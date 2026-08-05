#!/usr/bin/env python3
"""
fake_firmware.py — 模拟 ESP32 固件，用于无硬件联调。

支持两种传输，帧格式完全一致（见 docs/PROTOCOL.md Step1）：
- 局域网 TCP 服务器模式（第一步默认，无需 broker）：
    python3 fake_firmware.py --tcp [--tcp-host 0.0.0.0] [--tcp-port 8899] [deviceId]
  监听 TCP:8899，接收换行分隔的 JSON 命令帧，并通过同一连接回发状态帧。
  这是嵌入式 AsyncTCP Server 的**可直接照抄的参考实现**。
- 云端 MQTT 模式（第二步）：
    python3 fake_firmware.py [broker] [deviceId]
  订阅 cnc/<deviceId>/cmd，发布 cnc/<deviceId>/status。

自检流水线由「固件」拥有：startJob 后先播自检阶段 scIndex 0→8，再进加工进度。
"""
import json
import sys
import time
import socket
import threading

# ---- 参数解析 ----
ARGV = list(sys.argv[1:])
TCP_MODE = "--tcp" in ARGV
if TCP_MODE:
    ARGV.remove("--tcp")

TCP_HOST = "0.0.0.0"
TCP_PORT = 8899
# 解析 --tcp-host / --tcp-port
i = 0
while i < len(ARGV):
    if ARGV[i] == "--tcp-host":
        TCP_HOST = ARGV[i + 1]; ARGV.pop(i); ARGV.pop(i)
    elif ARGV[i] == "--tcp-port":
        TCP_PORT = int(ARGV[i + 1]); ARGV.pop(i); ARGV.pop(i)
    else:
        i += 1

DEVICE = ARGV[0] if len(ARGV) > 0 else "alexcnc-001"
BROKER = ARGV[1] if len(ARGV) > 1 else "broker.emqx.io"
PORT = 1883
CMD_TOPIC = f"cnc/{DEVICE}/cmd"
STATUS_TOPIC = f"cnc/{DEVICE}/status"

tcp_clients = []  # 已连接的 App TCP 客户端 socket

# ---- 内部状态（SSOT）----
state = "idle"          # idle | homing | busy | paused | alarm | disconnected
pos = {"x": 0.0, "y": 0.0, "z": 0.0}
mpos = {"x": 0.0, "y": 0.0, "z": 0.0}
rpm = None
feed = None
progress = 0.0
eta_sec = None
sc_index = 0
sc_total = 0
aux = {"light": False, "laser": False, "timelapse": False}
tools = [
    {"index": 1, "name": "3.175平底刀", "installed": True},
    {"index": 2, "name": "1.5球刀", "installed": True},
    {"index": 3, "installed": False},
    {"index": 4, "installed": False},
]
gcode_lines = []


def emit():
    payload = {
        "state": state,
        "pos": pos,
        "mpos": mpos,
        "rpm": rpm,
        "feed": feed,
        "progress": round(progress, 3),
        "etaSec": eta_sec,
        "scIndex": sc_index,
        "scTotal": sc_total,
        "aux": aux,
        "tools": tools,
    }
    if TCP_MODE:
        line = json.dumps(payload) + "\n"
        dead = []
        for s in list(tcp_clients):
            try:
                s.sendall(line.encode())
            except Exception:
                dead.append(s)
        for s in dead:
            if s in tcp_clients:
                tcp_clients.remove(s)
    else:
        client.publish(STATUS_TOPIC, json.dumps(payload), qos=1)


