#!/usr/bin/env python3
"""MQTT 链路 loopback 测试：模拟「App 命令发布方」与「状态订阅方」，
验证 fake_firmware（固件形态）对命令帧的响应与状态广播帧契约。

前置：先起 local_broker.py，再起 fake_firmware.py localhost <device>，
最后运行本脚本：python3 mqtt_loopback_test.py [device]

期望观察到的状态演进：
  idle -> (job start) busy 且 scIndex 从 0 递增到 scTotal -> 进入 progress 递增
  (jog) pos/mpos 累加  (leveling) 打印收到网格方案  (job stop) 回到 idle
"""
import json
import sys
import time
import paho.mqtt.client as mqtt

DEVICE = sys.argv[1] if len(sys.argv) > 1 else "alexcnc-001"
CMD = f"cnc/{DEVICE}/cmd"
STATUS = f"cnc/{DEVICE}/status"

seen = []


def on_connect(c, u, f, rc, *a):
    print(f"[test] 连上 broker，订阅 {STATUS}", flush=True)
    c.subscribe(STATUS, qos=1)


def on_message(c, u, msg):
    try:
        s = json.loads(msg.payload.decode())
    except Exception:
        return
    seen.append(s)
    print(f"[status] state={s.get('state')} sc={s.get('scIndex')}/{s.get('scTotal')} "
          f"prog={s.get('progress')} pos={s.get('pos')}", flush=True)


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
client.on_connect = on_connect
client.on_message = on_message
client.connect("127.0.0.1", 1883, 60)
client.loop_start()

time.sleep(1.5)


def send(cmd):
    client.publish(CMD, json.dumps(cmd), qos=1)
    print(f"[cmd] -> {cmd}", flush=True)


# 1) 启动加工（固件拥有自检流水线）
send({"cmd": "job", "action": "start"})
time.sleep(3)  # 观察自检阶段 + 进入加工

# 2) JOG 测试
send({"cmd": "jog", "axis": "x", "dist": 5.0})
time.sleep(1)

# 3) 调平方案下发
send({"cmd": "leveling", "mode": 1, "cols": 5, "rows": 4})
time.sleep(1)

# 4) 暂停 / 恢复
send({"cmd": "job", "action": "pause"})
time.sleep(1.5)
send({"cmd": "job", "action": "resume"})
time.sleep(1.5)

# 5) 停止
send({"cmd": "job", "action": "stop"})
time.sleep(1.5)

client.loop_stop()
client.disconnect()

# ---- 断言 ----
states = [s.get("state") for s in seen]
assert any(s.get("scTotal", 0) > 0 for s in seen), "未观察到自检阶段广播"
assert any(s.get("pos", {}).get("x") == 5.0 for s in seen), "JOG x=5.0 未生效"
assert "paused" in states, "pause 未生效"
print("\n[RESULT] MQTT 命令/状态帧契约 loopback 验证通过 ✅")
