package com.alexcnc.native_vlc_player

import android.content.Context
import android.graphics.Color
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import io.flutter.plugin.platform.PlatformView

/**
 * 播放器创建失败时的降级视图。
 *
 * 存在的唯一理由：`PlatformViewFactory.create()` 里抛出的任何 Throwable 都会变成
 * Android 主线程的未捕获异常，直接杀掉进程 —— 用户看到的就是"一点实时预览就闪退"。
 * 与其闪退，不如在原地渲染一段可读的错误说明，让问题变成可见、可反馈的信息。
 */
class ErrorPlatformView(context: Context, message: String) : PlatformView {

    private val root: View = FrameLayout(context).apply {
        setBackgroundColor(Color.parseColor("#0A0A0A"))
        addView(
            TextView(context).apply {
                text = message
                setTextColor(Color.parseColor("#FF6B6B"))
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(32, 32, 32, 32)
            },
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
    }

    override fun getView(): View = root

    override fun dispose() {
        // 纯静态视图，无资源需要释放。
    }
}
