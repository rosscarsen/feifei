import 'dart:async';
import 'dart:io';

import 'package:camerax/camerax.dart' as cx;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../controllers/editor_controller.dart';
import '../data/project_repository.dart';
import '../domain/project.dart';
import '../services/capture_service.dart';
import '../services/sound_service.dart';
import 'export_screen.dart';
import 'sound_screen.dart';
import 'studio_theme.dart';

/// 让工具栏在正常宽度均匀排布，窄屏及大字体时保留可滚动的完整点击区域。
class _ScrollableToolRow extends StatelessWidget {
  /// 接收按视觉顺序排列的独立操作项。
  const _ScrollableToolRow({required this.children});
  final List<Widget> children;

  /// 用内容最小宽度与可用宽度共同决定工具栏尺寸。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: children,
        ),
      ),
    ),
  );
}

/// 用大取景区、胶片时间轴与文字工具提供完整定格创作流程。
class EditorScreen extends StatefulWidget {
  /// 以工程快照打开工作台并自动保存；可注入相机会话，页面退出时统一关闭。
  const EditorScreen({
    super.key,
    required this.repository,
    required this.project,
    this.captureService,
  });
  final ProjectRepository repository;
  final AnimationProject project;
  final CaptureService? captureService;

  /// 创建独占的相机和编辑会话。
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

/// 管理页面生命周期，离开时等待异步任务结束再释放相机。
class _EditorScreenState extends State<EditorScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final EditorController _editor;
  late final CaptureService _camera;
  SoundService? _sound;
  bool _onion = false;
  bool _clickSound = true;
  bool _navigating = false;
  bool _foreground = true;
  bool _controlBusy = false;
  bool _allowExit = false;
  bool _exiting = false;
  int _captureGeneration = 0;
  late final AnimationController _shutterFlash;

