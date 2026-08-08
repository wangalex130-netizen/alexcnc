plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.alexcnc.alexcnc"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.alexcnc.alexcnc"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // libvlc-all 自带 4 种 ABI 的 .so，占了 APK 绝大部分体积。
        // 真机只需要这两种；去掉 x86/x86_64 后安装包大约减半。
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            signingConfig = signingConfigs.getByName("debug")

            // ===================================================================
            // 【闪退根因修复】
            // Flutter 的 release 构建默认会跑 R8（构建日志里可见
            // `> Task :app:minifyReleaseWithR8` 与 `:app:shrinkReleaseRes`）。
            //
            // libVLC 的 native 层在 JNI_OnLoad 阶段通过【类名 / 方法名 / 字段名】
            // 反射定位 org.videolan.** 下的 Java 成员并缓存 jclass/jmethodID。
            // R8 一旦把这些名字改掉或把"看似没人引用"的成员裁掉，native 侧就找不
            // 到符号：构造 VLCVideoLayout / LibVLC 时抛 NoClassDefFoundError，
            // 该异常从 PlatformViewFactory.create() 冒泡成主线程未捕获异常
            // —— 用户看到的现象就是"一点实时预览就闪退"。
            //
            // 这里直接关掉代码与资源压缩；同时仍挂上 proguard-rules.pro，
            // 万一将来重新开启压缩，keep 规则也能继续保护 libVLC。
            // ===================================================================
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}
