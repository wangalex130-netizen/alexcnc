package com.alexcnc.alexcnc

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import java.io.File

/**
 * 个推 3.x 正确初始化（对照 alexcnc_push_test Run 15 真机全链路验证通过的范本）。
 *
 * 为什么必须在这里做完整初始化，而不能只依赖 getuiflut 插件：
 *   插件 GetuiflutPlugin.initGtSdk() 的正常路径（单参数 initialize 不抛异常）下，
 *   只调 PushManager.getInstance().initialize(context)，**从不注册**
 *   FlutterPushService（SDK 核心服务）与 FlutterIntentService（CID/消息回调桥梁）。
 *   单参数 initialize 会去拉起默认 com.igexin.sdk.PushService，该类未在合并后的
 *   AndroidManifest 中声明，于是服务起不来、CID 永远为空，且个推内部把异常吞掉，
 *   Flutter 侧完全无回调 —— 正是「getui-init-ok 但 CID 停在占位 pt_」的根因。
 *
 * 因此这里按个推官方顺序显式做：
 *   1) 同意隐私策略（GTPrivacyManager / PushManager 多路径兼容不同 SDK 版本）
 *   2) preInit
 *   3) registerPushIntentService(FlutterIntentService)
 *   4) initialize(context, FlutterPushService)（双参数，指定已声明的服务类）
 *
 * 全部用反射调用（不 import com.igexin / com.getui）：gtsdk 由 getuiflut 以
 * implementation 方式传递，仅运行时 classpath 可见，编译期直接 import 会报
 * Unresolved reference（CI run 34081314371 实测）。反射可同时满足
 * 编译期零依赖 + 运行时正常生效。
 *
 * 诊断下沉：把每一步结果与个推 SDK 内部日志写入 FlutterSharedPreferences
 * （key: push_native_init_log / push_sdk_log），调试页「推送联调」卡片可直接读出，
 * 无需 adb。若 CID 仍失败，这里会明确显示 appid 不对 / 包名不匹配 / 网络不通等根因。
 */
class MainApplication : Application() {

    companion object {
        private const val TAG = "AlexCncPush"
        private const val SP_NAME = "FlutterSharedPreferences"
        const val KEY_NATIVE_INIT = "push_native_init_log"
        const val KEY_SDK_LOG = "push_sdk_log"
        const val KEY_PROCESS = "push_native_process"
        /** N-02：隐私同意标记，与 push_service.dart 的 kPrivacyAcceptedKey 同名。 */
        const val KEY_PRIVACY = "push_privacy_accepted_v1"

        /** 进程内缓存（供后续扩展读取，落盘以 FlutterSharedPreferences 为准）。 */
        @JvmField var nativeInitLog: String = "(未执行)"

        @JvmField var sdkLog: String = "(暂无 SDK 日志)"
    }

    override fun onCreate() {
        super.onCreate()
        val processName = readProcessName()
        writeSp(KEY_PROCESS, processName)
        Log.d(TAG, "onCreate process=$processName package=$packageName")

        // 个推的 :pushservice 子进程也会走 Application.onCreate，只在主进程初始化。
        if (processName.isNotEmpty() && processName != packageName) {
            nativeInitLog = "子进程($processName)跳过初始化"
            writeSp(KEY_NATIVE_INIT, nativeInitLog)
            return
        }

        installSdkDebugLogger(applicationContext)
        // 🔴 N-02（2026-09-10，P1 合规）：隐私门控下沉到原生层。
        // 原实现在 onCreate 无条件 setPrivacyPolicyStrategy(true) + initialize，
        // 而 Dart 侧 push_service 的门控发生在更晚 —— 用户还没同意，CID 就已注册完成
        //（已在收集设备信息）。现按**真实同意状态**决定：未同意只做 preInit，
        // initialize 等用户同意后由 MainActivity 的 MethodChannel 触发。
        val accepted = isPrivacyAccepted()
        Log.d(TAG, "privacyAccepted=$accepted")
        agreePrivacyPolicyBeforeInit(applicationContext, accepted)
        initGetuiSdkProperly(applicationContext, fullInit = accepted)
    }

    /**
     * 读取 Dart 侧写入的隐私同意标记（shared_preferences 会加 "flutter." 前缀）。
     * 与 push_service.dart 的 [kPrivacyAcceptedKey] 保持同一 key。
     */
    private fun isPrivacyAccepted(): Boolean {
        return try {
            val sp = getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
            sp.getBoolean("flutter.$KEY_PRIVACY", false) ||
                sp.getBoolean(KEY_PRIVACY, false)
        } catch (e: Throwable) {
            Log.e(TAG, "isPrivacyAccepted failed", e)
            false
        }
    }

