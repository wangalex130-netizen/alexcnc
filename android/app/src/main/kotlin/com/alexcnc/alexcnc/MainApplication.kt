package com.alexcnc.alexcnc

import android.app.Application
import android.util.Log

/**
 * 个推 3.x 隐私合规初始化（鸿蒙 AOSP / 小米 MIUI / HyperOS 实测踩坑 8/26）。
 *
 * 关键：必须在 SDK `initialize()` 之前完成两步 —— ① 同意隐私策略；② preInit。
 * 否则在严格 ROM 上 SDK **静默失败**（不抛异常、CID 永远不来）。
 *
 * ⚠️ 为什么全部用反射而不是直接 import：
 * gtsdk 是由 Flutter 插件 `getuiflut` 以 `implementation` 方式传递进来的，
 * **只在运行时 classpath / APK 里，不在 app 模块的编译期 classpath**。
 * 直接 `import com.igexin.sdk.PushManager` 会编译报错
 * `Unresolved reference: igexin`（CI run 34081314371 实测）。
 * 反射调用可以同时满足：编译期零依赖 + 运行时正常生效。
 *
 * 方法签名不硬编码：遍历同名方法按参数个数匹配，并同时兼容
 * `boolean` 基本类型与 `Boolean` 包装类，避免 SDK 版本差异导致 NoSuchMethod。
 */
class MainApplication : Application() {

    companion object {
        private const val TAG = "GeTuiInit"
    }

    override fun onCreate() {
        super.onCreate()
        // 1) 同意隐私策略（true = 同意；false = 不同意，SDK 不初始化）
        val privacyOk = callSetPrivacy("com.getui.gt.GTPrivacyManager") ||
            callSetPrivacy("com.igexin.sdk.PushManager")
        // 2) preInit 必须在 initialize 之前；Flutter 插件不会调
        val preInitOk = callNoArgContext("com.igexin.sdk.PushManager", "preInit")
        Log.d(TAG, "privacyOk=$privacyOk preInitOk=$preInitOk")
    }

    /** 调 X.setPrivacyPolicyStrategy(Context, true)；成功返回 true。 */
    private fun callSetPrivacy(className: String): Boolean {
        return try {
            val cls = Class.forName(className)
            val inst = cls.getMethod("getInstance").invoke(null) ?: return false
            for (m in cls.methods) {
                if (m.name != "setPrivacyPolicyStrategy") continue
                if (m.parameterTypes.size != 2) continue
                val second = m.parameterTypes[1]
                val arg2: Any = when (second) {
                    java.lang.Boolean.TYPE -> true
                    java.lang.Boolean::class.java -> java.lang.Boolean.TRUE
                    else -> continue
                }
                return try {
                    m.invoke(inst, this, arg2)
                    true
                } catch (_: Throwable) {
                    false
                }
            }
            false
        } catch (_: Throwable) {
            false
        }
    }

    /** 调 X.methodName(Context)；成功返回 true。 */
    private fun callNoArgContext(className: String, methodName: String): Boolean {
        return try {
            val cls = Class.forName(className)
            val inst = cls.getMethod("getInstance").invoke(null) ?: return false
            for (m in cls.methods) {
                if (m.name != methodName) continue
                if (m.parameterTypes.size != 1) continue
                return try {
                    m.invoke(inst, this)
                    true
                } catch (_: Throwable) {
                    false
                }
            }
            false
        } catch (_: Throwable) {
            false
        }
    }
}
