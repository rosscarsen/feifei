import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../domain/project.dart';
import 'media_session.dart';

/// 描述随应用打包的原创声音，不依赖在线下载。
class BuiltinSound {
  /// 创建素材索引，时长与生成清单保持一致。
  const BuiltinSound(
    this.name,
    this.category,
    this.file,
    this.seconds,
    this.description,
  );
  final String name;
  final String category;
  final String file;
  final int seconds;
  final String description;

  static const all = [
    BuiltinSound('晨光木琴', '乐器', 'morning-marimba', 16, '轻快 · 温暖 · 小小冒险'),
    BuiltinSound('星屑钟琴', '乐器', 'starlight-bells', 16, '空灵 · 柔和 · 梦幻故事'),
    BuiltinSound('微风溪流', '自然', 'breeze-stream', 12, '合成环境声 · 林间散步'),
    BuiltinSound('水下气泡', '自然', 'underwater-bubbles', 8, '合成环境声 · 海底奇遇'),
    BuiltinSound('轻快脚步', '生活', 'little-footsteps', 4, '合成音效 · 角色登场'),
    BuiltinSound('滴答时钟', '生活', 'gentle-clock', 8, '合成音效 · 时间流逝'),
  ];
}

/// 管理单实例试听、时间轴声音和麦克风录音，显式释放播放器。
class SoundService extends ChangeNotifier {
  /// 注入页面独占的播放会话和录音器，避免不同条目同时发声。
  SoundService({this._recorder, this._playback});

  MediaSession? _playback;
  String? _loadedPath;

  /// 按需创建播放器，单纯录音时不额外占用音频解码资源。
  MediaSession get player => _playback ??= MediaSession();
  AudioRecorder? _recorder;
  Future<void>? _recordStarting;
  Future<String?>? _recordStopping;
  int _recordGeneration = 0;
  Timer? _offsetTimer;
  Timer? _recordTimer;
  int _generation = 0;
  bool recording = false;
  String? completedRecordingPath;

  /// 启动和停止尚未完成时也占用录音操作，避免重入与提前读取。
  bool get recordingBusy =>
      recording || _recordStarting != null || _recordStopping != null;
  int recordedSeconds = 0;
  String? error;
  bool _closed = false;
  Future<void>? _closing;

  /// 向仍存活的声音编辑界面报告录音和错误状态。
  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// 加载本地文件并验证设备能够解码及其真实时长。
  Future<Duration> load(String path) async {
    await stop();
    if (_closed) throw StateError('声音会话已经结束');
    final token = _generation;
    final duration = await player.open(path);
    if (_closed || token != _generation) throw StateError('声音加载已经取消');
    if (duration.inMilliseconds <= 0 || duration.inMilliseconds > 600000) {
      throw const FormatException('无法读取声音，或声音超过 10 分钟');
    }
    _loadedPath = path;
    return duration;
  }

  /// 应用裁剪、循环和音量后试听，不阻塞等待整段声音播放完毕。
  Future<void> preview(ProjectAudio audio) async {
    audio.validate();
    if (_closed) return;
    final path = _loadedPath;
    if (path == null) throw StateError('请先选择声音');
    final token = ++_generation;
    await player.open(
      path,
      start: Duration(milliseconds: audio.sourceStartMs),
      end: Duration(milliseconds: audio.sourceEndMs),
    );
    if (_closed || token != _generation) return;
    await player.setVolume(audio.volume);
    if (_closed || token != _generation) return;
    await player.setLoop(audio.loop);
    if (_closed || token != _generation) return;
    _play();
  }

  /// 启动播放器并收集异步设备错误，避免未处理的播放 Future。
  void _play() {
    if (_closed) return;
    unawaited(
      player.play().catchError((Object exception) {
        error = exception.toString();
        _notify();
      }),
    );
  }

