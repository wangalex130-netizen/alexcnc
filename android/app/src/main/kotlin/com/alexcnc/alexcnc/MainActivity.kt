package com.alexcnc.alexcnc

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val PUSH_CHANNEL = "alexcnc/push"
    }

    /**
     * N-02（2026-09-10，P1 合规）：个推的 initialize 已被 MainApplication 门控，
     * 未同意隐私政策时只做 preInit。用户在 App 内点同意后，Dart 侧经此通道
     * 调用 "initialize" 完成后续注册（registerPushIntentService + initialize）。
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PUSH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        (application as? MainApplication)?.initAfterConsent()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
