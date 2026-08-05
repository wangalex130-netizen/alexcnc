#!/usr/bin/env python3
"""
fake_firmware.py — 模拟 ESP32 固件，用于无硬件联调 App 的 MQTT 链路。

按 docs/PROTOCOL.md 契约：
- 订阅 cnc/<deviceId>/cmd（App 下发的 JSON 命令）
- 发布 cnc/<deviceId>/status（JSON 状态广播，含自检 scIndex/scTotal）
- 自检流水线由「固件」拥有：startJob 后先播自检阶段，再进加工进度

依赖：pip install paho-mqtt
用法：python3 fake_firmware.py [broker] [deviceId]
"""
import json
import sys
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("请先安装依赖: pip install paho-mqtt")
    sys.exit(1)

BROKER = sys.argv[1] if len(sys.argv) > 1 else "broker.emqx.io"
PORT = 1883
DEVICE = sys.argv[2] if len(sys.argv) > 2 else "alexcnc-001"
CMD_TOPIC = f"cnc/{DEVICE}/cmd"
STATUS_TOPIC = f"cnc/{DEVICE}/status"

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
    client.publish(STATUS_TOPIC, json.dumps(payload), qos=1)


def on_connect(c, u, f, rc, *a):
    print(f"[fake_firmware] 连上 {BROKER}，订阅 {CMD_TOPIC}")
    c.subscribe(CMD_TOPIC, qos=1)


def handle(cmd):
    global state, pos, mpos, rpm, feed, progress, eta_sec, sc_index, sc_total, aux
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
    emit()


def on_message(c, u, msg):
    try:
        cmd = json.loads(msg.payload.decode())
    except Exception:
        return
    handle(cmd)


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


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER, PORT, 60)

import threading
threading.Thread(target=ticker, daemon=True).start()
print(f"[fake_firmware] 模拟固件启动: device={DEVICE}")
client.loop_forever()
