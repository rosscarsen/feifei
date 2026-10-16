# CameraX 1.2.2 本地补丁

原始包：camerax_android 1.2.2，保留原有 LICENSE 与拍摄实现；对应原生 CameraX 1.6.1。

补丁只增加 `CameraXImageGeometry.sensorToBufferTransform`，通过已有 Pigeon 实例标识只读查询 `ImageProxy.imageInfo.sensorToBufferTransformMatrix`。调用必须发生在 `ImageProxy.close()` 前，接口不保留或关闭图片。插件分离时解除新增通道。

原因：工程锁定屏幕方向时，CameraController 的拍摄方向仍可能跟随物理传感器；部分 HAL 还会先旋转 JPEG 像素。读取每张图实际矩阵后，可计算剩余旋转角，避免硬减 90 度或只替换 EXIF。保留原生包全部能力，不另写相机实现。

修改范围：`lib/camerax_android.dart`、新增 `lib/src/image_geometry.dart`、`android/src/main/kotlin/dev/zeekr/camerax_android/CameraXAndroidPlugin.kt`。未修改生成的 Pigeon 文件。升级包时应迁移该小补丁并重新验证方向矩阵。

本目录是运行时依赖，须随工程提交；不是临时工具目录。
