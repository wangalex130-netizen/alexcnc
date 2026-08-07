package com.alexcnc.native_vlc_player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
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
 * This is the exact same approach used by the standalone camera-test-app:
 *   - LibVLC with low-latency options and RTP-over-TCP.
 *   - MediaPlayer attached to a VLCVideoLayout (TextureView).
 *   - Events posted back to the main thread and forwarded to Flutter.
 *
 * Keeping it native avoids the `LateInitializationError(_viewId)` crash that
 * comes from flutter_vlc_player's Flutter-side controller initializing before
 * the underlying Android Surface/Texture is ready.
 */
class NativeVlcView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int
) : PlatformView, MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "native_vlc_player_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())

    private val libVLC: LibVLC?
    private val mediaPlayer: MediaPlayer?
    private val videoLayout: VLCVideoLayout

    init {
        channel.setMethodCallHandler(this)
        videoLayout = VLCVideoLayout(context)

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
                    "--no-audio"
                )
            )
        }.onFailure { Log.e(TAG, "LibVLC init failed", it) }.getOrNull()

        mediaPlayer = libVLC?.let { vlc ->
            runCatching { MediaPlayer(vlc) }
                .onFailure { Log.e(TAG, "MediaPlayer create failed", it) }
                .getOrNull()
        }

        mediaPlayer?.setEventListener { event ->
            mainHandler.post { handlePlayerEvent(event) }
        }
    }

    override fun getView(): View = videoLayout

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
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
    }

    private fun play(url: String) {
        val mp = mediaPlayer ?: run {
            sendEvent("error", mapOf("message" to "播放器未初始化"))
            return
        }
        val vlc = libVLC ?: run {
            sendEvent("error", mapOf("message" to "LibVLC 未初始化"))
            return
        }

        runCatching {
            // Stop and detach before re-attaching to avoid
            // "Can't set view when already attached".
            mp.stop()
            mp.detachViews()

            val media = Media(vlc, Uri.parse(url))
            mp.media = media
            videoLayout.let { layout ->
                // textureView=true: render onto a TextureView (better compositing
                // inside Flutter's platform view).
                mp.attachViews(layout, null, false, true)
            }
            media.release()
            mp.play()
        }.onFailure { e ->
            Log.e(TAG, "play failed: $url", e)
            sendEvent("error", mapOf("message" to (e.message ?: "启动播放失败")))
        }
    }

    private fun stop() {
        runCatching {
            mediaPlayer?.stop()
            mediaPlayer?.detachViews()
        }.onFailure { Log.e(TAG, "stop failed", it) }
    }

    private fun handlePlayerEvent(event: MediaPlayer.Event) {
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
    }

    private fun sendEvent(name: String, args: Map<String, Any?> = emptyMap()) {
        val payload = HashMap<String, Any?>(args)
        payload["event"] = name
        channel.invokeMethod("onEvent", payload)
    }

    override fun dispose() {
        channel.setMethodCallHandler(null)
        runCatching {
            mediaPlayer?.setEventListener(null)
            mediaPlayer?.stop()
            mediaPlayer?.detachViews()
            mediaPlayer?.release()
            libVLC?.release()
        }.onFailure { Log.e(TAG, "dispose failed", it) }
    }
}
