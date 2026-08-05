#!/usr/bin/env python3
"""本地 MQTT Broker（联调用，纯 Python，无需外部服务）。

让 sandbox / 本机在无外网 1883 放行时也能跑通 App↔固件 MQTT 链路：
  - 监听 0.0.0.0:1883
  - 订阅/发布主题与 PROTOCOL.md 一致：cnc/<deviceId>/cmd、cnc/<deviceId>/status

用法：python3 local_broker.py
"""
import asyncio
from amqtt.broker import Broker

CONFIG = {
    "listeners": {
        "default": {
            "type": "tcp",
            "bind": "0.0.0.0:1883",
        }
    },
    "plugins": {
        "amqtt.plugins.authentication.AnonymousAuthPlugin": {"allow_anonymous": True},
    },
}


async def main():
    broker = Broker(CONFIG)
    await broker.start()
    print("[broker] MQTT broker on 0.0.0.0:1883 (ctrl-c to stop)", flush=True)
    try:
        while True:
            await asyncio.sleep(3600)
    except (KeyboardInterrupt, asyncio.CancelledError):
        await broker.shutdown()


if __name__ == "__main__":
    asyncio.run(main())
