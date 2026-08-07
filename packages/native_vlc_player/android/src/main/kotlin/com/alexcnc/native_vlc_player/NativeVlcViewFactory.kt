package com.alexcnc.native_vlc_player

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Factory that creates one [NativeVlcView] per embedded platform view.
 * Each view owns its libVLC instance and a dedicated MethodChannel named
 * `native_vlc_player_<viewId>`.
 */
class NativeVlcViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return NativeVlcView(context, messenger, viewId)
    }
}