  /// 根据动画锚点安排声音；重复播放或离开页面会使旧调度失效。
  Future<void> playTimeline(AnimationProject project, String path) async {
    final clock = Stopwatch()..start();
    await stop();
    final token = _generation;
    final audio = project.audio;
    if (audio == null || _closed) return;
    await player.open(
      path,
      start: Duration(milliseconds: audio.sourceStartMs),
      end: Duration(milliseconds: audio.sourceEndMs),
    );
    if (token != _generation || _closed) return;
    await player.setVolume(audio.volume);
    if (token != _generation || _closed) return;
    await player.setLoop(audio.loop);
    if (token != _generation || _closed) return;
    final elapsedAfterAnchor = clock.elapsed - project.audioOffset;
    final clipDuration = audio.sourceEndMs - audio.sourceStartMs;
    if (!audio.loop && elapsedAfterAnchor.inMilliseconds >= clipDuration) {
      return;
    }
    final seekMs = elapsedAfterAnchor.isNegative
        ? 0
        : elapsedAfterAnchor.inMilliseconds % clipDuration;
    await player.seek(Duration(milliseconds: audio.sourceStartMs + seekMs));
    if (token != _generation || _closed) return;
    final remaining = project.audioOffset - clock.elapsed;
    _offsetTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (token == _generation && !_closed) _play();
    });
  }

  /// 停止声音和未触发的锚点调度。
  Future<void> stop() async {
    _generation++;
    _offsetTimer?.cancel();
    _offsetTimer = null;
    if (!_closed) await _playback?.pause();
  }

  /// 请求麦克风权限并开始写入项目私有录音文件。
  Future<void> startRecording(String path) {
    if (recordingBusy || _closed) return Future.error(StateError('当前不能开始录音'));
    completedRecordingPath = null;
    final token = ++_recordGeneration;
    final pending = _startRecording(path, token);
    _recordStarting = pending;
    return pending.whenComplete(() => _recordStarting = null);
  }

  /// 每次设备等待后验证启动代际，迟到成功立即取消麦克风会话。
  Future<void> _startRecording(String path, int token) async {
    await stop();
    if (_closed || token != _recordGeneration) return;
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) throw StateError('需要麦克风权限才能录音');
    if (_closed || token != _recordGeneration) return;
    await recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        numChannels: 1,
        bitRate: 128000,
      ),
      path: path,
    );
    if (_closed || token != _recordGeneration) {
      await recorder.cancel();
      return;
    }
    recordedSeconds = 0;
    recording = true;
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      recordedSeconds++;
      if (recordedSeconds >= 150) {
        _recordTimer?.cancel();
        unawaited(
          stopRecording().catchError((Object exception) {
            error = exception.toString();
            _notify();
            return null;
          }),
        );
      }
      _notify();
    });
    _notify();
  }

  /// 停止并完成录音文件；调用者负责后续试听与保存引用。
  Future<String?> stopRecording() async {
    if (_recordStopping != null) return _recordStopping;
    _recordGeneration++;
    _recordTimer?.cancel();
    _recordTimer = null;
    final pending = _finishRecording(_recordStarting);
    _recordStopping = pending;
    try {
      return await pending;
    } finally {
      _recordStopping = null;
      _notify();
    }
  }

  /// 等待启动退出及原生封装完成后，才公布可解码的录音路径。
  Future<String?> _finishRecording(Future<void>? starting) async {
    try {
      await starting;
    } catch (_) {
      /* 启动错误由原调用者处理。 */
    }
    if (!recording) return null;
    try {
      final path = await _recorder?.stop();
      if (!_closed) completedRecordingPath = path;
      return path;
    } finally {
      recording = false;
    }
  }

  /// 后台使未完成的启动失效，并等待已开始的录音完成封装。
  Future<void> suspend() async {
    final stopping = stopRecording();
    await stop();
    await stopping;
  }

  /// 取消未完成的录音与试听，再关闭设备资源。
  Future<void> close() => _closing ??= _close();

  /// 显式关闭播放器、录音器和所有计时器。
  Future<void> _close() async {
    _closed = true;
    _generation++;
    _offsetTimer?.cancel();
    _recordTimer?.cancel();
    await stopRecording();
    await _recorder?.dispose();
    await _playback?.close();
    super.dispose();
  }
}
