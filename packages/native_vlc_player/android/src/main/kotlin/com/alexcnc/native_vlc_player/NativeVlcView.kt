package com.alexcnc.native_vlc_player

import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
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
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

private const val TAG = "NativeVlcView"

/**
 * A single platform view that wraps libVLC's [VLCVideoLayout] and [MediaPlayer].
 *
 * 与 camera-test-app 一致的原生实现：
 *   - LibVLC 低延迟参数 + RTP over TCP。
 *   - MediaPlayer 挂到 VLCVideoLayout（TextureView）。
 *   - 事件回主线程后转发给 Flutter。
 *
 * 【稳定性约定】这个类的构造函数不允许把异常放跑出去以外的任何形式崩溃：
 * 承载容器 [container] 一定创建成功，libVLC 相关的每一步都单独兜底，
 * 失败时把原因记进 [initError] 并直接画在画面上。
 */
class NativeVlcView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int
) : PlatformView, MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "native_vlc_player_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 永远可用的宿主容器。即使 libVLC 的类一个都加载不出来，
     * getView() 依然能返回一个合法 View —— 这是"绝不闪退"的地基。
     */
    private val container = FrameLayout(context).apply {
        setBackgroundColor(Color.parseColor("#0A0A0A"))
    }

    private var videoLayout: VLCVideoLayout? = null
    private var libVLC: LibVLC? = null
    private var mediaPlayer: MediaPlayer? = null

    /** 初始化阶段的失败原因，供 Flutter 侧与画面展示。 */
    private var initError: String? = null

    /**
     * Flutter 侧传下来的待播放地址。
     * 平台视图被创建时往往还没有 attach 到窗口、也没有完成 layout，
     * 此时 libVLC 的 Surface/TextureView 尚未就绪，直接 play() 会立即收到
     * Stopped/EncounteredError。因此我们先把地址存起来，等容器真正可见、
     * 宽高都大于 0 后再开始播放。
     */
    private var pendingUrl: String? = null
    private var isDisposed = false

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

        // ---- 2) libVLC 实例 ----
        libVLC = runCatching {
            LibVLC(
                context,
                arrayListOf(
                    "--rtsp-tcp",
                    "--network-caching=100",
                    "--live-caching=100",
                    "--avcodec-hw=any",
                    "--drop-late-frames",
                    "--skip-frames",
                    "--no-audio",
                    // 打印详细日志到 logcat，便于排查播放失败真实原因。
                    "--verbose=2"
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
                mainHandler.post { handlePlayerEvent(event) }
            }
        }.onFailure {
            Log.e(TAG, "注册播放事件监听失败", it)
            recordInitError("事件监听注册失败", it)
        }

        // 监听容器尺寸/附加状态：一旦视图挂到窗口且有有效大小，就尝试播放。
        container.addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
            if (right - left > 0 && bottom - top > 0 && container.isAttachedToWindow) {
                tryStartPlayback()
            }
        }

        // 初始化没成功就把原因画到画面上，让问题可见、可反馈，而不是黑屏或闪退。
        initError?.let { showOverlayMessage(it) }
    }

    private fun matchParent() = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
    )

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
        // 方法回调同样全程兜底：任何未捕获异常都会被 Flutter 引擎转成崩溃。
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
                    stop()
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

    /**
     * 收到播放指令后只暂存 URL，真正启动交给 [tryStartPlayback]，
     * 等视图 attach + layout 完成后再执行。
     */
    private fun play(url: String) {
        if (isDisposed) return
        Log.d(TAG, "play requested: $url")
        pendingUrl = url
        tryStartPlayback()
    }

    private fun tryStartPlayback() {
        if (isDisposed) return
        val url = pendingUrl ?: return

        // 视图未挂到窗口或尺寸为 0 时，Surface/Texture 还没准备好，
        // 强行播放 libVLC 会立即 stop。这里延迟重试，最多等 3 秒。
        if (container.width <= 0 || container.height <= 0 || !container.isAttachedToWindow) {
            Log.d(TAG, "view not ready yet (w=${container.width} h=${container.height} attached=${container.isAttachedToWindow}), defer play")
            mainHandler.removeCallbacksAndMessages(DEFER_TOKEN)
            mainHandler.postDelayed({ tryStartPlayback() }, DEFER_TOKEN, 100)
            return
        }

        pendingUrl = null
        mainHandler.removeCallbacksAndMessages(DEFER_TOKEN)
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

        runCatching {
            // 重新 attach 前先 stop + detach，避免 "Can't set view when already attached"。
            mp.stop()
            mp.detachViews()

            val media = Media(vlc, Uri.parse(url))
            mp.media = media
            // textureView=true：渲染到 TextureView，在 Flutter 平台视图里合成更稳。
            mp.attachViews(layout, null, false, true)
            media.release()
            Log.d(TAG, "starting playback: $url")
            mp.play()
        }.onFailure { e ->
            Log.e(TAG, "play failed: $url", e)
            sendEvent("error", mapOf("message" to (e.message ?: "启动播放失败")))
        }
    }

    private fun stop() {
        pendingUrl = null
        mainHandler.removeCallbacksAndMessages(DEFER_TOKEN)
        runCatching {
            mediaPlayer?.stop()
            mediaPlayer?.detachViews()
        }.onFailure { Log.e(TAG, "stop failed", it) }
    }

    private fun handlePlayerEvent(event: MediaPlayer.Event) {
        runCatching {
            Log.d(TAG, "event type=${event.type} length=${event.lengthChanged} time=${event.timeChanged}")
            when (event.type) {
                MediaPlayer.Event.Opening -> sendEvent("opening")
                MediaPlayer.Event.Buffering -> sendEvent("buffering")
                MediaPlayer.Event.Playing -> sendEvent("playing")
                MediaPlayer.Event.Stopped -> sendEvent("stopped")
                MediaPlayer.Event.EndReached -> sendEvent("endReached")
                MediaPlayer.Event.EncounteredError -> {
                    sendEvent("error", mapOf("message" to "无法连接摄像头，或该流格式不受支持"))
                }
            }
        }.onFailure { Log.e(TAG, "handlePlayerEvent failed", it) }
    }

    private fun sendEvent(name: String, args: Map<String, Any?> = emptyMap()) {
        runCatching {
            val payload = HashMap<String, Any?>(args)
            payload["event"] = name
            channel.invokeMethod("onEvent", payload)
        }.onFailure { Log.e(TAG, "sendEvent($name) failed", it) }
    }

    override fun dispose() {
        isDisposed = true
        mainHandler.removeCallbacksAndMessages(DEFER_TOKEN)
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

    companion object {
        /** 用于延迟播放重试的 Handler token，便于 dispose 时一次性清掉。 */
        private const val DEFER_TOKEN = 0x564C43 // "VLC"
    }
}
