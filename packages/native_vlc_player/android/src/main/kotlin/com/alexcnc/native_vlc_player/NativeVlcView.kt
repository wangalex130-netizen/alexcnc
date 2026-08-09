package com.alexcnc.native_vlc_player

import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.IVLCVout
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

private const val TAG = "NativeVlcView"

/**
 * 把 libVLC 的 [VLCVideoLayout] + [MediaPlayer] 包成一个 Flutter 平台视图。
 *
 * ============================================================
 * 【本次根治的 BUG：libVLC 的"假 Stopped 事件"】
 * ============================================================
 * libVLC 3.x 的 `libvlc_media_player_stop()` 实现是：
 *
 *     if (state != libvlc_Stopped) { set_state(Stopped); send(MediaPlayerStopped); }
 *
 * 一个**全新**的 MediaPlayer 初始状态是 `libvlc_NothingSpecial`（不是 Stopped），
 * 所以只要调用一次 `stop()`，libVLC 就会立刻抛出一个 **MediaPlayerStopped 事件** ——
 * 哪怕它从来没播放过任何东西。
 *
 * 原来的 doPlay() 为了避免 "Can't set view when already attached"，在 play 之前
 * 无条件先 `stop() + detachViews()`，于是每次播放都会先收到一个假的 Stopped。
 *
 * 在纯原生的 camera-test-app 里，这个假事件只是把状态文字刷成"已停止"，
 * 紧接着 Opening/Playing 就把它覆盖了，用户完全无感 —— 所以模拟 APP 一直能用。
 *
 * 但主 APP 的 Flutter 侧有一套"连接状态机"，它把 connecting 期间收到的 stopped
 * 判定为**本次尝试失败**，于是每一次尝试都在真正连上摄像头之前就被自己掐断，
 * 一路 /11 → /12 → 重新扫描 → 全部"失败"，最后报「最后错误：播放已停止」。
 *
 * 修复策略（双保险）：
 *   1. 首次播放不调用 stop()（新播放器本来就不需要停），从源头不产生假事件；
 *   2. 之后的换流必须 stop() 时，开一个 [ignoreStopUntilMs] 抑制窗口，
 *      窗口内的 Stopped/EndReached 一律视为自己造成的噪声，不上报 Flutter。
 *   3. 每次播放带一个自增的 [generation]，事件回传时附带，Flutter 侧可丢弃过期事件。
 *
 * 【稳定性约定】构造函数绝不允许抛异常：容器 [container] 一定创建成功，
 * libVLC 每一步单独兜底，失败原因写进 [initError] 并直接画在画面上。
 */