def handle(cmd):
    global state, pos, mpos, rpm, feed, progress, eta_sec, sc_index, sc_total, aux, gcode_lines
    if not isinstance(cmd, dict):
        return
    c = cmd.get("cmd")
    if c == "jog":
        ax = cmd.get("axis", "x")
        d = float(cmd.get("dist", 0) or 0)
        if ax in pos:
            pos[ax] = round(pos[ax] + d, 3)
            mpos[ax] = round(mpos[ax] + d, 3)
    elif c == "home":
        state = "homing"
        emit()
        time.sleep(0.6)
        pos = {"x": 0.0, "y": 0.0, "z": 0.0}
        mpos = {"x": 0.0, "y": 0.0, "z": 0.0}
        state = "idle"
    elif c == "setWorkZero":
        pos = {"x": float(cmd.get("x", 0) or 0),
               "y": float(cmd.get("y", 0) or 0),
               "z": float(cmd.get("z", 0) or 0)}
    elif c == "spindle":
        r = cmd.get("rpm")
        rpm = int(r) if r else None
    elif c == "aux":
        aux[cmd.get("key")] = bool(cmd.get("on"))
    elif c == "job":
        act = cmd.get("action")
        if act == "start":
            state = "busy"
            progress = 0.0
            sc_index = 0
            sc_total = 8          # 固件拥有的自检流水线：8 个阶段
            eta_sec = 300
        elif act == "pause":
            if state == "busy":
                state = "paused"
        elif act == "resume":
            if state == "paused":
                state = "busy"
        elif act == "stop":
            state = "idle"
            progress = 0.0
            sc_index = 0
            sc_total = 0
            rpm = None
            feed = None
    elif c == "toolMap":
        for t in cmd.get("tools", []):
            i = int(t.get("index"))
            for slot in tools:
                if slot["index"] == i:
                    slot["installed"] = bool(t.get("installed"))
    elif c == "leveling":
        mode = int(cmd.get("mode", 1))
        cols = int(cmd.get("cols", 1))
        rows = int(cmd.get("rows", 1))
        print(f"[fake_firmware] 收到调平方案 mode={mode} 网格 {cols}x{rows}")
    elif c == "gcode":
        gcode_lines = list(cmd.get("lines", []))
        print(f"[fake_firmware] 收到 G-code {len(gcode_lines)} 行（已缓冲）")
    emit()


# ---- 局域网 TCP 服务器模式（第一步）----
def handle_client(conn, addr):
    buf = b""
    try:
        emit()  # 连上即回一发，App 立刻看到"已连"
        while True:
            data = conn.recv(4096)
            if not data:
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                t = line.decode(errors="ignore").strip()
                if not t:
                    continue
                try:
                    cmd = json.loads(t)
                except Exception:
                    continue
                handle(cmd)  # handle() 末尾 emit() 经同一连接回发状态
    except Exception as e:
        print(f"[fake_firmware] 客户端 {addr} 断开: {e}")
    finally:
        if conn in tcp_clients:
            tcp_clients.remove(conn)
        try:
            conn.close()
        except Exception:
            pass


def start_tcp():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((TCP_HOST, TCP_PORT))
    srv.listen(5)
    print(f"[fake_firmware] TCP Server 监听 {TCP_HOST}:{TCP_PORT} (device={DEVICE})")
    while True:
        conn, addr = srv.accept()
        print(f"[fake_firmware] 客户端连接 {addr}")
        tcp_clients.append(conn)
        threading.Thread(target=handle_client, args=(conn, addr), daemon=True).start()


# ---- 后台状态推进（自检 → 加工）----
def ticker():
    global sc_index, sc_total, progress, eta_sec, state, rpm, feed
    while True:
        time.sleep(1)
        if state == "busy":
            if sc_index < sc_total:
                sc_index += 1          # 自检阶段由固件推进
            else:
                progress = min(1.0, progress + 0.02)
                rpm = 12000
                feed = 600
                eta_sec = max(0, int((1 - progress) * 300))
                if progress >= 1.0:
                    state = "idle"
                    progress = 1.0
                    rpm = None
                    feed = None
        emit()


if TCP_MODE:
    threading.Thread(target=ticker, daemon=True).start()
    print(f"[fake_firmware] 模拟固件启动(TCP模式): device={DEVICE}")
    start_tcp()
else:
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        print("请先安装依赖: pip install paho-mqtt")
        sys.exit(1)

    def on_connect(c, u, f, rc, *a):
        print(f"[fake_firmware] 连上 {BROKER}，订阅 {CMD_TOPIC}")
        c.subscribe(CMD_TOPIC, qos=1)

    def on_message(c, u, msg):
        try:
            cmd = json.loads(msg.payload.decode())
        except Exception:
            return
        handle(cmd)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(BROKER, PORT, 60)
    threading.Thread(target=ticker, daemon=True).start()
    print(f"[fake_firmware] 模拟固件启动(MQTT模式): device={DEVICE}")
    client.loop_forever()
