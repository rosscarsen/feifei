import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';

/// 描述相机返回的临时图片及尚未写入 EXIF 的方向信息。
class CapturedPhoto {
  /// 创建一次拍摄结果；工作台负责消费后删除临时文件。
  const CapturedPhoto(
    this.file, {
    this.rotationDegrees = 0,
    this.mirror = false,
  });
  final File file;
  final int rotationDegrees;
  final bool mirror;
}

/// 负责工作台的串行编辑、拍摄互斥和基于单调时钟的播放。
class EditorController extends ChangeNotifier {
  /// 接收持久化仓库和初始工程快照。
  EditorController(this.repository, this.project);

  final ProjectRepository repository;
  AnimationProject project;
  int selectedIndex = -1;
  bool busy = false;
  bool playing = false;
  bool intervalActive = false;
  String? error;
  VoidCallback? onPlaybackStart;
  VoidCallback? onPlaybackStop;
  Timer? _playTimer;
  Timer? _intervalTimer;
  final Stopwatch _clock = Stopwatch();
  Future<void>? _operation;
  Future<void>? _closing;
  bool _closed = false;
  int _generation = 0;
  int _cycle = 0;

  /// 返回当前稳定选中帧；取景态或空工程返回 null。
  AnimationFrame? get selectedFrame =>
      selectedIndex >= 0 && selectedIndex < project.frames.length
      ? project.frames[selectedIndex]
      : null;

  /// 只向仍存活的界面发布状态。
  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// 串行执行一个用户操作，拒绝重复点击形成任务队列。
  Future<bool> _perform(Future<void> Function() action) async {
    if (busy || _closed) return false;
    busy = true;
    error = null;
    _notify();
    final completion = Completer<void>();
    _operation = completion.future;
    try {
      await action();
      return true;
    } catch (exception) {
      error = exception.toString();
      rethrow;
    } finally {
      busy = false;
      completion.complete();
      _notify();
    }
  }

  /// 拍照后落盘并提交；前后台切换后的过期照片不会进入新会话。
  Future<bool> capture(Future<CapturedPhoto> Function() provider) async {
    var accepted = false;
    final generation = _generation;
    final ran = await _perform(() async {
      stopPlayback();
      if (project.frames.length >= AnimationProject.maxFrames) {
        throw StateError('已达到 600 帧上限');
      }
      await repository.requireSpace(128 * 1024 * 1024);
      final photo = await provider();
      try {
        if (_closed || generation != _generation) return;
        final next = await repository.importFrame(
          project,
          photo.file,
          rotationDegrees: photo.rotationDegrees,
          mirror: photo.mirror,
        );
        project = next;
        accepted = true;
        if (!_closed && generation == _generation) selectedIndex = -1;
      } finally {
        try {
          if (await photo.file.exists()) await photo.file.delete();
        } on FileSystemException {
          /* 系统临时目录会继续回收。 */
        }
      }
    });
    return ran && accepted;
  }

  /// 提交编辑后才替换界面快照，持久化失败时保留原状态。
  Future<void> edit(AnimationProject Function(AnimationProject) update) async {
    stopPlayback();
    final ran = await _perform(() async {
      final next = update(project);
      await repository.save(next);
      project = next;
      if (selectedIndex >= next.frames.length) {
        selectedIndex = next.frames.length - 1;
      }
    });
    if (!ran) throw StateError('请等待当前操作结束');
  }

  /// 选中一帧并停止播放，负数表示回到相机取景。
  void select(int index) {
    if (busy || _closed) return;
    stopPlayback();
    selectedIndex = index.clamp(-1, project.frames.length - 1);
    _notify();
  }

  /// 删除选中帧并保持一个有效选中位置。
  Future<void> deleteSelected() async {
    if (selectedFrame == null) return;
    final id = selectedFrame!.id;
    await edit(
      (value) => value.withFrames(
        value.frames.where((frame) => frame.id != id).toList(),
      ),
    );
  }

  /// 复制帧时使用仓库的新文件，避免副本依赖原图。
  Future<void> duplicateSelected() async {
    if (selectedFrame == null) return;
    await _perform(() async {
      project = await repository.duplicateFrame(project, selectedIndex);
      selectedIndex++;
    });
  }

  /// 应用拖动排序，同时按照稳定编号保留选中帧。
  Future<void> reorder(int oldIndex, int newIndex) async {
    final id = selectedFrame?.id;
    await edit((value) {
      final frames = [...value.frames];
      final frame = frames.removeAt(oldIndex);
      frames.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, frame);
      return value.withFrames(frames);
    });
    if (id != null) {
      selectedIndex = project.frames.indexWhere((frame) => frame.id == id);
    }
    _notify();
  }

  /// 从首帧播放，定时器只触发检查，实际帧序由单调时钟计算。
  void startPlayback() {
    if (busy || _closed || project.frames.isEmpty || playing) return;
    stopInterval();
    playing = true;
    selectedIndex = 0;
    _cycle = 0;
    _clock
      ..reset()
      ..start();
    onPlaybackStart?.call();
    _playTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final absolute = _clock.elapsedMicroseconds * project.fps ~/ 1000000;
      if (absolute >= project.frames.length && !project.loop) {
        stopPlayback();
        return;
      }
      final cycle = absolute ~/ project.frames.length;
      if (cycle != _cycle) {
        _cycle = cycle;
        onPlaybackStart?.call();
      }
      final index = absolute % project.frames.length;
      if (index != selectedIndex) {
        selectedIndex = index;
        _notify();
      }
    });
    _notify();
  }

  /// 停止播放并释放时间驱动资源。
  void stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    _clock.stop();
    if (playing) {
      playing = false;
      onPlaybackStop?.call();
      _notify();
    }
  }

  /// 开启串行间隔拍摄，上一张写入完成后才安排下一次。
  void startInterval(Future<CapturedPhoto> Function() provider) {
    if (busy || _closed || intervalActive) return;
    stopPlayback();
    intervalActive = true;
    _scheduleCapture(provider);
    _notify();
  }

  /// 安排唯一的下一次拍摄，错误和上限都会停止自动调度。
  void _scheduleCapture(Future<CapturedPhoto> Function() provider) {
    _intervalTimer?.cancel();
    _intervalTimer = Timer(
      Duration(seconds: project.intervalSeconds),
      () async {
        if (!intervalActive || _closed) return;
        try {
          await capture(provider);
          if (project.frames.length >= AnimationProject.maxFrames) {
            stopInterval();
          }
        } catch (_) {
          stopInterval();
        }
        if (intervalActive && !_closed) _scheduleCapture(provider);
      },
    );
  }

  /// 停止间隔拍摄，取消尚未触发的定时器。
  void stopInterval() {
    _intervalTimer?.cancel();
    _intervalTimer = null;
    if (intervalActive) {
      intervalActive = false;
      _notify();
    }
  }

  /// 退后台或离开拍摄会话，使迟到的拍摄结果失效。
  void suspend() {
    _generation++;
    stopInterval();
    stopPlayback();
  }

  /// 等待正在写入的操作结束后关闭，支持重复调用。
  Future<void> close() => _closing ??= _close();

  /// 关闭监听前先标记失效，防止异步回调通知已销毁界面。
  Future<void> _close() async {
    suspend();
    _closed = true;
    await _operation;
    super.dispose();
  }
}