class NativeVlcView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int
) : PlatformView, MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "native_vlc_player_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 永远可用的宿主容器，"绝不闪退"的地基。 */
    private val container = FrameLayout(context).apply {
        setBackgroundColor(Color.parseColor("#0A0A0A"))
    }

    private var videoLayout: VLCVideoLayout? = null
    private var libVLC: LibVLC? = null
    private var mediaPlayer: MediaPlayer? = null

    /** 初始化阶段的失败原因，供 Flutter 侧与画面展示。 */
    private var initError: String? = null

    /** 等待播放的地址（视图尚未 layout 完成时暂存）。 */
    private var pendingUrl: String? = null
    private var isDisposed = false

    /** 是否已经真正 attach/play 过一次 —— 决定要不要在播放前先 stop()。 */
    private var hasPlayedOnce = false

    /** 抑制窗口：在这个时间点之前收到的 Stopped/EndReached 都是我们自己 stop() 造成的。 */
    private var ignoreStopUntilMs = 0L

    /** 本次播放会话号，随每次 doPlay 自增，用于让 Flutter 丢弃过期事件。 */
    private var generation = 0

    /** 本会话是否已经收到过 Playing。 */
    private var sawPlaying = false

    /** 延迟重试播放的 Runnable（不用 postDelayed(token) —— 那是 API 28+ 才有的重载）。 */
    private val deferRunnable = Runnable { tryStartPlayback() }

    init {
        channel.setMethodCallHandler(this)

        // ---- 1) 视频承载层 ----
        runCatching {
            val layout = VLCVideoLayout(context)
            videoLayout = layout
            container.addView(layout, matchParent())
        }.onFailure {
            Log.e(TAG, "VLCVideoLayout 创建失败", it)
            recordInitError("视频层创建失败", it)
        }

        // ---- 2) libVLC 实例（参数与 camera-test-app 完全一致）----
        libVLC = runCatching {
            LibVLC(
                context,
                arrayListOf(
                    "--rtsp-tcp",
                    "--network-caching=150",
                    "--live-caching=150",
                    "--avcodec-hw=any",
                    "--drop-late-frames",
                    "--skip-frames",
                    // 实时流禁用音视频时钟同步，立即渲染最新帧，显著降低延迟与卡顿。
                    "--clock-synchro=0",
                    "--clock-jitter=0",
                    "--no-audio",
                    "--no-video-title-show",
                    "--verbose=1"
                )
            )
        }.onFailure {
            Log.e(TAG, "LibVLC 初始化失败", it)
            recordInitError("LibVLC 初始化失败", it)
        }.getOrNull()

        // ---- 3) MediaPlayer ----
        mediaPlayer = libVLC?.let { vlc ->
            runCatching { MediaPlayer(vlc) }
                .onFailure {
                    Log.e(TAG, "MediaPlayer 创建失败", it)
                    recordInitError("MediaPlayer 创建失败", it)
                }
                .getOrNull()
        }

        runCatching {
            mediaPlayer?.setEventListener { event ->
                // 事件可能来自 libVLC 的工作线程，统一切回主线程处理。
                val type = event.type
                mainHandler.post { handlePlayerEvent(type) }
            }
        }.onFailure {
            Log.e(TAG, "注册播放事件监听失败", it)
            recordInitError("事件监听注册失败", it)
        }

        // 监听视频尺寸变化，每次变化都重新按容器比例铺满。
        runCatching {
            mediaPlayer?.vlcVout?.addCallback(object : IVLCVout.Callback {
                override fun onSurfacesCreated(vout: IVLCVout?) {}
                override fun onSurfacesDestroyed(vout: IVLCVout?) {}
                override fun onNewVideoLayout(
                    vout: IVLCVout?,
                    width: Int,
                    height: Int,
                    visibleWidth: Int,
                    visibleHeight: Int,
                    sarNum: Int,
                    sarDen: Int
                ) {
                    mainHandler.post { applyFill() }
                }
            })
        }.onFailure {
            Log.e(TAG, "注册视频布局监听失败", it)
            recordInitError("视频布局监听注册失败", it)
        }

        // 容器一旦挂到窗口且有有效尺寸就尝试播放（Surface/Texture 此时才就绪）。
        container.addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
            runCatching {
                if (right - left > 0 && bottom - top > 0 && container.isAttachedToWindow) {
                    applyFill()
                    tryStartPlayback()
                }
            }.onFailure { Log.e(TAG, "layout 回调异常", it) }
        }

        initError?.let { showOverlayMessage(it) }
    }

    private fun matchParent() = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
    )

    /** 按容器尺寸强制铺满（牺牲比例或裁剪黑边，不留白边）。 */
    private fun applyFill() {
        runCatching {
            val mp = mediaPlayer ?: return
            val w = container.width
            val h = container.height
            if (w <= 0 || h <= 0) return
            // 把显示窗口设为容器大小，并把视频比例强制设为容器比例，
            // 这样 libVLC 会拉伸/裁剪画面以完全填满容器。
            mp.setWindowSize(w, h)
            mp.setAspectRatio("$w:$h")
        }.onFailure { Log.e(TAG, "applyFill failed", it) }
    }

    private fun recordInitError(stage: String, t: Throwable) {
        if (initError == null) {
            initError = "$stage：${t::class.java.simpleName} ${t.message ?: ""}".trim()
        }
    }

    private fun showOverlayMessage(text: String) {
        runCatching {
            val tv = TextView(container.context).apply {
                setText(text)
                setTextColor(Color.parseColor("#FF6B6B"))
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(32, 32, 32, 32)
            }
            container.addView(tv, matchParent())
        }
    }

    override fun getView(): View = container

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        runCatching {
            when (call.method) {
                "play" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("BAD_URL", "url is null or blank", null)
                        return
                    }
                    play(url)
                    result.success(null)
                }
                "stop" -> {
                    stop(userRequested = true)
                    result.success(null)
                }
                "dispose" -> {
                    dispose()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }.onFailure { t ->
            Log.e(TAG, "onMethodCall(${call.method}) 异常", t)
            runCatching { result.error("NATIVE_ERROR", t.message, null) }
        }
    }

    /** 收到播放指令只暂存 URL，真正启动交给 [tryStartPlayback]（等 layout 完成）。 */
    private fun play(url: String) {
        if (isDisposed) return
        Log.d(TAG, "play requested: $url")
        pendingUrl = url
        tryStartPlayback()
    }

    private fun tryStartPlayback() {
        if (isDisposed) return
        val url = pendingUrl ?: return

        if (container.width <= 0 || container.height <= 0 || !container.isAttachedToWindow) {
            Log.d(
                TAG,
                "view not ready (w=${container.width} h=${container.height} attached=${container.isAttachedToWindow}), defer"
            )
            mainHandler.removeCallbacks(deferRunnable)
            mainHandler.postDelayed(deferRunnable, 100)
            return
        }

        pendingUrl = null
        mainHandler.removeCallbacks(deferRunnable)
        doPlay(url)
    }

    private fun doPlay(url: String) {
        val mp = mediaPlayer
        val vlc = libVLC
        val layout = videoLayout
        if (mp == null || vlc == null || layout == null) {
            sendEvent("error", mapOf("message" to (initError ?: "播放器未初始化")))
            return
        }

        generation += 1
        sawPlaying = false

        runCatching {
            // 【关键】只有真正播放过才需要 stop()。
            // 对全新的 MediaPlayer 调 stop() 会立刻抛出一个假的 Stopped 事件，
            // 那正是主 APP 一直"播放已停止"的元凶。
            if (hasPlayedOnce) {
                // 换流时确实要先停，但开一个抑制窗口过滤掉自己造成的 Stopped。
                ignoreStopUntilMs = SystemClock.uptimeMillis() + 1500
                mp.stop()
                mp.detachViews()
            }

            val media = Media(vlc, Uri.parse(url))
            mp.media = media
            // useTextureView=true：渲染到 TextureView。
            // 关键修复：SurfaceView 在 Flutter Hybrid Composition 平台视图里首帧合成不稳定，
            // 常黑屏/卡住、必须退出重进才动；TextureView 随普通 View 合成，首帧立即出现，
            // 根治「退出重进才动」与首帧卡顿。
            mp.attachViews(layout, null, true, false)
            applyFill()
            media.release()

            Log.d(TAG, "starting playback (gen=$generation): $url")
            mp.play()
            hasPlayedOnce = true

            // 播放看门狗：8 秒还没 Playing，就把播放器内部状态报给 Flutter，
            // 让错误信息有据可查（而不是笼统的"播放失败"）。
            scheduleWatchdog(generation, url)
        }.onFailure { e ->
            Log.e(TAG, "play failed: $url", e)
            sendEvent("error", mapOf("message" to "启动播放失败：${e.message ?: e::class.java.simpleName}"))
        }
    }

    private fun scheduleWatchdog(gen: Int, url: String) {
        mainHandler.postDelayed({
            if (isDisposed || gen != generation || sawPlaying) return@postDelayed
            val state = runCatching { mediaPlayer?.playerState?.toString() ?: "?" }.getOrDefault("?")
            Log.w(TAG, "watchdog: 8s 未进入 Playing, state=$state url=$url")
            sendEvent(
                "stalled",
                mapOf("message" to "8 秒未出画面（播放器状态 $state）")
            )
        }, 8000)
    }

    private fun stop(userRequested: Boolean) {
        pendingUrl = null
        mainHandler.removeCallbacks(deferRunnable)
        if (!userRequested) ignoreStopUntilMs = SystemClock.uptimeMillis() + 1500
        runCatching {
            mediaPlayer?.stop()
            mediaPlayer?.detachViews()
        }.onFailure { Log.e(TAG, "stop failed", it) }
    }

    private fun handlePlayerEvent(type: Int) {
        runCatching {
            when (type) {
                MediaPlayer.Event.Opening -> sendEvent("opening")
                MediaPlayer.Event.Buffering -> sendEvent("buffering")
                MediaPlayer.Event.Playing -> {
                    sawPlaying = true
                    sendEvent("playing")
                }
                MediaPlayer.Event.Stopped, MediaPlayer.Event.EndReached -> {
                    // 抑制窗口内的停止事件 = 我们自己 stop() 造成的噪声，直接丢弃。
                    if (SystemClock.uptimeMillis() < ignoreStopUntilMs) {
                        Log.d(TAG, "忽略自触发的 Stopped/EndReached（抑制窗口内）")
                        return@runCatching
                    }
                    // 从未进入过 Playing 的 Stopped 同样不可信（libVLC 打开流失败时
                    // 会先发 EncounteredError，真失败不会漏报）。交给上层超时判定。
                    if (!sawPlaying) {
                        Log.d(TAG, "忽略未播放过就到达的 Stopped（gen=$generation）")
                        return@runCatching
                    }
                    sendEvent(if (type == MediaPlayer.Event.EndReached) "endReached" else "stopped")
                }
                MediaPlayer.Event.EncounteredError -> {
                    sendEvent(
                        "error",
                        mapOf("message" to "libVLC 打开流失败（地址/账号密码/码流路径不对，或摄像头拒绝连接）")
                    )
                }
            }
        }.onFailure { Log.e(TAG, "handlePlayerEvent failed", it) }
    }

    private fun sendEvent(name: String, args: Map<String, Any?> = emptyMap()) {
        if (isDisposed) return
        runCatching {
            val payload = HashMap<String, Any?>(args)
            payload["event"] = name
            payload["generation"] = generation
            channel.invokeMethod("onEvent", payload)
        }.onFailure { Log.e(TAG, "sendEvent($name) failed", it) }
    }

    override fun dispose() {
        if (isDisposed) return
        isDisposed = true
        mainHandler.removeCallbacks(deferRunnable)
        mainHandler.removeCallbacksAndMessages(null)
        runCatching { channel.setMethodCallHandler(null) }
        runCatching {
            mediaPlayer?.setEventListener(null)
            mediaPlayer?.stop()
            mediaPlayer?.detachViews()
            mediaPlayer?.release()
            libVLC?.release()
        }.onFailure { Log.e(TAG, "dispose failed", it) }
        mediaPlayer = null
        libVLC = null
        videoLayout = null
    }
}
