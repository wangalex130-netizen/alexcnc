# -*- coding: utf-8 -*-
"""
two_stage_launch_sim.py — 雕刻启动「两段式」验收用最小模拟器（App 侧自测工具）

为什么单独写一个而不改 cnc-control-server/sim/flat_screen_sim.py：
  现有 flat_screen_sim.py 的 `_cmd_job(start)` 直接 `state=busy`，
  **不发 awaitingConfirm、不发 confirm_required/confirm_timeout**，
  即它复刻的是「老固件」行为 —— 用它可以验老固件回归（验收③），
  但验不了两段式的「待确认」态（验收②）。本脚本补上这一态，
  且不侵入 cnc-control-server 项目（避免与服务端同学改同一文件冲突）。

两种模式：
  --mode legacy     老固件：start → 直接 busy（验收③ 回归）
  --mode two-stage  两段式：start → awaitingConfirm=true + notify confirm_required
                            → 等人工指令 → busy（确认）或 idle + confirm_timeout（超时）
                                                            （验收②）

运行后（two-stage 模式）在控制台输入：
  key      模拟客户在机器上按下物理开始键 → 发 confirm 并进入 busy
  timeout  模拟客户没按键、机器超时取消   → 发 confirm_timeout 并回到 idle
  quit     退出

用法示例（与 EMQX 同机走内网 1883）：
  python3 two_stage_launch_sim.py --broker 127.0.0.1 --port 1883 \\
      --device cnc-demo-01 --user screen-cnc-demo-01 --password demo123 --mode two-stage

外网 TLS（香港 43.154.192.242:8883）：
  python3 two_stage_launch_sim.py --broker 43.154.192.242 --port 8883 --tls \\
      --device cnc-demo-01 --user screen-cnc-demo-01 --password demo123 --mode two-stage

协议契约（与 App hardware_service_real 一致）：
  订阅 cnc/{id}/cmd          收 {"cmd":"job","action":"start"}
  发布 cnc/{id}/status       qos=1 retain=1，含 state / awaitingConfirm
  发布 cnc/{id}/notify       qos=1，{"type":...,"msg":...,"data":{}}
"""
import argparse
import json
import ssl
import sys
import threading
import time

import paho.mqtt.client as mqtt


