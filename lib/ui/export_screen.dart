import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';
import '../services/export_service.dart';
import '../services/media_session.dart';
import 'studio_theme.dart';

/// 展示真实导出进度、取消、成片预览和独立的相册保存状态。
class ExportScreen extends StatefulWidget {
  /// 接收不可变工程快照，导出期间上层不允许编辑该工程。
  const ExportScreen({
    super.key,
    required this.repository,
    required this.project,
    this.reuseLatest = false,
  });
  final ProjectRepository repository;
  final AnimationProject project;
  final bool reuseLatest;

  /// 创建导出页面状态。
  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

/// 持有导出服务和预览播放器，并处理前后台与返回操作。
class _ExportScreenState extends State<ExportScreen>
    with WidgetsBindingObserver {
  late final ExportService _service;
  MediaSession? _player;
  VideoController? _video;
  bool _saving = false;
  bool _saved = false;
  bool _exiting = false;
  bool _allowExit = false;

  /// 页面首次布局后开始导出，避免在构建中更新状态。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service = ExportService(widget.repository)..addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _render();
    });
  }

  /// 仅在页面存活时刷新真实导出状态。
  void _changed() {
    if (mounted) setState(() {});
  }

  /// 执行导出并初始化成片预览，预览失败不丢弃有效文件。
  Future<void> _render() async {
    _saved = false;
    final previous = _player;
    _player = null;
    _video = null;
    await previous?.close();
    if (!mounted) return;
    try {
      final restored =
          widget.reuseLatest && await _service.restoreLatest(widget.project);
      final path = restored
          ? _service.outputPath
          : await _service.render(widget.project);
      if (path == null || !mounted) return;
      final player = MediaSession();
      final video = VideoController(player.player);
      setState(() {
        _player = player;
        _video = video;
      });
      try {
        await player.open(path);
        if (!mounted) {
          await player.close();
          return;
        }
        setState(() {});
      } catch (_) {
        if (mounted) {
          setState(() {
            _player = null;
            _video = null;
          });
        }
        await player.close();
      }
    } catch (_) {
      /* 服务保留了可重试错误，页面直接展示。 */
    }
  }

  /// 保存相册失败时保留已合成文件，用户可以直接重试。
  Future<void> _save() async {
    final path = _service.outputPath;
    if (path == null || _saving || _saved) return;
    setState(() => _saving = true);
    try {
      if (!await Gal.hasAccess(toAlbum: true) &&
          !await Gal.requestAccess(toAlbum: true)) {
        throw StateError('没有相册保存权限，请在系统设置中允许后重试');
      }
      await Gal.putVideo(path, album: '飞帧');
      if (mounted) {
        setState(() => _saved = true);
        showStudioMessage(context, '已保存到系统相册');
      }
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 使用系统分享面板发送用户主动选择的成片。
  Future<void> _share() async {
    final path = _service.outputPath;
    if (path == null) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: widget.project.name),
      );
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    }
  }

  /// 返回前等待取消结束；相册写入期间避免关闭页面。
  Future<void> _exit() async {
    if (_exiting) return;
    if (_saving) {
      showStudioMessage(context, '正在保存到相册，请稍候');
      return;
    }
    _exiting = true;
    await _service.cancel();
    await _player?.close();
    if (!mounted) return;
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  /// 本版仅前台导出，退后台请求安全取消并暂停预览。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_service.cancel());
      unawaited(_player?.pause().catchError((Object _) {}));
    }
  }

  /// 解除观察者并关闭本页面持有的所有资源。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_changed);
    unawaited(_service.close());
    unawaited(_player?.close());
    super.dispose();
  }

  /// 展示成片或进度，区分编码完成与保存相册完成。
  @override
  Widget build(BuildContext context) {
    final completed = _service.phase == ExportPhase.completed;
    final failed = _service.phase == ExportPhase.failed;
    final cancelled = _service.phase == ExportPhase.cancelled;
    final player = _player;
    return PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('让故事动起来'),
          leading: IconButton(
            onPressed: _exit,
            tooltip: '返回作品',
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: ListView(
                padding: const EdgeInsets.all(26),
                children: [
                  if (completed && player != null && _video != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: ColoredBox(
                        color: StudioColors.night,
                        child: AspectRatio(
                          aspectRatio: widget.project.format.aspectRatio,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Video(
                                controller: _video!,
                                controls: NoVideoControls,
                                aspectRatio: widget.project.format.aspectRatio,
                              ),
                              StreamBuilder<bool>(
                                stream: player.playingStream,
                                builder: (context, snapshot) =>
                                    IconButton.filled(
                                      onPressed: () async {
                                        try {
                                          if (player.playing) {
                                            await player.pause();
                                          } else {
                                            if (player.player.state.completed) {
                                              await player.seek(Duration.zero);
                                            }
                                            await player.play();
                                          }
                                        } catch (exception) {
                                          if (context.mounted) {
                                            showStudioMessage(
                                              context,
                                              exception,
                                            );
                                          }
                                        }
                                      },
                                      tooltip: '播放或暂停成片',
                                      iconSize: 38,
                                      icon: Icon(
                                        snapshot.data ?? player.playing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 42),
                      child: Center(
                        child: SizedBox(
                          width: 120,
                          height: 120,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                strokeWidth: 6,
                                value: _service.busy ? _service.progress : 1,
                                constraints: const BoxConstraints.expand(),
                                color: failed
                                    ? Colors.deepOrange
                                    : StudioColors.mint,
                              ),
                              Icon(
                                completed
                                    ? Icons.check_rounded
                                    : cancelled
                                    ? Icons.pause_rounded
                                    : failed
                                    ? Icons.error_outline
                                    : Icons.movie_creation_outlined,
                                size: 44,
                                color: StudioColors.ink,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 28),
                  Text(
                    completed
                        ? '你的故事，完成了。'
                        : failed
                        ? '这次导出没有完成'
                        : cancelled
                        ? '导出已取消'
                        : '正在把每一帧连成故事',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.project.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xff64746a),
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (!widget.reuseLatest)
                          Chip(
                            label: Text('${widget.project.frames.length} 帧'),
                          ),
                        Chip(
                          label: Text(
                            widget.reuseLatest
                                ? '上次成片'
                                : durationLabel(widget.project.duration),
                          ),
                        ),
                        const Chip(label: Text('1080p · MP4')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_service.busy) ...[
                    Text(
                      _service.phase == ExportPhase.audio
                          ? '正在添加声音 · ${(_service.progress * 100).round()}%'
                          : '正在合成画面 · ${(_service.progress * 100).round()}%',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '请保持应用在前台。取消后会清理本次导出，请稍候。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Color(0xff64746a)),
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton(
                      onPressed: _service.cancel,
                      child: const Text('取消导出'),
                    ),
                  ],
                  if (completed) ...[
                    FilledButton.icon(
                      onPressed: _saving || _saved ? null : _save,
                      icon: Icon(
                        _saved ? Icons.check_rounded : Icons.save_alt_rounded,
                      ),
                      label: Text(
                        _saving
                            ? '正在保存…'
                            : _saved
                            ? '已保存到相册'
                            : '保存到系统相册',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('分享这部故事'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _saved ? '现在可以在系统相册中查看和播放。' : '成片已合成；点击上方按钮保存到相册。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xff64746a),
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (failed || cancelled) ...[
                    if (failed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Text(
                          _service.error ?? '请检查存储空间后重试',
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.deepOrange,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: _render,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新导出'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