    /**
     * N-02：用户在 App 内同意隐私政策后，由 MainActivity 的 MethodChannel 调用，
     * 完成此前被门控拦下的 registerPushIntentService + initialize。
     */
    fun initAfterConsent() {
        if (!isPrivacyAccepted()) {
            Log.d(TAG, "initAfterConsent: 仍未同意，忽略")
            return
        }
        if (nativeInitLog.contains("initialize")) {
            Log.d(TAG, "initAfterConsent: 已初始化过，跳过")
            return
        }
        agreePrivacyPolicyBeforeInit(applicationContext, true)
        initGetuiSdkProperly(applicationContext, fullInit = true)
    }

    private fun writeSp(key: String, value: String) {
        try {
            val sp = getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
            val e = sp.edit()
            // 关键坑：shared_preferences ^2.x 的 Android 实现读 key 时会自动加
            // "flutter." 前缀（SP 文件名就是 FlutterSharedPreferences），所以
            // 原生必须写带前缀的 key，否则 Dart 侧 SharedPreferences.getInstance()
            // .getString("push_native_init_log") 永远读不到，会显示"原生未写入"。
            // 同时也写一份不带前缀的作为兜底（万一日后插件前缀行为变化）。
            e.putString("flutter.$key", value)
            e.putString(key, value)
            e.apply()
        } catch (e: Throwable) {
            Log.e(TAG, "writeSp($key) failed", e)
        }
    }

    /** 读取当前进程名，区分主进程与 :pushservice 子进程。 */
    private fun readProcessName(): String {
        return try {
            File("/proc/self/cmdline").readText().replace("\u0000", "").trim()
        } catch (e: Throwable) {
            ""
        }
    }

