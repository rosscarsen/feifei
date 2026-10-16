import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';

/// 绘制原创纸艺小岛，用于封面和可实际导出的示例帧。
class StoryboardPainter extends CustomPainter {
  /// progress 控制风车与纸飞机位置，范围为一圈动画的比例。
  const StoryboardPainter({this.progress = 0});
  final double progress;

  /// 用矢量几何绘制小岛，避免加载大幅装饰位图。
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 960, size.height / 540);
    final paint = Paint();
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 960, 540),
      paint..color = const Color(0xffe6eee8),
    );
    canvas.drawCircle(
      const Offset(738, 128),
      55,
      paint..color = const Color(0xffedca8b),
    );
    for (final offset in [const Offset(190, 130), const Offset(540, 85)]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(offset.dx, offset.dy, 150, 36),
          const Radius.circular(25),
        ),
        paint..color = const Color(0xfff8f8ed),
      );
      canvas.drawCircle(offset + const Offset(55, 0), 35, paint);
      canvas.drawCircle(offset + const Offset(95, 8), 29, paint);
    }
    final hill = Path()
      ..moveTo(0, 410)
      ..quadraticBezierTo(270, 230, 500, 400)
      ..quadraticBezierTo(720, 270, 960, 392)
      ..lineTo(960, 540)
      ..lineTo(0, 540)
      ..close();
    canvas.drawPath(hill, paint..color = const Color(0xff9cba9d));
    final sea = Path()
      ..moveTo(0, 455)
      ..quadraticBezierTo(300, 410, 960, 470)
      ..lineTo(960, 540)
      ..lineTo(0, 540)
      ..close();
    canvas.drawPath(sea, paint..color = const Color(0xff6ba69b));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(386, 270, 112, 156),
        const Radius.circular(10),
      ),
      paint..color = const Color(0xffeee5cf),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(423, 364, 34, 62),
        const Radius.circular(15),
      ),
      paint..color = const Color(0xff60766c),
    );
    final roof = Path()
      ..moveTo(365, 289)
      ..lineTo(443, 224)
      ..lineTo(518, 289)
      ..close();
    canvas.drawPath(roof, paint..color = const Color(0xffbc7f6c));
    canvas.save();
    canvas.translate(442, 280);
    canvas.rotate(progress * math.pi * 2);
    for (var i = 0; i < 4; i++) {
      canvas.rotate(math.pi / 2);
      final blade = Path()
        ..moveTo(0, 0)
        ..lineTo(-16, -25)
        ..lineTo(-17, -118)
        ..lineTo(14, -97)
        ..close();
      canvas.drawPath(
        blade,
        paint
          ..color = i.isEven
              ? const Color(0xffdbaf75)
              : const Color(0xfffbf3dc),
      );
    }
    canvas.restore();
    canvas.drawCircle(
      const Offset(442, 280),
      10,
      paint..color = const Color(0xff53695e),
    );
    final x = 125 + progress * 640;
    final y = 210 - math.sin(progress * math.pi * 2) * 48;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(-.12);
    final plane = Path()
      ..moveTo(-40, -12)
      ..lineTo(62, -28)
      ..lineTo(-6, 32)
      ..lineTo(0, 0)
      ..close();
    canvas.drawPath(plane, paint..color = const Color(0xffe9a88f));
    final fold = Path()
      ..moveTo(0, 0)
      ..lineTo(62, -28)
      ..lineTo(-6, 32)
      ..close();
    canvas.drawPath(fold, paint..color = const Color(0xffca7c67));
    canvas.restore();
    canvas.restore();
  }

  /// 只在动画进度变化时重绘。
  @override
  bool shouldRepaint(covariant StoryboardPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 创建能编辑、配音和导出的真实示例工程，便于离线试玩。
Future<AnimationProject> createDemoProject(
  ProjectRepository repository, {
  ValueChanged<double>? onProgress,
}) async {
  var project = await repository.create('风起小岛 · 示例', CanvasFormat.landscape);
  try {
    for (var i = 0; i < 24; i++) {
      final recorder = ui.PictureRecorder();
      StoryboardPainter(progress: i / 24)
          .paint(Canvas(recorder), const Size(960, 540));
      final picture = recorder.endRecording();
      final bitmap = await picture.toImage(960, 540);
      picture.dispose();
      final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      bitmap.dispose();
      if (bytes == null) throw StateError('无法创建示例帧');
      final file = File(repository.newPath(project, 'exports', '.png'));
      try {
        await file.writeAsBytes(bytes.buffer.asUint8List());
        project = await repository.importFrame(project, file);
      } finally {
        if (await file.exists()) await file.delete();
      }
      onProgress?.call((i + 1) / 24);
    }
    project = project.copyWith(fps: 6);
    await repository.save(project);
    return project;
  } catch (_) {
    await repository.delete(project);
    rethrow;
  }
}
