package com.alexcnc.native_vlc_player

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

private const val TAG = "NativeVlcViewFactory"

/**
 * Factory that creates one [NativeVlcView] per embedded platform view.
 * Each view owns its libVLC instance and a dedicated MethodChannel named
 * `native_vlc_player_<viewId>`.
 */
class NativeVlcViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        // 这里必须吞掉所有 Throwable（包含 NoClassDefFoundError / UnsatisfiedLinkError
        // 这类 Error，它们不是 Exception，普通 catch (e: Exception) 抓不到）。
        // create() 一旦抛出，异常会冒泡到 Flutter 的 PlatformViewsController，
        // 最终成为主线程未捕获异常 —— 表现为应用瞬间闪退且无任何提示。
        return try {
            NativeVlcView(context, messenger, viewId)
        } catch (t: Throwable) {
            Log.e(TAG, "原生播放器创建失败，降级为错误占位视图", t)
            ErrorPlatformView(
                context,
                "播放器初始化失败\n${t::class.java.simpleName}\n${t.message ?: "无附加信息"}"
            )
        }
    }
}
