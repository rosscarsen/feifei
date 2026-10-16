import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// 统一管理 Android 与后续桌面平台的播放、事件等待和串行资源释放。
class MediaSession {
  /// 按需创建真实播放器；注入测试设备时不加载原生媒体库。
  MediaSession({Player? player}) : player = player ?? _createPlayer();

  /// 首次播放才加载原生媒体库，利用包内的初始化保护避免重复加载。
  static Player _createPlayer() {
    MediaKit.ensureInitialized();
    return Player(
      configuration: const PlayerConfiguration(
        title: '飞帧',
        bufferSize: 4 * 1024 * 1024,
      ),
    );
  }

  final Player player;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  Completer<Duration>? _loading;
  bool _closed = false;

  /// 返回当前实际播放状态，界面可通过 playingStream 持续观察。
  bool get playing => player.state.playing;

  /// 监听播放及自然结束，避免按钮图标停在过期状态。
  Stream<bool> get playingStream => player.stream.playing;

  /// 将设备命令串行化，关闭后拒绝尚未执行的操作。
  Future<T> _run<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('播放会话已经关闭'));
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_closed) throw StateError('播放会话已经关闭');
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  /// 暂停加载本地媒体；start/end 为源文件绝对时间，等待真实解码时长再返回。
  Future<Duration> open(String path, {Duration? start, Duration? end}) =>
      _run(() async {
        final ready = Completer<Duration>();
        _loading = ready;
        // 设备错误可能先于 open Future 返回，立即挂接错误处理，仍由下面 await 传播。
        unawaited(
          ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        final durationSubscription = player.stream.duration.listen((duration) {
          if (duration > Duration.zero && !ready.isCompleted) {
            ready.complete(duration);
          }
        });
        final errorSubscription = player.stream.error.listen((error) {
          if (!ready.isCompleted) {
            ready.completeError(FormatException('媒体无法解码：$error'));
          }
        });
        final timer = Timer(const Duration(seconds: 15), () {
          if (!ready.isCompleted) {
            ready.completeError(TimeoutException('媒体加载超时，请重试'));
          }
        });
        try {
          await player.open(Media(path, start: start, end: end), play: false);
          if (_closed) throw StateError('播放会话已经关闭');
          if (player.state.duration > Duration.zero && !ready.isCompleted) {
            ready.complete(player.state.duration);
          }
          return await ready.future;
        } finally {
          timer.cancel();
          await durationSubscription.cancel();
          await errorSubscription.cancel();
          if (identical(_loading, ready)) _loading = null;
        }
      });

  /// 开始播放已加载的媒体。
  Future<void> play() => _run(player.play);

  /// 暂停播放并保留当前文件，便于继续试听。
  Future<void> pause() => _run(player.pause);

  /// 跳转到源文件绝对时间，裁剪片段不得把相对时间直接传入。
  Future<void> seek(Duration position) => _run(() => player.seek(position));

  /// 将业务音量 0–1 转为 media_kit 的百分比。
  Future<void> setVolume(double volume) =>
      _run(() => player.setVolume(volume.clamp(0, 1) * 100));

  /// 循环单项播放列表，让每次重载重新应用裁剪起点；文件循环仅会回到原曲开头。
  Future<void> setLoop(bool loop) => _run(
    () => player.setPlaylistMode(loop ? PlaylistMode.loop : PlaylistMode.none),
  );

  /// 使加载等待立即失效，等已提交命令退出后关闭播放器及视频纹理。
  Future<void> close() => _closing ??= _close();

  /// 单次释放设备，避免重复 dispose 或原生操作与销毁交错。
  Future<void> _close() async {
    _closed = true;
    final loading = _loading;
    if (loading != null && !loading.isCompleted) {
      loading.completeError(StateError('播放会话已经关闭'));
    }
    await _tail;
    await player.dispose();
  }
}
