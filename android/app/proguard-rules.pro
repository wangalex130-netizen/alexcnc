# ===========================================================================
# libVLC (org.videolan.android:libvlc-all)
#
# libVLC 的 native 库在 JNI_OnLoad 里用 FindClass / GetFieldID / GetMethodID
# 按【字符串名字】把一整套 Java 侧的类、字段、回调方法缓存下来，例如：
#   org/videolan/libvlc/MediaPlayer$Event
#   org/videolan/libvlc/Media
#   org/videolan/libvlc/interfaces/IVLCVout
#   org/videolan/libvlc/util/VLCVideoLayout
#
# 这些成员在 Java/Kotlin 代码里"看不出被谁调用"，R8 会判定为可重命名甚至可裁剪。
# 一旦被动过，native 侧查符号失败 -> NoClassDefFoundError / UnsatisfiedLinkError
# -> 在 PlatformViewFactory.create() 里冒泡成主线程未捕获异常 -> 应用闪退。
#
# 结论：org.videolan 整个包必须原样保留，不混淆、不裁剪、不优化。
# ===========================================================================
-keep class org.videolan.** { *; }
-keep interface org.videolan.** { *; }
-keepclassmembers class org.videolan.** { *; }
-dontwarn org.videolan.**

# 本地插件由 Flutter 的 GeneratedPluginRegistrant 反射实例化，需保留入口类。
-keep class com.alexcnc.native_vlc_player.** { *; }

# Flutter 引擎与插件注册同样走反射。
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# 保留 native 方法签名（任何被 JNI 调用的方法都不能改名）。
-keepclasseswithmembernames class * {
    native <methods>;
}
