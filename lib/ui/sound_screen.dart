import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';
import '../services/sound_service.dart';
import 'studio_theme.dart';
import 'audio_import_screen.dart';

/// 提供原创素材、导入、录音、真实波形与单音轨裁剪编辑。
class SoundScreen extends StatefulWidget {
  /// 接收当前选中帧，允许用户把声音起点附着到该帧。
  const SoundScreen({
    super.key,
    required this.repository,
    required this.project,
    this.selectedFrameId,
  });
  final ProjectRepository repository;
  final AnimationProject project;
  final String? selectedFrameId;

  /// 创建独立声音会话。
  @override
  State<SoundScreen> createState() => _SoundScreenState();
}

/// 管理待提交音轨、临时文件与独占播放器生命周期。
class _SoundScreenState extends State<SoundScreen> with WidgetsBindingObserver {
  late final SoundService _sound;
  ProjectAudio? _audio;
  Duration _duration = Duration.zero;
  List<double> _waveform = [];
  String _category = '乐器';
  bool _busy = false;
  bool _fromCurrent = false;
  String? _anchorFrameId;
  bool _accepted = false;
  String? _recordPath;
  final Set<String> _owned = {};
  Future<void>? _pending;

  /// 加载当前音轨，直到用户确认前都不覆盖工程记录。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sound = SoundService()..addListener(_soundChanged);
    _audio = widget.project.audio;
    _fromCurrent = _audio?.anchorFrameId != null;
    _anchorFrameId = _audio?.anchorFrameId;
    if (_audio != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _work(() => _load(_audio!.path, _audio!.label, preserve: _audio));
        }
      });
    }
  }

  /// 完成手动或自动停止的录音后加载其实际时长。
  void _soundChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_sound.recordingBusy &&
        _recordPath != null &&
        _sound.completedRecordingPath == _recordPath) {
      final path = _sound.completedRecordingPath!;
      _recordPath = null;
      _work(() async {
        final relative = p.relative(
          path,
          from: p.dirname(widget.repository.resolve(widget.project, 'marker')),
        );
        await _load(relative, '我的配音');
      });
    }
  }

  /// 去重异步操作并统一提示错误，离开页面后只完成清理。
  Future<void> _work(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final completion = Completer<void>();
    _pending = completion.future;
    try {
      await action();
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    } finally {
      completion.complete();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 加载项目内声音并抽取实际峰值波形，不支持时保留裁剪能力。
  Future<void> _load(
    String relative,
    String label, {
    ProjectAudio? preserve,
  }) async {
    final path = widget.repository.resolve(widget.project, relative);
    final duration = await _sound.load(path);
    if (!mounted) return;
    setState(() {
      _duration = duration;
      _waveform = [];
      _audio =
          preserve ??
          ProjectAudio(
            path: relative,
            label: label,
            sourceEndMs: duration.inMilliseconds,
          );
    });
    try {
      final wave = await ProVideoEditor.instance.getWaveform(
        WaveformConfigs(
          video: EditorVideo.file(path),
          resolution: WaveformResolution.low,
        ),
        nativeLogLevel: NativeLogLevel.none,
      );
      if (mounted) setState(() => _waveform = wave.leftChannel.toList());
    } catch (_) {
      /* 设备不支持波形时仍能裁剪与试听，不伪造波形。 */
    }
  }

  /// 复制内置声音到项目，再使用同一条音轨编辑。
  Future<void> _builtin(BuiltinSound sound, {bool preview = false}) =>
      _work(() async {
        await widget.repository.requireSpace(128 * 1024 * 1024);
        final bytes = await rootBundle.load('assets/audio/${sound.file}.m4a');
        final path = widget.repository.newPath(widget.project, 'audio', '.m4a');
        _owned.add(path);
        await File(path).writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
        final relative = p.relative(
          path,
          from: p.dirname(widget.repository.resolve(widget.project, 'marker')),
        );
        await _load(relative, sound.name);
        if (preview && mounted && _audio != null) await _sound.preview(_audio!);
      });

  /// Android 默认在应用内选择音频；选定后检查大小并流式复制，其他文件保留系统入口。
  Future<void> _import() => _work(() async {
    var usedMediaLibrary = false;
    var usedFilePicker = false;
    try {
      await widget.repository.requireSpace(128 * 1024 * 1024);
      if (!mounted) return;
      if (Theme.of(context).platform == TargetPlatform.android) {
        var otherLocation = false;
        final asset = await Navigator.of(context).push<AssetEntity>(
          MaterialPageRoute(
            builder: (pickerContext) => AudioImportScreen(
              onOtherLocation: () {
                otherLocation = true;
                Navigator.pop(pickerContext);
              },
            ),
          ),
        );
        if (!mounted) return;
        if (asset != null) {
          usedMediaLibrary = true;
          final file = await asset.originFile;
          if (!mounted) return;
          if (file == null) throw const FormatException('音频已被移动或无法读取，请重新选择');
          final relative = await widget.repository.importAudio(
            widget.project,
            file,
          );
          _owned.add(widget.repository.resolve(widget.project, relative));
          if (!mounted) return;
          await _load(relative, asset.title ?? p.basename(file.path));
          return;
        }
        if (!otherLocation) return;
      }
      usedFilePicker = true;
      final file = await FilePicker.pickFile(
        dialogTitle: '导入音频',
        type: FileType.custom,
        allowedExtensions: ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac'],
      );
      if (file == null || !mounted) return;
      final size = file.lengthSync() ?? await file.length();
      if (size == null || size <= 0 || size > 100 * 1024 * 1024) {
        throw const FormatException('声音文件须大于 0 且不超过 100 MB');
      }
      final path = file.path;
      if (path == null) throw const FormatException('无法读取声音文件，请选择本地音频');
      final relative = await widget.repository.importAudio(
        widget.project,
        File(path),
      );
      _owned.add(widget.repository.resolve(widget.project, relative));
      if (!mounted) return;
      await _load(relative, file.name);
    } finally {
      if (usedMediaLibrary) {
        try {
          // Android 10 可能生成完整临时副本；仅清包缓存，不能删除用户 originFile。
          await PhotoManager.clearFileCache();
        } catch (_) {
          /* 不覆盖原始导入结果，系统可继续回收缓存。 */
        }
      }
      if (usedFilePicker) {
        try {
          await FilePicker.clearTemporaryFiles();
        } catch (_) {
          /* 不覆盖原始导入结果或错误。 */
        }
      }
    }
  });

  /// 切换录音状态，录音与试听始终互斥。
  Future<void> _record() async {
    if (_sound.recording) {
      try {
        await _sound.stopRecording();
      } catch (exception) {
        if (mounted) showStudioMessage(context, exception);
      }
      return;
    }
    await _work(() async {
      await widget.repository.requireSpace(128 * 1024 * 1024);
      final path = widget.repository.newPath(widget.project, 'audio', '.m4a');
      _owned.add(path);
      await _sound.startRecording(path);
      _recordPath = path;
    });
  }

  /// 试听当前裁剪范围，再次点击时停止播放器。
  Future<void> _preview() async {
    if (_audio == null) return;
    try {
      if (_sound.player.playing) {
        await _sound.stop();
      } else {
        await _sound.preview(_audio!);
      }
      if (mounted) setState(() {});
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    }
  }

  /// 确认单音轨替换规则后返回配置，实际持久化由工作台完成。
  Future<void> _apply() async {
    final audio = _audio;
    if (audio == null || _busy || _sound.recordingBusy) return;
    if (widget.project.audio != null &&
        widget.project.audio!.path != audio.path) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('替换当前声音？'),
          content: const Text('试玩版每部作品使用一条音轨。选用后会替换原来的配乐或录音。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('保留原声音'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    await _sound.stop();
    if (!mounted) return;
    _accepted = true;
    Navigator.pop(
      context,
      ProjectAudio(
        path: audio.path,
        label: audio.label,
        sourceStartMs: audio.sourceStartMs,
        sourceEndMs: audio.sourceEndMs,
        anchorFrameId: _fromCurrent ? _anchorFrameId : null,
        volume: audio.volume,
        loop: audio.loop,
      ),
    );
  }

  /// 后台立即停止录音与试听，返回后允许检查已完成录音。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_sound.suspend().catchError((Object _) {}));
    }
  }

  /// 等待当前设备操作后释放资源，删除未提交的素材副本。
  Future<void> _release() async {
    await _pending;
    await _sound.close();
    final keep = _accepted && _audio != null
        ? widget.repository.resolve(widget.project, _audio!.path)
        : null;
    for (final path in _owned) {
      if (path == keep) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        /* 启动恢复会再次清理未引用文件。 */
      }
    }
  }

  /// 解除系统监听并异步完成受控资源释放。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sound.removeListener(_soundChanged);
    unawaited(_release());
    super.dispose();
  }

  /// 构建分类声音库与可滚动的裁剪工具，小屏不挤压操作区。
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && !_sound.recording,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) {
        showStudioMessage(context, _sound.recording ? '请先停止录音' : '正在处理声音，请稍候');
      }
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('给故事一点声音')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
              children: [
                const Text(
                  '听见你的想象。',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  '原创短配乐与音效，也可以用自己的声音。',
                  style: TextStyle(color: Color(0xff6b7c70)),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy || _sound.recording ? null : _import,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('导入音频'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _record,
                      icon: Icon(
                        _sound.recording
                            ? Icons.stop_rounded
                            : Icons.mic_none_rounded,
                      ),
                      label: Text(
                        _sound.recording
                            ? '停止录音 · ${_sound.recordedSeconds}s'
                            : '录制配音',
                      ),
                    ),
                  ],
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (_audio != null && !_sound.recording) ...[
                  const SizedBox(height: 24),
                  _editor(),
                ],
                if (_sound.error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _sound.error!,
                      style: const TextStyle(color: Colors.deepOrange),
                    ),
                  ),
                const SizedBox(height: 28),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final category in ['乐器', '自然', '生活'])
                      ChoiceChip(
                        label: Text(category),
                        selected: _category == category,
                        onSelected: (_) => setState(() => _category = category),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                for (final sound in BuiltinSound.all.where(
                  (sound) => sound.category == _category,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xffe8f2eb),
                          child: Icon(
                            _category == '乐器'
                                ? Icons.music_note_rounded
                                : _category == '自然'
                                ? Icons.spa_outlined
                                : Icons.graphic_eq_rounded,
                            color: const Color(0xff4c8270),
                          ),
                        ),
                        title: Text(
                          sound.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${sound.description}\n${sound.seconds} 秒',
                          style: const TextStyle(fontSize: 12, height: 1.7),
                        ),
                        trailing: Wrap(
                          spacing: 0,
                          children: [
                            IconButton(
                              onPressed: _busy || _sound.recording
                                  ? null
                                  : () => _builtin(sound, preview: true),
                              tooltip: '试听${sound.name}',
                              icon: const Icon(Icons.play_circle_outline),
                            ),
                            IconButton(
                              onPressed: _busy || _sound.recording
                                  ? null
                                  : () => _builtin(sound),
                              tooltip: '选用${sound.name}',
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  '内置内容为本项目原创程序合成试听素材。自然与生活分类为音效。',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: Color(0xff849187),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 12),
          child: FilledButton.icon(
            onPressed: _audio == null || _busy || _sound.recording
                ? null
                : _apply,
            icon: const Icon(Icons.check_rounded),
            label: const Text('将声音加入故事'),
          ),
        ),
      ),
    ),
  );

  /// 展示真实波形、源区间、音量、循环与时间轴锚点。
  Widget _editor() {
    final audio = _audio!;
    return Material(
      color: const Color(0xffe8eee7),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    audio.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                StreamBuilder<bool>(
                  stream: _sound.player.playingStream,
                  builder: (context, snapshot) => IconButton(
                    onPressed: _busy ? null : _preview,
                    tooltip: '试听裁剪片段',
                    icon: Icon(
                      snapshot.data == true
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_filled_rounded,
                    ),
                    iconSize: 34,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_waveform.isNotEmpty)
              SizedBox(
                height: 58,
                width: double.infinity,
                child: CustomPaint(painter: WaveformPainter(_waveform)),
              ),
            if (_duration.inMilliseconds > 0) ...[
              RangeSlider(
                values: RangeValues(
                  audio.sourceStartMs.toDouble().clamp(
                    0,
                    _duration.inMilliseconds.toDouble(),
                  ),
                  audio.sourceEndMs.toDouble().clamp(
                    0,
                    _duration.inMilliseconds.toDouble(),
                  ),
                ),
                min: 0,
                max: _duration.inMilliseconds.toDouble(),
                labels: RangeLabels(
                  '${(audio.sourceStartMs / 1000).toStringAsFixed(1)}s',
                  '${(audio.sourceEndMs / 1000).toStringAsFixed(1)}s',
                ),
                onChangeStart: (_) => _sound.stop(),
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value.end.round() <= value.start.round()) return;
                        setState(
                          () => _audio = audio.copyWith(
                            sourceStartMs: value.start.round(),
                            sourceEndMs: value.end.round(),
                          ),
                        );
                      },
              ),
              Text(
                '裁剪 ${(audio.sourceStartMs / 1000).toStringAsFixed(1)}–${(audio.sourceEndMs / 1000).toStringAsFixed(1)} 秒  ·  选用 ${durationLabel(audio.clipDuration)}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.volume_up_outlined, size: 20),
                Expanded(
                  child: Slider(
                    value: audio.volume,
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _audio = audio.copyWith(volume: value),
                          ),
                    onChangeEnd: (value) => _sound.player.setVolume(value),
                  ),
                ),
                Text('${(audio.volume * 100).round()}%'),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('声音不足时循环'),
              subtitle: const Text(
                '关闭时，剩余部分保持安静。',
                style: TextStyle(fontSize: 11),
              ),
              value: audio.loop,
              onChanged: _busy
                  ? null
                  : (value) {
                      _sound.stop();
                      setState(() => _audio = audio.copyWith(loop: value));
                    },
            ),
            const Divider(),
            const Text('从哪里开始播放？', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('故事开头'),
                  selected: !_fromCurrent,
                  onSelected: (_) => setState(() => _fromCurrent = false),
                ),
                ChoiceChip(
                  label: const Text('当前选中帧'),
                  selected:
                      _fromCurrent && _anchorFrameId == widget.selectedFrameId,
                  onSelected: widget.selectedFrameId == null
                      ? null
                      : (_) => setState(() {
                          _fromCurrent = true;
                          _anchorFrameId = widget.selectedFrameId;
                        }),
                ),
                if (widget.project.audio?.anchorFrameId != null &&
                    widget.project.audio!.anchorFrameId !=
                        widget.selectedFrameId)
                  ChoiceChip(
                    label: const Text('原声音起点'),
                    selected:
                        _fromCurrent &&
                        _anchorFrameId == widget.project.audio!.anchorFrameId,
                    onSelected: (_) => setState(() {
                      _fromCurrent = true;
                      _anchorFrameId = widget.project.audio!.anchorFrameId;
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 将设备返回的实际声音峰值聚合成有限数量的波形柱。
class WaveformPainter extends CustomPainter {
  /// 接收低分辨率真实峰值数据，不为装饰伪造波形。
  const WaveformPainter(this.samples);
  final List<double> samples;

  /// 按可用宽度聚合峰值并绘制音轨能量。
  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final count = math.max(1, (size.width / 5).floor());
    final paint = Paint()
      ..color = const Color(0xff4c9b84)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final begin = i * samples.length ~/ count;
      final end = math.min(
        samples.length,
        math.max(begin + 1, (i + 1) * samples.length ~/ count),
      );
      var peak = 0.0;
      for (var j = begin; j < end; j++) {
        if (samples[j].isFinite) peak = math.max(peak, samples[j].abs());
      }
      final height = math.max(2.0, peak.clamp(0, 1) * size.height * .9);
      final x = (i + .5) * size.width / count;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  /// 新声音加载后重新绘制。
  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) =>
      oldDelegate.samples != samples;
}
