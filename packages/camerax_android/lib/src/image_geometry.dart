import 'package:camerax_platform_interface/camerax_platform_interface.dart';
import 'package:flutter/services.dart';

import 'core/image_proxy_impl.dart';

/// 读取 CameraX 已有的逐张图片变换数据，不接管拍照或图像资源所有权。
abstract final class CameraXImageGeometry {
  static const _channel = MethodChannel('camerax.zeekr.dev/imageGeometry');

  /// 在 ImageProxy 关闭前读取传感器到实际 JPEG 像素的九项矩阵。
  static Future<List<double>> sensorToBufferTransform(ImageProxy image) async {
    if (image is! ImageProxyImpl) {
      throw ArgumentError('图片必须来自当前 Android CameraX 会话');
    }
    final api = image.api;
    final identifier = api.pigeon_instanceManager.getIdentifier(api);
    if (identifier == null) throw StateError('图片代理已失效');
    final values = await _channel.invokeListMethod<num>(
      'sensorToBuffer',
      identifier,
    );
    if (values == null || values.length != 9) throw StateError('无法读取照片方向');
    return values.map((value) => value.toDouble()).toList(growable: false);
  }
}
