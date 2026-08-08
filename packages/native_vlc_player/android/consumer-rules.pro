# 随插件一起分发的 ProGuard 规则：任何引用 native_vlc_player 的 App 在开启
# R8 时都会自动合并这些规则，不需要各自再手写一遍 keep。
#
# 原因见 android/app/proguard-rules.pro 的说明：libVLC 通过 JNI 按名字反射
# 定位 org.videolan.** 下的成员，被混淆或裁剪后会导致运行时闪退。
-keep class org.videolan.** { *; }
-keep interface org.videolan.** { *; }
-keepclassmembers class org.videolan.** { *; }
-dontwarn org.videolan.**

-keep class com.alexcnc.native_vlc_player.** { *; }

-keepclasseswithmembernames class * {
    native <methods>;
}
