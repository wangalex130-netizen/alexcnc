package com.alexcnc.alexcnc

import android.app.Application
import com.igexin.sdk.PushManager

/**
 * 个推 3.x 隐私合规初始化（鸿蒙 AOSP / 小米 MIUI / HyperOS 实测踩坑 8/26）。
 *
 * 关键：必须在 SDK `initialize()` 之前完成两步 —— ① 同意隐私策略；② preInit。
 * 否则在严格 ROM 上 SDK **静默失败**（不抛异常、CID 永远不来）。
 *
 * Flutter 插件 `getuiflut` 0.2.41 完全没有调用 preInit，也不负责隐私合规门控，
 * 所以必须由原生 Application 的 onCreate 完成。Manifest 里
 * `<application android:name=".MainApplication">` 指到这里才会执行。
 *
 * 双路径兜底：
 *  - gtsdk 3.x 新版 → com.getui.gt.GTPrivacyManager
 *  - 旧版 / 反射失败 → 回退 com.igexin.sdk.PushManager.setPrivacyPolicyStrategy
 */
class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // 1) 同意隐私策略（true = 同意；false = 不同意，SDK 不初始化）
        var ok = false
        try {
            val cls = Class.forName("com.getui.gt.GTPrivacyManager")
            val getInstance = cls.getMethod("getInstance")
            val inst = getInstance.invoke(null)
            val setPrivacy = cls.getMethod(
                "setPrivacyPolicyStrategy",
                android.content.Context::class.java,
                java.lang.Boolean.TYPE
            )
            setPrivacy.invoke(inst, this, true)
            ok = true
        } catch (_: Throwable) {
            // 走旧路径
        }
        if (!ok) {
            try {
                PushManager.getInstance().setPrivacyPolicyStrategy(this, true)
            } catch (_: Throwable) {
                // SDK 都没加载到，忽略；Flutter 侧 initGetui 抛异常会被诊断捕获
            }
        }

        // 2) preInit 必须在 initialize 之前；Flutter 插件不会调
        try {
            PushManager.getInstance().preInit(this)
        } catch (_: Throwable) {
            // 同上
        }
    }
}