class TwoStageSim:
    def __init__(self, device_id, two_stage, confirm_window_sec=30):
        self.device_id = device_id
        self.two_stage = two_stage
        self.confirm_window_sec = confirm_window_sec

        self.state = "idle"
        self.awaiting_confirm = False
        self.sc_index = 0
        self.sc_total = 0

        self.topic_cmd = f"cnc/{device_id}/cmd"
        self.topic_status = f"cnc/{device_id}/status"
        self.topic_notify = f"cnc/{device_id}/notify"
        self.topic_job = f"cnc/{device_id}/job"

        self.client = mqtt.Client(client_id=f"sim-{device_id}-{int(time.time())}")
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self._lock = threading.Lock()

    # ---------- 发布 ----------
    def _publish_status(self):
        payload = json.dumps(
            {
                "state": self.state,
                "awaitingConfirm": self.awaiting_confirm,
                "scIndex": self.sc_index,
                "scTotal": self.sc_total,
                "progress": 0.0,
                "msg": "等待机旁确认" if self.awaiting_confirm else "",
            },
            ensure_ascii=False,
        )
        self.client.publish(self.topic_status, payload, qos=1, retain=True)
        print(f"[sim] → status  {payload}")

    def _publish_notify(self, etype, msg, data=None):
        payload = json.dumps(
            {"type": etype, "msg": msg, "data": data or {}}, ensure_ascii=False
        )
        self.client.publish(self.topic_notify, payload, qos=1)
        print(f"[sim] → notify  {payload}")

    def _publish_job(self, phase, percent=0.0):
        payload = json.dumps(
            {"phase": phase, "percent": percent, "line": 0, "total": 100},
            ensure_ascii=False,
        )
        self.client.publish(self.topic_job, payload, qos=1)
        print(f"[sim] → job     {payload}")

    # ---------- 回调 ----------
    def _on_connect(self, client, userdata, flags, rc, properties=None):
        print(f"[sim] connected rc={rc}, subscribing {self.topic_cmd}")
        client.subscribe(self.topic_cmd, qos=1)
        self._publish_status()

    def _on_message(self, client, userdata, msg):
        try:
            frame = json.loads(msg.payload.decode("utf-8"))
        except Exception as e:
            print(f"[sim] ! bad json: {e}")
            return
        print(f"[sim] ← cmd     {json.dumps(frame, ensure_ascii=False)}")
        if frame.get("cmd") != "job":
            return
        action = frame.get("action")
        if action == "start":
            self._handle_start()
        elif action == "stop":
            self._handle_stop()

    # ---------- 两段式状态机 ----------
    def _handle_start(self):
        with self._lock:
            if self.state not in ("idle", "alarm"):
                self._publish_notify(
                    "job_error", f"当前状态 {self.state} 无法启动", {"code": "E409"}
                )
                return

            if not self.two_stage:
                # 老固件路径（验收③）：收到 start 直接开刀，awaitingConfirm 恒 false。
                # App 应表现为「已下发 → 加工中」，不出现待确认态、不报错。
                print("[sim] legacy mode: start → busy (无待确认态)")
                thread = threading.Thread(target=self._run_job, daemon=True)
                thread.start()
                return

            # 两段式路径（验收②）：进入待确认，等客户按物理键。
            self.state = "busy"
            self.awaiting_confirm = True
            self.sc_total = 5
            self.sc_index = 0
            self._publish_status()
            self._publish_notify(
                "confirm_required",
                "请在机器上按开始键确认",
                {"timeoutSec": self.confirm_window_sec},
            )
            print(
                f"[sim] 待确认：{self.confirm_window_sec}s 内输入 'key'（确认）"
                f" 或 'timeout'（超时取消）"
            )

    def confirm_by_key(self):
        """客户按了物理开始键 → 动刀。"""
        with self._lock:
            if not self.awaiting_confirm:
                print("[sim] ! 当前不在待确认态，忽略")
                return
            self.awaiting_confirm = False
            self._publish_notify("confirm_accepted", "已确认，开始加工")
            thread = threading.Thread(target=self._run_job, daemon=True)
            thread.start()

    def confirm_timeout(self):
        """客户没按 → 机器取消本次启动。App 必须停止重发（命令已送达只是被取消）。"""
        with self._lock:
            if not self.awaiting_confirm:
                print("[sim] ! 当前不在待确认态，忽略")
                return
            self.awaiting_confirm = False
            self.state = "idle"
            self.sc_total = 0
            self.sc_index = 0
            self._publish_status()
            self._publish_notify("confirm_timeout", "确认超时已取消", {"code": "E410"})

    def _handle_stop(self):
        with self._lock:
            self.awaiting_confirm = False
            self.state = "idle"
            self.sc_total = 0
            self.sc_index = 0
            self._publish_status()
            self._publish_notify("job_stopped", "已停止")

    def _run_job(self):
        """自检 1..5 → 加工（复刻 flat_screen_sim 的 _job_worker 节奏）。"""
        self.state = "busy"
        self.awaiting_confirm = False
        self.sc_total = 5
        self._publish_job("loading", 0.0)
        for i in range(1, 6):
            self.sc_index = i
            self._publish_status()
            time.sleep(0.4)
        self.sc_index = 5
        self._publish_job("carving", 0.0)
        for p in range(0, 101, 10):
            self._publish_job("carving", p / 100.0)
            time.sleep(0.3)
        self.state = "idle"
        self.sc_total = 0
        self.sc_index = 0
        self._publish_job("done", 1.0)
        self._publish_status()
        self._publish_notify("job_done", "加工完成")

    # ---------- 生命周期 ----------
    def start(self, broker, port, user, password, tls):
        if user:
            self.client.username_pw_set(user, password or None)
        if tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self.client.tls_set_context(ctx)
        self.client.connect(broker, port, keepalive=30)
        self.client.loop_start()

    def stop(self):
        self.client.loop_stop()
        self.client.disconnect()


def main():
    ap = argparse.ArgumentParser(description="雕刻启动两段式验收模拟器")
    ap.add_argument("--broker", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--device", default="cnc-demo-01")
    ap.add_argument("--user", default="")
    ap.add_argument("--password", default="")
    ap.add_argument("--tls", action="store_true")
    ap.add_argument(
        "--mode",
        choices=["legacy", "two-stage"],
        default="two-stage",
        help="legacy=老固件(start 直接 busy，验收③)；two-stage=两段式(验收②)",
    )
    ap.add_argument("--confirm-window", type=int, default=30, help="待确认窗口（秒，仅提示用）")
    args = ap.parse_args()

    sim = TwoStageSim(
        args.device,
        two_stage=(args.mode == "two-stage"),
        confirm_window_sec=args.confirm_window,
    )
    sim.start(args.broker, args.port, args.user, args.password, args.tls)
    print(f"[sim] 就绪 device={args.device} mode={args.mode} broker={args.broker}:{args.port}")

    if args.mode == "two-stage":
        print("[sim] 命令：key=按下物理键确认 / timeout=确认超时取消 / quit=退出")
        while True:
            try:
                line = sys.stdin.readline()
            except KeyboardInterrupt:
                break
            if not line:
                break
            cmd = line.strip().lower()
            if cmd == "key":
                sim.confirm_by_key()
            elif cmd == "timeout":
                sim.confirm_timeout()
            elif cmd in ("quit", "exit", "q"):
                break
    else:
        print("[sim] legacy 模式：App 点开始后应直接进「加工中」，无待确认态。Ctrl-C 退出。")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass

    sim.stop()
    print("[sim] 已退出")


if __name__ == "__main__":
    main()
