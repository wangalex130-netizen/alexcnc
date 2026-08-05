#!/usr/bin/env python3
"""本地 Mock 云端（Smart CNC Studio）—— 纯标准库，无需 pip。

作用：在开发/联调阶段扮演「云端」，让 App 的 RealCloudService（USE_REAL_BACKEND=true）
在还没有真后端时就能跑通 REST 契约：

  GET  /api/v1/materials            材质参数主表（JSON 数组，字段对齐 MaterialSpec.fromJson）
  GET  /api/v1/tasks/active         当前激活任务元数据
  GET  /api/v1/tasks/<id>           指定任务元数据（含 widthMm/heightMm 驱动调平点数）
  POST /api/v1/devices/<id>/jobs    云端把切片 G-code 推送到指定设备（App 仅触发，不传 G-code）
  POST /api/v1/diagnostics          诊断日志上报

运行：
  python3 server.py            # 默认 0.0.0.0:8787
  python3 server.py 9000       # 自定义端口

配合 docker-compose 起 MQTT Broker 后，bridge.py 会把 G-code 推送事件转发到
cnc/<deviceId>/cmd，sim_device.py 扮演固件回 status —— 完整闭环见 README。
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
HOST = "0.0.0.0"

# ---- 材质主表（与 lib/data/material_db.dart 对齐；云端为唯一真源）----
MATERIALS = [
    {"key": "pine", "name": "松木", "visual": "wood", "swatch": "#D7B49E",
     "rpm": 10000, "feed": 1500, "plunge": 400, "toolIds": ["t_flat_3175", "t_ball_15"],
     "note": "软木，进给可快；3.175 平底刀粗雕 + 1.5 球头刀浮雕"},
    {"key": "basswood", "name": "椴木", "visual": "wood", "swatch": "#E8D5A8",
     "rpm": 11000, "feed": 1800, "plunge": 450, "toolIds": ["t_flat_3175", "t_ball_15"],
     "note": "极软木，进给最快；平底刀开粗 + 球头刀收光"},
    {"key": "plywood", "name": "密度板", "visual": "plywood", "swatch": "#C8B68F",
     "rpm": 12000, "feed": 1200, "plunge": 500, "toolIds": ["t_flat_3175", "t_v60"],
     "note": "MDF 粉尘大；平底刀切割 + 60°V 刻线，进给适中"},
    {"key": "walnut", "name": "胡桃木", "visual": "wood", "swatch": "#5D4037",
     "rpm": 10000, "feed": 1000, "plunge": 350, "toolIds": ["t_flat_3175", "t_vtip_08"],
     "note": "硬木中速；3.175 平底刀 + 0.8 尖刀精雕"},
    {"key": "blackwalnut", "name": "黑胡桃木", "visual": "wood", "swatch": "#3E2723",
     "rpm": 11000, "feed": 900, "plunge": 320, "toolIds": ["t_flat_3175", "t_ball_15"],
     "note": "硬木，致密；平底刀开粗 + 球头刀收光"},
    {"key": "boxwood", "name": "黄杨木", "visual": "wood", "swatch": "#D7C9A3",
     "rpm": 12000, "feed": 1400, "plunge": 400, "toolIds": ["t_flat_3175", "t_vtip_08"],
     "note": "细密硬木；平底刀 + 0.8 尖刀精细浮雕"},
    {"key": "ebony", "name": "紫光檀", "visual": "wood", "swatch": "#1B1B1B",
     "rpm": 12000, "feed": 800, "plunge": 300, "toolIds": ["t_flat_3175", "t_vtip_08"],
     "note": "极硬红木，进给要慢；平底刀开粗 + 尖刀精雕"},
    {"key": "acrylic", "name": "亚克力", "visual": "acrylic", "swatch": "#2196F3",
     "rpm": 12000, "feed": 800, "plunge": 300, "toolIds": ["t_o_single_3175", "t_v60"],
     "note": "注意排屑防熔边；单刃螺旋刀 + 60°V 型刀刻字"},
    {"key": "abs", "name": "ABS", "visual": "plastic", "swatch": "#F5F5F5",
     "rpm": 11000, "feed": 1000, "plunge": 350, "toolIds": ["t_o_single_3175", "t_v60"],
     "note": "工程塑料；单刃螺旋刀排屑 + V 型刀刻字"},
    {"key": "absdual", "name": "双色板", "visual": "plastic", "swatch": "#FF5252",
     "rpm": 12000, "feed": 900, "plunge": 300, "toolIds": ["t_v60", "t_flat_3175"],
     "note": "雕铣露底色的招牌料；60°V 型刀刻字为主"},
    {"key": "pvcsheet", "name": "雪弗板", "visual": "foam", "swatch": "#E0E0E0",
     "rpm": 13000, "feed": 1500, "plunge": 500, "toolIds": ["t_flat_3175", "t_o_single_3175"],
     "note": "PVC 发泡板，轻软；平底刀切割，进给可快"},
    {"key": "leather", "name": "皮革", "visual": "leather", "swatch": "#6D4C41",
     "rpm": 9000, "feed": 600, "plunge": 200, "toolIds": ["t_v60", "t_vtip_08"],
     "note": "薄软，用小切深；60°V / 0.8 尖刀压印刻线"},
    {"key": "pcb", "name": "覆铜板", "visual": "pcb", "swatch": "#2E7D32",
     "rpm": 14000, "feed": 600, "plunge": 250, "toolIds": ["t_vtip_08", "t_flat_3175"],
     "note": "薄板浅雕；0.8 尖刀走线 + 平底刀切外形"},
    {"key": "brass", "name": "黄铜", "visual": "brass", "swatch": "#B8860B",
     "rpm": 9000, "feed": 400, "plunge": 200, "toolIds": ["t_2flute_3175", "t_flat_18"],
     "note": "金属，需润滑/风冷；2 刃螺旋刀低速小进给"},
    {"key": "bakelite", "name": "电木", "visual": "bakelite", "swatch": "#4E342E",
     "rpm": 10000, "feed": 700, "plunge": 250, "toolIds": ["t_flat_3175", "t_2flute_3175"],
     "note": "绝缘硬板；平底刀切割，进给偏低"},
    {"key": "alu", "name": "铝合金", "visual": "metal", "swatch": "#90A4AE",
     "rpm": 8000, "feed": 300, "plunge": 150, "toolIds": ["t_2flute_3175", "t_flat_18"],
     "note": "需润滑/风冷；2 刃螺旋刀低速大进给"},
]

# ---- 任务元数据样本（驱动向导 Step5 调平点数 = f(模型尺寸)）----
TASKS = {
    "active": {
        "id": "task-001", "name": "胡桃木杯垫", "widthMm": 80, "heightMm": 80,
        "depthMm": 3, "boardThicknessMm": 8, "recommendedSpindleRpm": 12000,
        "recommendedFeedRate": 600, "defaultMaterialKey": "walnut",
        "defaultToolId": "t_flat_3175",
        "requiredTools": [{"toolId": "t_flat_3175", "role": "粗雕/轮廓"},
                           {"toolId": "t_v60", "role": "精雕/刻线"}],
    },
    "insp-hero": {
        "id": "insp-hero", "name": "复古木雕花纹板", "widthMm": 145, "heightMm": 95,
        "depthMm": 3, "boardThicknessMm": 3, "recommendedSpindleRpm": 10000,
        "recommendedFeedRate": 1500, "defaultMaterialKey": "pine",
        "defaultToolId": "t_flat_3175",
        "requiredTools": [{"toolId": "t_flat_3175", "role": "粗雕/轮廓"},
                           {"toolId": "t_v60", "role": "精雕/刻线"}],
    },
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # 安静日志
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = urlparse(self.path)
        if p.path == "/api/v1/materials":
            return self._send(200, MATERIALS)
        if p.path == "/api/v1/tasks/active":
            return self._send(200, TASKS["active"])
        if p.path.startswith("/api/v1/tasks/"):
            tid = p.path.rsplit("/", 1)[-1]
            task = TASKS.get(tid)
            if task:
                return self._send(200, task)
            return self._send(404, {"error": "task not found", "id": tid})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        p = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw or b"{}")
        except Exception:
            payload = {}

        if p.path.startswith("/api/v1/devices/") and p.path.endswith("/jobs"):
            dev = p.path.split("/")[-2]
            print(f"[GCODE PUSH] device={dev} task={payload.get('taskId')} "
                  f"-> 云端将切片 G-code 直推 MCU（App 不持有 G-code）", flush=True)
            # 此处真实环境会把任务交给切片服务并推送；本地仅记录事件。
            return self._send(202, {"accepted": True, "device": dev,
                                     "taskId": payload.get("taskId")})

        if p.path == "/api/v1/diagnostics":
            print(f"[DIAG] device={payload.get('device')} "
                  f"log={str(payload.get('log'))[:80]}", flush=True)
            return self._send(200, {"ok": True})

        return self._send(404, {"error": "not found"})


if __name__ == "__main__":
    print(f"Mock Cloud listening on http://{HOST}:{PORT}")
    print("Endpoints: GET /api/v1/materials | GET /api/v1/tasks/<id> | "
          "POST /api/v1/devices/<id>/jobs")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
