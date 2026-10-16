package com.lamb.feifei

import android.os.Build
import android.os.Bundle
import android.view.ViewTreeObserver
import android.view.WindowManager
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 管理全面屏并提供实际窗口旋转角，避免工程锁屏后拍照与取景方向不一致。 */
class MainActivity : FlutterActivity() {
    private var displayChannel: MethodChannel? = null
    private var keyboardVisible = false
    private val restoreFullscreen = Runnable { applyFullscreen() }
    private val keyboardListener = ViewTreeObserver.OnGlobalLayoutListener {
        val visible = ViewCompat.getRootWindowInsets(window.decorView)
            ?.isVisible(WindowInsetsCompat.Type.ime()) == true
        if (keyboardVisible && !visible) {
            // Android 对键盘关闭后的系统栏控制有短暂限制，延后一次恢复即可。
            window.decorView.removeCallbacks(restoreFullscreen)
            window.decorView.postDelayed(restoreFullscreen, 1100)
        }
        keyboardVisible = visible
    }

    /** 只补充包未暴露的窗口旋转查询；相机能力仍全部通过 camerax 接口调用。 */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        displayChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.lamb.feifei/display").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "rotation") {
                    result.notImplemented()
                } else {
                    val rotation = window.decorView.display?.rotation
                    if (rotation == null) {
                        result.error("display_unavailable", "当前窗口未连接显示器，请稍后重试", null)
                    } else {
                        result.success(rotation)
                    }
                }
            }
        }
    }

    /** 引擎与 Activity 分离时解除回调，避免通道继续持有已销毁窗口。 */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        displayChannel?.setMethodCallHandler(null)
        displayChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** 让背景延伸到挖孔区域，并只注册一个键盘布局观察者；按钮避让交给 Flutter。 */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
        }
        window.decorView.viewTreeObserver.addOnGlobalLayoutListener(keyboardListener)
        applyFullscreen()
    }

    /** 从系统选择器、权限弹窗或后台返回时恢复全面屏。 */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyFullscreen()
    }

    /** 隐藏系统栏；边缘滑动仍可临时呼出系统导航，不干扰正在显示的键盘。 */
    private fun applyFullscreen() {
        if (isFinishing || isDestroyed || !window.decorView.hasWindowFocus()) return
        val insets = ViewCompat.getRootWindowInsets(window.decorView)
        if (insets?.isVisible(WindowInsetsCompat.Type.ime()) == true) return
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    /** 销毁窗口时移除延迟任务和观察者，避免继续持有 Activity。 */
    override fun onDestroy() {
        window.decorView.removeCallbacks(restoreFullscreen)
        window.decorView.viewTreeObserver.removeOnGlobalLayoutListener(keyboardListener)
        super.onDestroy()
    }
}