  /// 打开工程即进入实时取景，洋葱皮默认关闭并由用户手动开启。
  @override
  void initState() {
    super.initState();
    _shutterFlash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      value: 1,
    );
    WidgetsBinding.instance.addObserver(this);
    _editor = EditorController(widget.repository, widget.project)
      ..addListener(_changed);
    _camera = (widget.captureService ?? CaptureService())
      ..addListener(_changed);
    unawaited(_orientForProject());
    _editor.onPlaybackStart = _playSound;
    _editor.onPlaybackStop = () => unawaited(_sound?.stop());
    unawaited(_camera.start());
  }

  /// 应用工程画幅的屏幕方向并保持到后续页面，切换工程时再更新；图像宽高比独立处理。
  Future<void> _orientForProject() => SystemChrome.setPreferredOrientations(
    _editor.project.format == CanvasFormat.landscape
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp],
  );

  /// 根据编辑与相机状态刷新，不读取或解码整批原图。
  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_editor.playing &&
        _editor.selectedIndex + 1 < _editor.project.frames.length) {
      final frame = _editor.project.frames[_editor.selectedIndex + 1];
      unawaited(
        precacheImage(
          ResizeImage(
            FileImage(
              File(widget.repository.resolve(_editor.project, frame.imagePath)),
            ),
            width: _editor.project.format == CanvasFormat.landscape ? 960 : 540,
          ),
          context,
          onError: (_, _) {},
        ),
      );
    }
  }

  /// 执行用户操作并把异常转成界面提示。
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    }
  }

  /// 在相机确认开始曝光时给出短闪和提示音，保存仍由拍摄任务负责。
  void _shutter() {
    if (!mounted) return;
    _shutterFlash.forward(from: 0);
    if (_clickSound) unawaited(SystemSound.play(SystemSoundType.click));
  }

  /// 请求一张实际照片，并在硬件快门回调中反馈拍摄时刻。
  Future<CapturedPhoto> _photo() => _camera.takePhoto(onShutter: _shutter);

  /// 开启时回到实时取景，固定叠加上一张照片；关闭只移除参考层。
  Future<void> _toggleOnion() async {
    if (_editor.busy || _navigating) return;
    setState(() => _onion = !_onion);
    if (_onion) await _live();
  }

  /// 从播放或单帧预览回到取景，再恢复镜头并拍摄；恢复及保存均受拍摄互斥保护。
  Future<void> _capture() => _run(() async {
    if (_editor.busy ||
        _controlBusy ||
        _navigating ||
        _exiting ||
        !_foreground) {
      return;
    }
    final generation = _captureGeneration;
    _editor.select(-1);
    await _editor.capture(() async {
      _checkCaptureSession(generation);
      await _camera.start(requestPermission: false);
      _checkCaptureSession(generation);
      if (!_camera.ready) {
        throw StateError(_camera.error ?? '镜头尚未恢复，请重新打开镜头');
      }
      return _photo();
    });
  });

  /// 在恢复镜头前后拒绝失效的快门请求，避免后台重新打开镜头或迟到曝光。
  void _checkCaptureSession(int generation) {
    if (!mounted ||
        !_foreground ||
        _navigating ||
        _exiting ||
        generation != _captureGeneration) {
      throw StateError('拍摄会话已结束，请返回镜头后重试');
    }
  }

  /// 回到实时取景前停止播放和定时拍摄。
  Future<void> _live() async {
    if (_editor.busy || _navigating) return;
    _editor.stopInterval();
    _editor.select(-1);
    if (_foreground) await _camera.start();
  }

  /// 查看单帧时释放相机，避免隐藏预览持续占用硬件。
  void _select(int index) {
    if (_editor.busy || _navigating) return;
    _editor.stopInterval();
    _editor.select(index);
    unawaited(_camera.suspend());
  }

  /// 播放时关闭相机会话，统一从工程首帧开始预览。
  Future<void> _togglePlay() async {
    if (_editor.playing) {
      _editor.stopPlayback();
      return;
    }
    if (_editor.busy) return;
    await _camera.suspend();
    _editor.startPlayback();
  }

  /// 只在项目存在音轨时创建播放器，按锚点调度声音。
  void _playSound() {
    final project = _editor.project;
    if (project.audio == null) return;
    final service = _sound ??= SoundService();
    unawaited(
      service
          .playTimeline(
            project,
            widget.repository.resolve(project, project.audio!.path),
          )
          .catchError((Object exception) {
            if (mounted) showStudioMessage(context, exception);
          }),
    );
  }

  /// 保持所选屏幕方向打开声音编辑，先停止实时资源，返回后提交有效音轨。
  Future<void> _openSound() async {
    if (_editor.busy || _navigating) return;
    _navigating = true;
    _editor.suspend();
    await _camera.suspend();
    await _sound?.stop();
    if (!mounted) return;
    try {
      final audio = await Navigator.of(context).push<ProjectAudio>(
        MaterialPageRoute(
          builder: (_) => SoundScreen(
            repository: widget.repository,
            project: _editor.project,
            selectedFrameId: _editor.selectedFrame?.id,
          ),
        ),
      );
      if (audio != null && mounted) {
        await _editor.edit((project) => project.copyWith(audio: audio));
      }
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    } finally {
      _navigating = false;
      if (mounted) await _orientForProject();
      if (mounted && _foreground && _editor.selectedIndex < 0) {
        await _camera.start(requestPermission: false);
      }
    }
  }

  /// 删除单音轨需要确认，保存后仓库才回收旧文件。
  Future<void> _removeSound() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除这条声音？'),
        content: const Text('照片和帧顺序会保留，可以稍后添加新的声音。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => _editor.edit((project) => project.copyWith(clearAudio: true)),
      );
    }
  }

  /// 保持所选屏幕方向进入导出页，使用稳定快照并在返回时恢复取景资源。
  Future<void> _export() async {
    if (_editor.busy || _navigating || _editor.project.frames.isEmpty) return;
    _navigating = true;
    _editor.suspend();
    await _camera.suspend();
    await _sound?.stop();
    if (!mounted) return;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExportScreen(
            repository: widget.repository,
            project: _editor.project,
          ),
        ),
      );
    } finally {
      _navigating = false;
      if (mounted) await _orientForProject();
      if (mounted && _foreground && _editor.selectedIndex < 0) {
        await _camera.start(requestPermission: false);
      }
    }
  }

  /// 删除帧时说明锚点迁移，避免用户失去声音位置。
  Future<void> _deleteFrame() async {
    final frame = _editor.selectedFrame;
    if (frame == null) return;
    final anchor = _editor.project.audio?.anchorFrameId == frame.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这一帧？'),
        content: Text(anchor ? '这帧也是声音的起点。删除后，声音会移动到新的首帧。' : '这张照片将从作品中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(() async {
        await _editor.deleteSelected();
        if (mounted && _foreground && _editor.selectedIndex < 0) {
          await _camera.start(requestPermission: false);
        }
      });
    }
  }

  /// 对设备控制设置串行加锁，防止拖动与镜头切换形成积压。
  Future<void> _cameraAction(Future<void> Function() action) async {
    if (_controlBusy || _editor.busy) return;
    setState(() => _controlBusy = true);
    await _run(action);
    if (mounted) setState(() => _controlBusy = false);
  }

  /// 展示实际可用的相机控制与拍摄参数。
  Future<void> _settings() async {
    var opacity = _editor.project.onionOpacity;
    var interval = _editor.project.intervalSeconds.toDouble();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, updateSheet) => AnimatedBuilder(
          animation: Listenable.merge([_camera, _editor]),
          builder: (context, _) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .85,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                children: [
                  const Text(
                    '让每一帧更稳定',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _camera.ready
                        ? '锁定前先完成构图与对焦。功能取决于当前镜头。'
                        : '回到实时取景后，可以调整镜头参数。',
                    style: const TextStyle(fontSize: 12),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('锁定对焦'),
                    subtitle: const Text('先对焦到画面中心，再保持焦点。'),
                    value: _camera.focusLocked,
                    onChanged:
                        !_camera.ready ||
                            !_camera.focusLockSupported ||
                            _controlBusy
                        ? null
                        : (value) async {
                            await _cameraAction(
                              () => _camera.setFocusLocked(value),
                            );
                            if (sheetContext.mounted) updateSheet(() {});
                          },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('锁定曝光'),
                    value: _camera.exposureLocked,
                    onChanged:
                        !_camera.ready ||
                            !_camera.exposureLockSupported ||
                            _controlBusy
                        ? null
                        : (value) async {
                            await _cameraAction(
                              () => _camera.setLocks(exposure: value),
                            );
                            if (sheetContext.mounted) updateSheet(() {});
                          },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('锁定白平衡'),
                    value: _camera.whiteBalanceLocked,
                    onChanged:
                        !_camera.ready ||
                            !_camera.whiteBalanceLockSupported ||
                            _controlBusy
                        ? null
                        : (value) async {
                            await _cameraAction(
                              () => _camera.setLocks(whiteBalance: value),
                            );
                            if (sheetContext.mounted) updateSheet(() {});
                          },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('拍摄提示音'),
                    value: _clickSound,
                    onChanged: (value) {
                      setState(() => _clickSound = value);
                      updateSheet(() {});
                    },
                  ),
                  const Divider(),
                  Text('洋葱皮透明度  ${(opacity * 100).round()}%'),
                  Slider(
                    value: opacity,
                    onChanged: (value) => updateSheet(() => opacity = value),
                    onChangeEnd: (value) => _run(
                      () => _editor.edit(
                        (project) => project.copyWith(onionOpacity: value),
                      ),
                    ),
                  ),
                  Text('定时拍摄间隔  ${interval.round()} 秒'),
                  Slider(
                    value: interval,
                    min: 1,
                    max: 60,
                    divisions: 59,
                    onChanged: (value) => updateSheet(() => interval = value),
                    onChangeEnd: (value) => _run(
                      () => _editor.edit(
                        (project) =>
                            project.copyWith(intervalSeconds: value.round()),
                      ),
                    ),
                  ),
                  const Text(
                    '间隔拍摄会等上一张保存完再计时；退后台会自动停止。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 退后台使旧会话与等待恢复的快门请求失效，回到前台只恢复取景镜头。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _captureGeneration++;
      _editor.suspend();
      unawaited(_camera.suspend());
      unawaited(_sound?.stop());
    } else if (state == AppLifecycleState.resumed) {
      final returningFromBackground = !_foreground;
      _foreground = true;
      if (returningFromBackground &&
          !_navigating &&
          _editor.selectedIndex < 0) {
        unawaited(_camera.start(requestPermission: false));
      }
    }
  }

  /// 返回列表前停止镜头并等待文件操作，保留用户最近选择的屏幕方向。
  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    await Future.wait([
      _editor.close(),
      _camera.close(),
      if (_sound != null) _sound!.close(),
    ]);
    if (!mounted) return;
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  /// 移除页面时释放观察者和会话资源，后续页面继续保持最近选择的屏幕方向。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editor.removeListener(_changed);
    _camera.removeListener(_changed);
    _shutterFlash.dispose();
    unawaited(_editor.close());
    unawaited(_camera.close());
    unawaited(_sound?.close());
    super.dispose();
  }

  /// 将完整画幅置于屏幕背景，悬浮工具不再挤压相机或照片预览。
  @override
  Widget build(BuildContext context) => Theme(
    data: StudioColors.theme(dark: true),
    child: PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _stage(),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact =
                      constraints.maxHeight < 500 ||
                      MediaQuery.textScalerOf(context).scale(12) > 16;
                  return Column(
                    children: [
                      _header(),
                      _previewToggles(),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _cameraTools(compact),
                          ),
                        ),
                      ),
                      _controlDeck(compact),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 固定显示两个预览开关和当前状态，横竖屏均无需滚动或长按寻找。
  Widget _previewToggles() => Container(
    color: Colors.black.withValues(alpha: .65),
    padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Row(
          children: [
            Expanded(
              child: _previewToggle(
                label: '洋葱皮',
                tooltip: '上一帧洋葱皮',
                icon: Icons.layers_outlined,
                selected: _onion,
                onPressed: () => _run(_toggleOnion),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _previewToggle(
                label: '循环播放',
                tooltip: '循环播放',
                icon: Icons.repeat_rounded,
                selected: _editor.project.loop,
                onPressed: () => _run(
                  () => _editor.edit(
                    (project) => project.copyWith(loop: !project.loop),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 以图标、中文及状态文字呈现开关，同时提供屏幕阅读器选中语义。
  Widget _previewToggle({
    required String label,
    required String tooltip,
    required IconData icon,
    required bool selected,
    required VoidCallback onPressed,
  }) => Tooltip(
    message: tooltip,
    child: Semantics(
      toggled: selected,
      child: TextButton(
        onPressed: _editor.busy ? null : onPressed,
        style: TextButton.styleFrom(
          foregroundColor: selected ? StudioColors.mint : Colors.white70,
          backgroundColor: selected
              ? StudioColors.mint.withValues(alpha: .12)
              : Colors.white.withValues(alpha: .06),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    selected ? '已开启' : '已关闭',
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 在画面上方展示返回、工程状态和导出，渐变保证亮背景上的文字可读。
  Widget _header() => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withValues(alpha: .88),
          Colors.black.withValues(alpha: .72),
        ],
      ),
    ),
    child: SizedBox(
      height: 56,
      child: AppBar(
        primary: false,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          onPressed: _exit,
          tooltip: '返回作品',
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _editor.project.name,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _editor.busy
                  ? '正在处理…'
                  : '已自动保存 · ${_editor.project.format.label}',
              style: const TextStyle(fontSize: 10, color: Color(0xffbccbc3)),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _editor.busy ? null : _settings,
            tooltip: '拍摄设置',
            icon: const Icon(Icons.tune_rounded),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              onPressed: _editor.busy || _editor.project.frames.isEmpty
                  ? null
                  : _export,
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('导出'),
            ),
          ),
        ],
      ),
    ),
  );

  /// 将播放和胶片条悬浮在画面底部，保留排序、声音和错误提示入口。
  Widget _controlDeck(bool compact) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withValues(alpha: .65),
          StudioColors.night.withValues(alpha: .96),
        ],
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _playControls(compact),
        _timeline(compact),
        if (_editor.selectedFrame != null && !_editor.playing)
          _frameTools(compact),
        if (_editor.project.audio != null && !compact) _audioStrip(),
        if (_editor.error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _editor.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
            ),
          ),
      ],
    ),
  );

  /// 显示当前音轨并提供编辑和移除操作，窄横屏通过声音工具进入同一流程。
  Widget _audioStrip() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Row(
      children: [
        const Icon(
          Icons.music_note_rounded,
          color: StudioColors.mint,
          size: 17,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _editor.project.audio!.label,
            style: const TextStyle(fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: _editor.busy ? null : _openSound,
          child: const Text('编辑声音'),
        ),
        IconButton(
          onPressed: _editor.busy ? null : _removeSound,
          tooltip: '移除声音',
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    ),
  );

  /// 显示实时取景或选中帧，洋葱皮永远只是可忽略触摸的叠加层。
  Widget _stage() {
    final project = _editor.project;
    final frame = _editor.selectedFrame;
    return Center(
      child: AspectRatio(
        aspectRatio: project.format.aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.zero,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xff19272b)),
              // 查看照片时保留原生预览节点，避免重新挂载与相机 bind 相互竞态。
              // 服务仍会解绑相机，保留节点不会让硬件在照片预览期间继续工作。
              if (_camera.controller != null)
                cx.PreviewWidget(
                  key: ValueKey(_camera.controller),
                  controller: _camera.controller!,
                  implementationMode:
                      cx.PreviewView$ImplementationMode.compatible,
                  scaleType: cx.PreviewView$ScaleType.fillCenter,
                ),
              if (frame != null)
                _frameImage(frame)
              else if (_camera.controller == null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.camera_alt_outlined,
                            size: 32,
                            color: Colors.white.withValues(alpha: .4),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _camera.error ?? '正在准备镜头…',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xffa2b5ab),
                              fontSize: 12,
                            ),
                          ),
                          if (_camera.error != null && Platform.isAndroid)
                            Wrap(
                              alignment: WrapAlignment.center,
                              children: [
                                TextButton(
                                  onPressed: _camera.start,
                                  child: const Text('重新打开'),
                                ),
                                TextButton(
                                  onPressed: openAppSettings,
                                  child: const Text('系统权限'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (frame == null && !_camera.ready && _camera.controller != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.black54,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _camera.error ?? '正在准备镜头…',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        if (_camera.error != null)
                          TextButton(
                            onPressed: _camera.start,
                            child: const Text('重新打开'),
                          ),
                      ],
                    ),
                  ),
                ),
              if (frame == null &&
                  _camera.ready &&
                  _onion &&
                  project.frames.isNotEmpty)
                IgnorePointer(
                  key: const ValueKey('onion-reference'),
                  child: Opacity(
                    opacity: project.onionOpacity,
                    child: _frameImage(project.frames.last),
                  ),
                ),
              IgnorePointer(
                child: FadeTransition(
                  opacity: _shutterFlash.drive(Tween(begin: .22, end: 0.0)),
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
              Positioned(
                top:
                    82 +
                    MediaQuery.textScalerOf(context).scale(22) * 1.4 +
                    MediaQuery.paddingOf(context).top,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .65),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _editor.playing
                        ? '预览 · ${project.fps} FPS'
                        : frame == null
                        ? '实时取景'
                        : '第 ${_editor.selectedIndex + 1} 帧',
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 按显示需要的分辨率读取图片，损坏图片有明确占位。
  Widget _frameImage(AnimationFrame frame) => Image.file(
    File(widget.repository.resolve(_editor.project, frame.imagePath)),
    fit: BoxFit.cover,
    gaplessPlayback: true,
    cacheWidth: _editor.project.format == CanvasFormat.landscape ? 960 : 540,
    errorBuilder: (_, _, _) => const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined),
          SizedBox(height: 8),
          Text('原图无法读取，请删除此帧', style: TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );

  /// 固定保留可从预览恢复拍摄的快门，其余镜头工具在低矮屏幕中滚动。
  Widget _cameraTools(bool compact) => Container(
    width: compact ? 68 : 76,
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .58),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: StudioColors.mint,
              foregroundColor: StudioColors.night,
              disabledBackgroundColor: StudioColors.panel,
              minimumSize: Size(compact ? 54 : 62, compact ? 54 : 62),
            ),
            onPressed:
                (!_camera.ready && _editor.selectedIndex < 0) ||
                    _editor.busy ||
                    _controlBusy
                ? null
                : _capture,
            tooltip: '拍摄一帧',
            icon: _editor.busy
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.camera_alt_rounded, size: 28),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed:
                      !_camera.ready ||
                          _controlBusy ||
                          _editor.busy ||
                          _camera.zoom >= _camera.maxZoom
                      ? null
                      : () => _cameraAction(
                          () => _camera.setZoom(_camera.zoom + .25),
                        ),
                  tooltip: '放大镜头',
                  icon: const Icon(Icons.add_rounded),
                ),
                if (_camera.ready)
                  Text(
                    '${_camera.zoom.toStringAsFixed(1)}×',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffa7b8af),
                    ),
                  ),
                IconButton(
                  onPressed:
                      !_camera.ready ||
                          _controlBusy ||
                          _editor.busy ||
                          _camera.zoom <= _camera.minZoom
                      ? null
                      : () => _cameraAction(
                          () => _camera.setZoom(_camera.zoom - .25),
                        ),
                  tooltip: '缩小镜头',
                  icon: const Icon(Icons.remove_rounded),
                ),
                IconButton(
                  onPressed: _editor.busy || _controlBusy
                      ? null
                      : () async {
                          _editor.stopInterval();
                          _editor.select(-1);
                          await _cameraAction(_camera.switchLens);
                        },
                  tooltip: '切换前后镜头',
                  icon: const Icon(Icons.flip_camera_android_outlined),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  /// 帧数、播放速度和音轨入口在窄屏下可横向滚动。
  Widget _playControls(bool compact) => Padding(
    padding: EdgeInsets.fromLTRB(12, compact ? 0 : 5, 12, 4),
    child: _ScrollableToolRow(
      children: [
        IconButton.filledTonal(
          onPressed: _editor.project.frames.isEmpty || _editor.busy
              ? null
              : _togglePlay,
          tooltip: _editor.playing ? '暂停预览' : '播放预览',
          icon: Icon(
            _editor.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
        DropdownButton<int>(
          value: _editor.project.fps,
          underline: const SizedBox(),
          items: [
            for (final fps in AnimationProject.supportedFps)
              DropdownMenuItem(
                value: fps,
                child: Text('$fps FPS', style: const TextStyle(fontSize: 12)),
              ),
          ],
          onChanged: _editor.busy
              ? null
              : (value) {
                  if (value != null) {
                    _run(
                      () => _editor.edit(
                        (project) => project.copyWith(fps: value),
                      ),
                    );
                  }
                },
        ),
        Text(
          '${_editor.project.frames.length} 帧',
          style: const TextStyle(fontSize: 11, color: Color(0xffa2b6aa)),
        ),
        IconButton(
          onPressed: _editor.busy ? null : _openSound,
          tooltip: '声音库与配音',
          icon: const Icon(Icons.music_note_rounded, size: 22),
        ),
        IconButton(
          onPressed:
              !_camera.ready ||
                  _editor.selectedIndex >= 0 ||
                  _editor.busy && !_editor.intervalActive
              ? null
              : () {
                  if (_editor.intervalActive) {
                    _editor.stopInterval();
                  } else {
                    _editor.startInterval(_photo);
                  }
                },
          color: _editor.intervalActive ? StudioColors.gold : Colors.white60,
          tooltip: _editor.intervalActive ? '停止定时拍摄' : '启动定时拍摄',
          icon: Icon(
            _editor.intervalActive
                ? Icons.timer_off_outlined
                : Icons.timer_outlined,
            size: 22,
          ),
        ),
        if (compact && _editor.project.audio != null) ...[
          TextButton(
            onPressed: _editor.busy ? null : _openSound,
            child: Text(_editor.project.audio!.label),
          ),
          IconButton(
            onPressed: _editor.busy ? null : _removeSound,
            tooltip: '移除声音',
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ],
    ),
  );

  /// 用稳定编号构建可拖动胶片条，只有可见缩略图进入缓存。
  Widget _timeline(bool compact) => SizedBox(
    height: compact ? 66 : 88,
    child: Row(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            width: 52,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _editor.busy ? null : _live,
                  tooltip: '实时取景',
                  color: _editor.selectedIndex < 0
                      ? StudioColors.mint
                      : Colors.white60,
                  icon: const Icon(Icons.camera_alt_outlined),
                ),
                if (!compact)
                  const Text(
                    '取景',
                    style: TextStyle(fontSize: 9, color: Color(0xffa2b6aa)),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _editor.project.frames.isEmpty
              ? const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '移动一点，再拍一张。',
                    style: TextStyle(color: Color(0xff748e80), fontSize: 12),
                  ),
                )
              : ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  onReorderItem: (oldIndex, newIndex) => _run(
                    () => _editor.reorder(
                      oldIndex,
                      newIndex > oldIndex ? newIndex + 1 : newIndex,
                    ),
                  ),
                  onReorderStart: (_) {
                    _editor.stopPlayback();
                    _editor.stopInterval();
                  },
                  itemCount: _editor.project.frames.length,
                  itemBuilder: (context, index) {
                    final frame = _editor.project.frames[index];
                    return SizedBox(
                      key: ValueKey(frame.id),
                      width: compact ? 66 : 82,
                      child: ReorderableDelayedDragStartListener(
                        index: index,
                        enabled: !_editor.busy,
                        child: GestureDetector(
                          onTap: () => _select(index),
                          child: Container(
                            margin: const EdgeInsets.fromLTRB(3, 2, 3, 6),
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: StudioColors.panel,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: index == _editor.selectedIndex
                                    ? StudioColors.mint
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: Column(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(5),
                                    child: Image.file(
                                      File(
                                        widget.repository.resolve(
                                          _editor.project,
                                          frame.thumbnailPath,
                                        ),
                                      ),
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      cacheWidth: 160,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.broken_image_outlined,
                                        size: 15,
                                      ),
                                    ),
                                  ),
                                ),
                                Text(
                                  (index + 1).toString().padLeft(3, '0'),
                                  style: const TextStyle(
                                    fontSize: 9,
                                    height: 1.5,
                                    color: Color(0xffa7b9ae),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(width: 8),
      ],
    ),
  );

  /// 为帧操作添加中文名称，不依赖难以理解的图标。
  Widget _frameTools(bool compact) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _editor.busy || _editor.selectedIndex <= 0
                ? null
                : () => _run(
                    () => _editor.reorder(
                      _editor.selectedIndex,
                      _editor.selectedIndex - 1,
                    ),
                  ),
            icon: const Icon(Icons.chevron_left_rounded, size: 18),
            label: const Text('前移'),
          ),
          TextButton.icon(
            onPressed:
                _editor.busy ||
                    _editor.selectedIndex >= _editor.project.frames.length - 1
                ? null
                : () => _run(
                    () => _editor.reorder(
                      _editor.selectedIndex,
                      _editor.selectedIndex + 2,
                    ),
                  ),
            icon: const Icon(Icons.chevron_right_rounded, size: 18),
            label: const Text('后移'),
          ),
          TextButton.icon(
            onPressed: _editor.busy
                ? null
                : () => _run(_editor.duplicateSelected),
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: const Text('复制'),
          ),
          TextButton.icon(
            onPressed: _editor.busy ? null : _deleteFrame,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('删除'),
          ),
        ],
      ),
    ),
  );
}
