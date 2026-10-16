import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:uuid/uuid.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';

/// 表示导出状态，完成编码与保存相册由不同界面状态表达。
enum ExportPhase {
  idle,
  preparing,
  rendering,
  audio,
  completed,
  cancelled,
  failed,
}

/// 隔离设备编码接口，测试只替换此边界。
abstract interface class ExportBackend {
  /// 将有序图片写成无声视频，并报告实际进度。
  Future<void> frames(
    String output,
    StopMotionRenderData data,
    ValueChanged<double> progress,
  );

  /// 为已有视频添加声音，直接输出文件。
  Future<void> audio(
    String output,
    VideoRenderData data,
    ValueChanged<double> progress,
  );

  /// 请求停止底层任务；调用者仍须等待渲染 Future 结束。
  Future<void> cancel(String taskId);
}

/// 直接复用 pro_video_editor，既不自写编码器，也不把成片读入内存。
class PluginExportBackend implements ExportBackend {
  /// 订阅图片合成进度，并在所有退出路径释放订阅。
  @override
  Future<void> frames(
    String output,
    StopMotionRenderData data,
    ValueChanged<double> progress,
  ) async {
    final subscription = data.progressStream.listen(
      (event) => progress(event.progress),
    );
    try {
      await ProVideoEditor.instance.renderStopMotionToFile(
        output,
        data,
        nativeLogLevel: NativeLogLevel.none,
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// 复用包的音频裁剪、循环与封装接口。
  @override
  Future<void> audio(
    String output,
    VideoRenderData data,
    ValueChanged<double> progress,
  ) async {
    final subscription = data.progressStream.listen(
      (event) => progress(event.progress),
    );
    try {
      await ProVideoEditor.instance.renderVideoToFile(
        output,
        data,
        nativeLogLevel: NativeLogLevel.none,
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// 按任务编号取消包内部的工作。
  @override
  Future<void> cancel(String taskId) => ProVideoEditor.instance.cancel(taskId);
}

/// 管理一次导出及其取消、失败清理，保存到相册由界面独立触发。
class ExportService extends ChangeNotifier {
  /// 接收文件仓库；设备编码可在集成测试中替换。
  ExportService(this.repository, {ExportBackend? backend})
    : _backend = backend ?? PluginExportBackend();

  final ProjectRepository repository;
  final ExportBackend _backend;
  ExportPhase phase = ExportPhase.idle;
  double progress = 0;
  String? outputPath;
  String? error;
  bool _cancelRequested = false;
  bool _canCancel = false;
  bool _cancelSent = false;
  bool _closed = false;
  String? _activeId;
  Completer<void>? _done;

  /// 只在真实任务尚未结束时保持互斥。
  bool get busy => _done != null && !_done!.isCompleted;

  /// 将状态变化通知界面；关闭后丢弃迟到的进度回调。
  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// 导出工程快照；取消返回 null，错误保留原因并向调用者抛出。
  Future<String?> render(AnimationProject project) async {
    if (busy || _closed) throw StateError('当前不能开始新的导出');
    _done = Completer<void>();
    _cancelRequested = false;
    _cancelSent = false;
    _canCancel = false;
    outputPath = null;
    error = null;
    progress = 0;
    phase = ExportPhase.preparing;
    _notify();
    var silentPath = '';
    var finalPath = '';
    var success = false;
    try {
      silentPath = repository.newPath(project, 'exports', '.silent.mp4');
      finalPath = repository.newPath(project, 'exports', '.mp4');
      project.validate();
      if (project.frames.isEmpty) throw StateError('请先拍摄至少一帧');
      // 包会生成准备图片和中间视频，额外保留两份图片及双份视频空间。
      var originalBytes = 0;
      for (final frame in project.frames) {
        final file = File(repository.resolve(project, frame.imagePath));
        if (!await file.exists()) {
          throw FileSystemException('有一张原图已经丢失，请先处理该帧', file.path);
        }
        originalBytes += await file.length();
      }
      await repository.requireSpace(
        128 * 1024 * 1024 +
            originalBytes * 2 +
            (project.duration.inMicroseconds / 1000000 * 6000000 / 8 * 2)
                .ceil(),
      );
      if (_cancelRequested) return null;
      final frames = <StopMotionFrame>[];
      for (var i = 0; i < project.frames.length; i++) {
        // Media3 的图片接口用毫秒。使用相邻绝对边界的差，避免每帧截断误差累计。
        final start = (i * 1000 / project.fps).round();
        // 单图的 Media3 末采样时长为零，额外提供一个采样以标记正确结束时间。
        // 向下取整避免 6/12 FPS 的毫秒补齐意外生成第三个采样。
        final end = project.frames.length == 1
            ? (2000 / project.fps).floor()
            : ((i + 1) * 1000 / project.fps).round();
        frames.add(
          StopMotionFrame(
            image: EditorLayerImage.file(
              File(repository.resolve(project, project.frames[i].imagePath)),
            ),
            duration: Duration(milliseconds: end - start),
          ),
        );
      }
      final data = StopMotionRenderData(
        id: const Uuid().v4(),
        frames: frames,
        frameRate: project.fps.toDouble(),
        fit: StopMotionFit.contain,
        resolution: Size(
          project.format.width.toDouble(),
          project.format.height.toDouble(),
        ),
        bitrate: 6000000,
      );
      _activeId = data.id;
      phase = ExportPhase.rendering;
      _notify();
      await _backend.frames(silentPath, data, (value) {
        // 发布包在准备阶段的取消回调可能早于准备线程退出；完成准备后再发送取消，避免遗留图片。
        if (value >= .2) _canCancel = true;
        _updateProgress(value * (project.audio == null ? 1 : .7));
        _sendCancel();
      });
      _activeId = null;
      if (_cancelRequested) return null;
      if (project.audio != null) {
        final audio = project.audio!;
        final sourcePath = repository.resolve(project, audio.path);
        if (!await File(sourcePath).exists()) {
          throw const FileSystemException('声音文件已经丢失');
        }
        final data = VideoRenderData(
          id: const Uuid().v4(),
          videoSegments: [VideoSegment(video: EditorVideo.file(silentPath))],
          enableAudio: false,
          // 使用完整无声源，勿按结束时间裁掉单图视频的终止采样。
          // 原视频已经具有正确帧率；再次启用 Media3 丢帧滤镜会误删毫秒边界附近的帧。
          audioTracks: [
            VideoAudioTrack(
              path: sourcePath,
              volume: audio.volume,
              loop: audio.loop,
              audioStartTime: Duration(milliseconds: audio.sourceStartMs),
              audioEndTime: Duration(milliseconds: audio.sourceEndMs),
              startTime: project.audioOffset,
              endTime: project.duration,
            ),
          ],
        );
        _activeId = data.id;
        _canCancel = false;
        _cancelSent = false;
        phase = ExportPhase.audio;
        _notify();
        await _backend.audio(finalPath, data, (value) {
          // 音频准备线程结束后才开始报告 Transformer 进度，此前只记录取消意图。
          _canCancel = true;
          _updateProgress(.7 + value * .3);
          _sendCancel();
        });
      } else {
        await File(silentPath).rename(finalPath);
      }
      _activeId = null;
      if (_cancelRequested) return null;
      if (!await File(finalPath).exists() ||
          await File(finalPath).length() == 0) {
        throw const FileSystemException('编码器没有生成有效文件');
      }
      await repository.keepExport(project, finalPath);
      success = true;
      outputPath = finalPath;
      progress = 1;
      phase = ExportPhase.completed;
      return finalPath;
    } catch (exception) {
      if (_cancelRequested || exception is RenderCanceledException) {
        _cancelRequested = true;
        return null;
      }
      phase = ExportPhase.failed;
      error = exception.toString();
      rethrow;
    } finally {
      _activeId = null;
      if (!success && _cancelRequested) phase = ExportPhase.cancelled;
      for (final path in [silentPath, if (!success) finalPath]) {
        if (path.isEmpty) continue;
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          /* 保留未完成文件供后续清理。 */
        }
      }
      _done!.complete();
      _notify();
    }
  }

  /// 恢复已持久化的完整成片，允许再次播放、分享或重试保存相册。
  Future<bool> restoreLatest(AnimationProject project) async {
    if (busy || _closed) return false;
    final path = await repository.lastExport(project);
    if (path == null || _closed) return false;
    outputPath = path;
    phase = ExportPhase.completed;
    progress = 1;
    _notify();
    return true;
  }

  /// 限制进度重建频率，忽略无效及倒退的进度。
  void _updateProgress(double value) {
    if (!value.isFinite || value < progress || value - progress < .005) return;
    progress = value.clamp(0, 1);
    _notify();
  }

  /// 在安全阶段发送一次取消；失败时等待底层自然结束后再清理。
  void _sendCancel() {
    if (!_cancelRequested || !_canCancel || _cancelSent || _activeId == null) {
      return;
    }
    _cancelSent = true;
    unawaited(
      _backend.cancel(_activeId!).catchError((Object _) {
        /* 渲染 Future 仍是生命周期依据。 */
      }),
    );
  }

  /// 取消后等待底层任务退出，不能仅关闭进度界面。
  Future<void> cancel() async {
    if (!busy) return;
    _cancelRequested = true;
    _sendCancel();
    _notify();
    await _done!.future;
  }

  /// 等待任务安全结束再释放状态监听。
  Future<void> close() async {
    if (_closed) return;
    await cancel();
    _closed = true;
    super.dispose();
  }
}
