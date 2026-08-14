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

D10 下载链路模拟（命令与文件分离）：
- 收到 {"cmd":"job","action":"prepare","gcodeUrl":"http://..."} 后，用 HTTP 把 G-code
  文本下载到本地（模拟 SD/Flash 落盘），广播 download 进度 0→1，完成后 state=ready。
- {"cmd":"gcode","lines":[...]} 帧保留为兼容通道，同样"落盘"后 state=ready。

D9 物理安全确认模拟：
- state=ready 后收到 {"cmd":"job","action":"start"}：广播 awaitingConfirm=true，
  机身屏弹「确认加工」；默认 --auto-confirm（模拟物理按钮自动按下）0.8s 后自动进入
  自检→加工；加 --no-auto-confirm 则需收到 {"cmd":"confirm"}（联调模拟按钮）才执行。

自检流水线由「固件」拥有：进入加工后先播自检阶段 scIndex 0→8，再进加工进度。
"""
import json
import sys
import time
import socket
import threading

try:
    sys.stdout.reconfigure(line_buffering=True)  # 重定向到文件时日志实时可见
except Exception:
    pass

# ---- 参数解析 ----
ARGV = list(sys.argv[1:])
TCP_MODE = "--tcp" in ARGV
if TCP_MODE:
    ARGV.remove("--tcp")

AUTO_CONFIRM = True
if "--no-auto-confirm" in ARGV:
    AUTO_CONFIRM = False
    ARGV.remove("--no-auto-confirm")

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
_state_lock = threading.Lock()  # 状态机并发保护（auto-confirm 线程 vs 命令线程）

# ---- 内部状态（SSOT）----
state = "idle"          # idle | ready | homing | busy | paused | alarm | disconnected
pos = {"x": 0.0, "y": 0.0, "z": 0.0}
mpos = {"x": 0.0, "y": 0.0, "z": 0.0}
rpm = None
feed = None
progress = 0.0
eta_sec = None
sc_index = 0
sc_total = 0
download_progress = None   # D10 G-code 下载进度 0..1；无下载任务为 None
awaiting_confirm = False   # D9 等待机旁物理确认
aux = {"light": False, "laser": False, "timelapse": False}
tools = [
    {"index": 1, "name": "3.175平底刀", "installed": True},
    {"index": 2, "name": "1.5球刀", "installed": True},
    {"index": 3, "installed": False},
    {"index": 4, "installed": False},
]
gcode_lines = []       # 模拟"SD/Flash 落盘的 G-code"
gcode_ready = False    # G-code 已落盘，可执行


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
        "download": download_progress,
        "awaitingConfirm": awaiting_confirm,
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


def begin_job():
    """D9 确认通过后：进入自检 → 加工。"""
    global state, progress, sc_index, sc_total, eta_sec, awaiting_confirm
    awaiting_confirm = False
    state = "busy"
    progress = 0.0
    sc_index = 0
    sc_total = 8          # 固件拥有的自检流水线：8 个阶段
    eta_sec = 300
    print("[fake_firmware] D9 确认通过 → 进入自检/加工")


def _confirm_after_delay():
    with _state_lock:
        begin_job()
    emit()


def handle(cmd):
    global state, pos, mpos, rpm, feed, progress, eta_sec, sc_index, sc_total, \
        aux, gcode_lines, gcode_ready, download_progress, awaiting_confirm
    if not isinstance(cmd, dict):
        return
    c = cmd.get("cmd")
    with _state_lock:
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
        elif c == "confirm":
            # D9 物理按钮（联调模拟）：仅等待确认时生效
            if awaiting_confirm:
                begin_job()
        elif c == "job":
            act = cmd.get("action")
            if act == "prepare":
                # D10：按 gcodeUrl 经 HTTP 下载 G-code 落盘（模拟 SD）
                url = cmd.get("gcodeUrl")
                if url:
                    download_progress = 0.0
                    emit()
                    try:
                        import urllib.request
                        with urllib.request.urlopen(url, timeout=10) as resp:
                            text = resp.read().decode("utf-8", errors="ignore")
                        lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
                        gcode_lines = lines
                        gcode_ready = True
                        download_progress = 1.0
                        state = "ready"
                        print(f"[fake_firmware] D10 已从 {url} 下载 {len(lines)} 行 G-code → ready")
                    except Exception as e:
                        download_progress = None
                        state = "alarm"
                        print(f"[fake_firmware] D10 下载失败: {e}")
                else:
                    print("[fake_firmware] job prepare 缺少 gcodeUrl")
            elif act == "start":
                # D9：已落盘 → 广播 awaitingConfirm，等待机旁确认
                if gcode_ready:
                    awaiting_confirm = True
                    state = "ready"
                    print("[fake_firmware] D9 等待机旁物理确认（awaitingConfirm=true）")
                    if AUTO_CONFIRM:
                        # 联调默认：模拟物理按钮 0.8s 后自动按下
                        threading.Timer(0.8, _confirm_after_delay).start()
                else:
                    # 兼容：无 G-code 时直接进 busy（旧联调流程不卡）
                    begin_job()
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
                awaiting_confirm = False
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
            # 兼容通道：lines 直传同样"落盘"
            gcode_lines = list(cmd.get("lines", []))
            gcode_ready = True
            state = "ready"
            print(f"[fake_firmware] 收到 G-code {len(gcode_lines)} 行（已落盘，state=ready）")
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
    print(f"[fake_firmware] D9 确认: {'自动确认(auto-confirm)' if AUTO_CONFIRM else '手动 confirm 帧'}")
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
