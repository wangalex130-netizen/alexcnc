package com.alexcnc.native_vlc_player

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Flutter plugin entry point. Registers the native VLC video view factory so
 * Dart code can embed it via [AndroidView].
 */
class NativeVlcPlayerPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(
            "native_vlc_player",
            NativeVlcViewFactory(binding.binaryMessenger)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Cleanup is per-view in NativeVlcView.dispose().
    }
}
