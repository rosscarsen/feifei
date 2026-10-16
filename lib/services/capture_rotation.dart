import 'dart:math' as math;

/// 将实际 JPEG 的硬件旋转从目标窗口旋转中扣除，避免重复旋转。
abstract final class CaptureRotation {
  /// 校验逐张图像矩阵并返回还需顺时针旋转的角度；不支持的变换明确拒绝。
  static int remainingDegrees({
    required int sensorToDisplay,
    required List<double> sensorToBuffer,
  }) {
    if (sensorToDisplay < 0 ||
        sensorToDisplay >= 360 ||
        sensorToDisplay % 90 != 0 ||
        sensorToBuffer.length != 9 ||
        sensorToBuffer.any((value) => !value.isFinite)) {
      throw const FormatException('照片方向数据无效');
    }
    final a = sensorToBuffer[0];
    final b = sensorToBuffer[3];
    final c = sensorToBuffer[1];
    final d = sensorToBuffer[4];
    final xScale = math.sqrt(a * a + b * b);
    final yScale = math.sqrt(c * c + d * d);
    if (!xScale.isFinite ||
        !yScale.isFinite ||
        xScale <= 0 ||
        yScale <= 0 ||
        a * d - b * c <= 0 ||
        ((a * c + b * d) / (xScale * yScale)).abs() > .0001 ||
        sensorToBuffer[6].abs() > .000001 ||
        sensorToBuffer[7].abs() > .000001 ||
        (sensorToBuffer[8] - 1).abs() > .000001) {
      throw const FormatException('当前镜头返回了不支持的照片变换');
    }
    final angle = (math.atan2(b, a) * 180 / math.pi + 360) % 360;
    final hardware = ((angle / 90).round() * 90) % 360;
    final difference = ((angle - hardware + 540) % 360) - 180;
    if (difference.abs() > .01) {
      throw const FormatException('照片旋转角不是直角');
    }
    return (sensorToDisplay - hardware + 360) % 360;
  }
}
