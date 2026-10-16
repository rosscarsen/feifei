package dev.zeekr.camerax_android

import androidx.camera.core.ImageProxy
import dev.zeekr.camerax_android.common.PermissionManager
import dev.zeekr.camerax_android.common.ViewFactory
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/** 保留上游相机实现，仅补充逐张图像的实际传感器变换查询。 */
class CameraXAndroidPlugin : FlutterPlugin, ActivityAware {
    private lateinit var registrar: CameraXApiPigeonProxyApiRegistrar
    private var imageGeometryChannel: MethodChannel? = null

    /** 注册原有代理及只读矩阵接口；图片仍由 Dart 拍摄流程负责关闭。 */
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val binaryMessenger = binding.binaryMessenger
        val context = binding.applicationContext
        registrar = CameraXRegistrarImpl(binaryMessenger, context)
        registrar.setUp()
        imageGeometryChannel = MethodChannel(binaryMessenger, "camerax.zeekr.dev/imageGeometry").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "sensorToBuffer") {
                    result.notImplemented()
                } else {
                    val identifier = (call.arguments as? Number)?.toLong()
                    val image = identifier?.let { registrar.instanceManager.getInstance<ImageProxy>(it) }
                    if (image == null) {
                        result.error("image_unavailable", "照片代理已失效", null)
                    } else {
                        val values = FloatArray(9)
                        image.imageInfo.sensorToBufferTransformMatrix.getValues(values)
                        result.success(values.map { it.toDouble() })
                    }
                }
            }
        }
        val viewRegistry = binding.platformViewRegistry
        val viewTypeId = "camerax.zeekr.dev/PreviewView"
        val viewFactory = ViewFactory(registrar.instanceManager)
        viewRegistry.registerViewFactory(viewTypeId, viewFactory)
        viewRegistry.registerViewFactory("$viewTypeId.TLHC", viewFactory)
    }

    /** 解除扩展回调并执行上游释放，避免通道继续持有已分离的插件实例。 */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        imageGeometryChannel?.setMethodCallHandler(null)
        imageGeometryChannel = null
        registrar.tearDown()
        registrar.instanceManager.stopFinalizationListener()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        PermissionManager.onAttachedToActivity(binding)
        registrar.onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        PermissionManager.onDetachedFromActivityForConfigChanges()
        registrar.onDetachedFromActivityForConfigChanges()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        PermissionManager.onReattachedToActivityForConfigChanges(binding)
        registrar.onReattachedToActivityForConfigChanges(binding)
    }

    override fun onDetachedFromActivity() {
        PermissionManager.onDetachedFromActivity()
        registrar.onDetachedFromActivity()
    }
}