    /**
     * 反射挂接 PushManager.setDebugLogger(Context, IUserLoggerInterface)，把个推 SDK
     * 内部日志收进 push_sdk_log，调试页可直接看到 CID 注册失败的精确原因。
     */
    private fun installSdkDebugLogger(context: Context) {
        try {
            val pmCls = Class.forName("com.igexin.sdk.PushManager")
            val pm = pmCls.getMethod("getInstance").invoke(null) ?: return
            val setLogger = pmCls.declaredMethods.firstOrNull {
                it.name == "setDebugLogger" && it.parameterCount == 2
            }
            if (setLogger == null) {
                appendSdkLog("setDebugLogger 方法未找到")
                return
            }
            val loggerCls = setLogger.parameterTypes[1]
            if (!loggerCls.isInterface) {
                appendSdkLog("setDebugLogger 第二参数非接口: ${loggerCls.name}")
                return
            }
            val proxy = java.lang.reflect.Proxy.newProxyInstance(
                loggerCls.classLoader ?: javaClass.classLoader,
                arrayOf(loggerCls)
            ) { p, method, args ->
                when (method.name) {
                    "log" -> {
                        appendSdkLog(args?.firstOrNull()?.toString() ?: "")
                        null
                    }
                    "hashCode" -> System.identityHashCode(p)
                    "equals" -> p === args?.firstOrNull()
                    "toString" -> "GetuiDebugLogger"
                    else -> null
                }
            }
            setLogger.isAccessible = true
            setLogger.invoke(pm, context, proxy)
            appendSdkLog("--- debugLogger 已挂载(${loggerCls.simpleName})，以下为 SDK 内部日志 ---")
        } catch (e: Throwable) {
            appendSdkLog("挂载 debugLogger 失败: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun appendSdkLog(line: String) {
        if (line.isBlank()) return
        val lines = sdkLog.split("\n").toMutableList()
        lines.add(line)
        while (lines.size > 200) lines.removeAt(0)
        sdkLog = lines.joinToString("\n")
        writeSp(KEY_SDK_LOG, sdkLog)
        Log.d(TAG, "[GT_SDK] $line")
    }

    /**
     * 反射设置个推隐私策略。**N-02：布尔值必须反映真实同意状态**
     *（原来是硬编码 true，等于替用户点了同意，属代用户同意）。
     * 多路径兼容不同 gtsdk 版本的类名：
     *   com.igexin.sdk.PushManager / com.getui.gt.GTPrivacyManager / com.igexin.sdk.GTPrivacyManager
     */
    private fun agreePrivacyPolicyBeforeInit(context: Context, accepted: Boolean) {
        val candidates = listOf(
            "com.igexin.sdk.PushManager",
            "com.getui.gt.GTPrivacyManager",
            "com.igexin.sdk.GTPrivacyManager",
        )
        val attempts = mutableListOf<String>()
        for (clsName in candidates) {
            if (attempts.any { it.endsWith("=OK") }) break
            try {
                val cls = Class.forName(clsName)
                val instance = cls.getMethod("getInstance").invoke(null) ?: continue
                val method = cls.declaredMethods.firstOrNull { m ->
                    m.name == "setPrivacyPolicyStrategy" &&
                        m.parameterCount == 2 &&
                        Context::class.java.isAssignableFrom(m.parameterTypes[0]) &&
                        m.parameterTypes[1] == Boolean::class.javaPrimitiveType
                }
                if (method != null) {
                    method.isAccessible = true
                    method.invoke(instance, context, accepted)
                    attempts.add("$clsName.setPrivacyPolicyStrategy=OK")
                } else {
                    attempts.add("$clsName.setPrivacyPolicyStrategy=not found")
                }
            } catch (e: Throwable) {
                attempts.add("$clsName=ERR:${e.javaClass.simpleName}")
            }
        }
        val log = attempts.joinToString(" | ")
        Log.d(TAG, "privacy: $log")
        appendSdkLog("privacy: $log")
    }

    /**
     * 按个推官方顺序初始化：preInit → registerPushIntentService(FlutterIntentService)
     * → initialize(context, FlutterPushService)。任一步失败都记录到 push_native_init_log。
     */
    private fun initGetuiSdkProperly(context: Context, fullInit: Boolean = true) {
        val steps = mutableListOf<String>()
        try {
            val pmCls = Class.forName("com.igexin.sdk.PushManager")
            val pm = pmCls.getMethod("getInstance").invoke(null)
            if (pm == null) {
                nativeInitLog = "PushManager.getInstance()=null"
                writeSp(KEY_NATIVE_INIT, nativeInitLog)
                return
            }

            // 0) preInit：官方要求「先 preInit 再 initialize」，否则部分 ROM 上 CID 注册失败。
            try {
                val pre = pmCls.declaredMethods.firstOrNull {
                    it.name == "preInit" && it.parameterCount == 1
                }
                if (pre != null) {
                    pre.isAccessible = true
                    pre.invoke(pm, context)
                    steps.add("preInit=OK")
                } else {
                    steps.add("preInit=方法未找到")
                }
            } catch (e: Throwable) {
                steps.add("preInit=ERR:${e.javaClass.simpleName}")
            }

            // 🔴 N-02：未同意隐私政策 → 到 preInit 为止（官方允许的合规路径），
            // 不做 registerPushIntentService / initialize —— 那才是真正注册 CID 的动作。
            if (!fullInit) {
                steps.add("已停止：等待用户同意隐私政策")
                nativeInitLog = steps.joinToString(" | ")
                writeSp(KEY_NATIVE_INIT, nativeInitLog)
                Log.d(TAG, "initGetuiSdkProperly: 仅 preInit（未同意隐私政策）")
                return
            }

            // 1) 注册回调桥梁：CID / 消息回调经此转发到 Flutter（onReceiveClientId 才生效）。
            try {
                val intentSvcCls = Class.forName("com.getui.getuiflut.FlutterIntentService")
                val m = pmCls.declaredMethods.firstOrNull {
                    it.name == "registerPushIntentService" && it.parameterCount == 2
                }
                if (m != null) {
                    m.isAccessible = true
                    m.invoke(pm, context, intentSvcCls)
                    steps.add("registerPushIntentService=OK")
                } else {
                    steps.add("registerPushIntentService=方法未找到")
                }
            } catch (e: Throwable) {
                steps.add("registerPushIntentService=ERR:${e.javaClass.simpleName}:${e.message}")
            }

            // 2) 关键：双参数 initialize，显式指定 manifest 已声明的 FlutterPushService。
            try {
                val pushSvcCls = Class.forName("com.getui.getuiflut.FlutterPushService")
                val m2 = pmCls.declaredMethods.firstOrNull {
                    it.name == "initialize" && it.parameterCount == 2
                }
                if (m2 != null) {
                    m2.isAccessible = true
                    m2.invoke(pm, context, pushSvcCls)
                    steps.add("initialize(Context,FlutterPushService)=OK")
                } else {
                    val m1 = pmCls.declaredMethods.firstOrNull {
                        it.name == "initialize" && it.parameterCount == 1
                    }
                    if (m1 != null) {
                        m1.isAccessible = true
                        m1.invoke(pm, context)
                        steps.add("initialize(Context)=降级调用")
                    } else {
                        steps.add("initialize=方法未找到")
                    }
                }
            } catch (e: Throwable) {
                steps.add("initialize=ERR:${e.javaClass.simpleName}:${e.message}")
            }
        } catch (e: Throwable) {
            steps.add("fatal:${e.javaClass.simpleName}:${e.message}")
        }
        nativeInitLog = steps.joinToString(" | ")
        writeSp(KEY_NATIVE_INIT, nativeInitLog)
        Log.d(TAG, "initGetuiSdkProperly: $nativeInitLog")
    }
}
