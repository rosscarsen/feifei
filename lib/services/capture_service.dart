import 'dart:async';
import 'dart:io';

import 'package:camerax/camerax.dart' as cx;
import 'package:camerax_android/camerax_android.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../controllers/editor_controller.dart';
import 'capture_rotation.dart';

/// 使用 camerax 已有接口管理相机、能力查询和图片代理释放。
class CaptureService extends ChangeNotifier {
  /// 默认创建包内相机，测试可注入受控设备验证回调先后顺序。
  CaptureService({
    this._controller,
    Future<List<double>> Function(cx.ImageProxy)? imageTransform,
  }) : _imageTransform =
           imageTransform ?? CameraXImageGeometry.sensorToBufferTransform;

  final Future<List<double>> Function(cx.ImageProxy) _imageTransform;

  cx.CameraController? _controller;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool _closed = false;
  bool _taking = false;
  bool _wanted = false;
  static const _displayChannel = MethodChannel('com.lamb.feifei/display');
  int _generation = 0;
  bool ready = false;
  bool front = false;
  bool focusLocked = false;
  bool exposureLocked = false;
  bool whiteBalanceLocked = false;
  bool exposureLockSupported = false;
  bool whiteBalanceLockSupported = false;
  bool focusLockSupported = false;
  double zoom = 1;
  double minZoom = 1;
  double maxZoom = 1;
  String? error;

  /// 返回已经创建的控制器，供包自带预览组件使用。
  cx.CameraController? get controller => _controller;

  /// 只向存活界面报告状态。
  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// 去重初始化；用户操作可请求权限，自动恢复仅检查已有授权。
  Future<void> start({bool requestPermission = true}) async {
    if (_closed) return;
    _wanted = true;
    var mayRequestPermission = requestPermission;
    while (_wanted && !_closed && !ready) {
      final existing = _starting;
      if (existing != null) {
        await existing;
      } else {
        final pending = _start(requestPermission: mayRequestPermission);
        // 初始化因后台失效后可以重开，但一次用户操作最多弹出一次权限请求。
        mayRequestPermission = false;
        _starting = pending;
        try {
          await pending;
        } finally {
          if (identical(_starting, pending)) _starting = null;
        }
      }
      if (error != null) return;
    }
  }

  /// 通过包内接口配置相机、取景分辨率与低延迟拍摄模式。
  Future<void> _start({required bool requestPermission}) async {
    if (_closed || ready) return;
    final generation = ++_generation;
    error = null;
    if (!Platform.isAndroid) {
      error = '拍摄功能需要在 Android 设备上使用';
      _notify();
      return;
    }
    try {
      // 旧解绑必须真正结束，避免其迟到完成把刚打开的新会话再次关闭。
      await _stopping;
      if (_closed || generation != _generation) return;
      final permission = requestPermission
          ? await Permission.camera.request()
          : await Permission.camera.status;
      if (!permission.isGranted) {
        throw StateError('需要相机权限才能拍摄，可在系统设置中开启');
      }
      if (_closed || generation != _generation) return;
      final camera = _controller ??= cx.CameraController();
      // PreviewWidget 必须先挂载，让包创建 PreviewView 与取景 Surface，再等待 bind。
      _notify();
      final selector = front ? cx.CameraSelector.front : cx.CameraSelector.back;
      if (!await _hasCameraReady(camera, selector, generation)) {
        if (_closed || generation != _generation) return;
        throw StateError('当前镜头不可用');
      }
      await camera.setCameraSelector(selector);
      await camera.setEnabledUseCases([
        cx.CameraController$UseCase.imageCapture,
      ]);
      final builder = cx.ResolutionSelector$Builder();
      await builder.setAspectRatioStrategy(
        cx.AspectRatioStrategy.ratio16_9FallbackAutoStrategy,
      );
      await builder.setResolutionStrategy(
        cx.ResolutionStrategy(
          boundSize: const cx.Size(1920, 1080),
          fallbackRule:
              cx.ResolutionStrategy$FallbackRule.closestLowerThenHigher,
        ),
      );
      final resolution = await builder.build();
      await camera.setImageCaptureResolutionSelector(resolution);
      await camera.setPreviewResolutionSelector(resolution);
      await camera.setImageCaptureFlashMode(cx.ImageCapture$FlashMode.off);
      // CameraX 在不支持零快门延迟的镜头上自动回退到最小延迟模式。
      await camera.setImageCaptureMode(
        cx.ImageCapture$CaptureMode.zeroShutterLag,
      );
      await camera.setTapToFocusEnabled(true);
      await camera.setPinchToZoomEnabled(false);
      await camera.bind();
      if (_closed || generation != _generation) {
        await camera.unbind();
        return;
      }
      final info = await _waitForBinding(camera, generation);
      if (info == null) return;
      if (!await _waitForOpen(info, generation)) return;
      final zoomState = await (await camera.getZoomState()).getValue();
      minZoom = zoomState?.minZoomRatio ?? 1;
      maxZoom = zoomState?.maxZoomRatio ?? 1;
      zoom = zoomState?.zoomRatio ?? 1;
      focusLocked = false;
      exposureLocked = false;
      whiteBalanceLocked = false;
      {
        final camera2 = cx.Camera2CameraInfo.from(info);
        exposureLockSupported =
            await camera2.getCameraCharacteristic(
              cx.CameraCharacteristics.controlAeLockAvailable,
            ) ??
            false;
        whiteBalanceLockSupported =
            await camera2.getCameraCharacteristic(
              cx.CameraCharacteristics.controlAwbLockAvailable,
            ) ??
            false;
        final action = await _focusAction();
        focusLockSupported = await info.isFocusMeteringSupported(action);
      }
      if (_closed || generation != _generation) {
        await camera.unbind();
        return;
      }
      ready = true;
    } catch (exception) {
      if (!_closed && generation == _generation) {
        error = exception is StateError
            ? exception.message.toString()
            : '镜头暂时无法打开，请重试或检查系统相机权限';
        if (kDebugMode) debugPrint('相机初始化失败：$exception');
      }
      try {
        await _controller?.unbind();
      } catch (_) {
        /* 无会话时无需再次处理。 */
      }
    }
    _notify();
  }

  /// 等待原生预览挂载后的实际绑定，旋转或退出使会话失效时立即停止轮询。
  Future<cx.CameraInfo?> _waitForBinding(
    cx.CameraController camera,
    int token,
  ) async {
    final clock = Stopwatch()..start();
    while (!_closed && token == _generation) {
      final info = await camera.getCameraInfo();
      if (_closed || token != _generation) return null;
      if (info != null) return info;
      if (clock.elapsed >= const Duration(seconds: 15)) {
        throw StateError('镜头绑定超时，请重新打开');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  /// bind 返回不代表硬件已打开；有限轮询实际状态，期间失效时停止等待。
  Future<bool> _waitForOpen(cx.CameraInfo info, int token) async {
    final state = await info.getCameraState();
    final clock = Stopwatch()..start();
    while (!_closed && token == _generation) {
      if (await state.getValue() == cx.CameraState.open) return true;
      if (clock.elapsed >= const Duration(seconds: 15)) {
        throw StateError('镜头打开超时，请重新打开');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  /// 包未公开初始化 Future；短暂轮询已有能力接口，避免过早调用原生 hasCamera。
  Future<bool> _hasCameraReady(
    cx.CameraController camera,
    cx.CameraSelector selector,
    int token,
  ) async {
    final deadline = Stopwatch()..start();
    while (!_closed &&
        token == _generation &&
        deadline.elapsed < const Duration(seconds: 15)) {
      try {
        return await camera.hasCamera(selector);
      } on PlatformException catch (exception) {
        if (!(exception.message ?? '').contains('Camera not initialized')) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (_closed || token != _generation) return false;
    throw StateError('镜头初始化超时，请重新打开');
  }

  /// 拍摄 JPEG 到临时文件；硬件开始曝光时通知界面，所有路径关闭图片代理。
  Future<CapturedPhoto> takePhoto({VoidCallback? onShutter}) async {
    if (!ready || _taking || _closed) throw StateError('相机尚未就绪，请稍后重试');
    _taking = true;
    final completer = Completer<CapturedPhoto>();
    // 原生错误可能先于 takePicture 的平台回复；立即监听，仍由下面 await 传播错误。
    unawaited(
      completer.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    var abandoned = false;
    final generation = _generation;
    final isFront = front;
    late final int displayRotationDegrees;
    final callback = cx.ImageCapture$OnImageCapturedCallback(
      onCaptureStarted: () {
        if (!abandoned && !_closed && generation == _generation) {
          onShutter?.call();
        }
      },
      onCaptureSuccess: (proxy) async {
        CapturedPhoto? photo;
        File? temporary;
        Object? failure;
        try {
          if (!abandoned && !_closed && generation == _generation) {
            final directory = await getTemporaryDirectory();
            final file = File(
              p.join(directory.path, 'feifei-shot-${const Uuid().v4()}.jpg'),
            );
            temporary = file;
            final original = proxy.planes.first.value;
            // 扣除这张 JPEG 已由硬件完成的旋转，不能假设所有手机都只写 EXIF。
            final remaining = CaptureRotation.remainingDegrees(
              sensorToDisplay: displayRotationDegrees,
              sensorToBuffer: await _imageTransform(proxy),
            );
            final exif = image.decodeJpgExif(original) ?? image.ExifData();
            exif.imageIfd.orientation = [1, 6, 3, 8][remaining ~/ 90];
            final jpeg = image.injectJpgExif(original, exif);
            if (jpeg == null) throw const FormatException('无法校正拍照方向');
            await file.writeAsBytes(jpeg, flush: true);
            photo = CapturedPhoto(
              file,
              rotationDegrees: remaining,
              mirror: isFront,
            );
          } else {
            failure = StateError('拍摄会话已结束');
          }
        } catch (exception) {
          failure = exception;
        } finally {
          try {
            await proxy.close();
          } catch (exception) {
            failure ??= exception;
          }
        }
        if (abandoned) {
          await _removeTemporary(temporary);
          return;
        }
        if (!completer.isCompleted) {
          if (failure != null) {
            await _removeTemporary(temporary);
            completer.completeError(failure);
          } else {
            completer.complete(photo!);
          }
        }
      },
      onError: (exception) {
        if (!abandoned && !completer.isCompleted) {
          if (!_closed && generation == _generation) {
            ready = false;
            error = '本次拍摄失败，请重新打开镜头';
            _notify();
          }
          completer.completeError(StateError(exception.toString()));
        }
      },
    );
    try {
      final rotation = await _displayChannel.invokeMethod<int>('rotation');
      if (rotation == null || rotation < 0 || rotation > 3) {
        throw StateError('无法读取当前窗口方向，请重新打开镜头');
      }
      final info = await _controller!.getCameraInfo();
      if (info == null) throw StateError('相机已关闭');
      displayRotationDegrees = await info.getSensorRotationDegrees(
        cx.Surface$Rotation.values[rotation],
      );
      if (_closed || generation != _generation || !ready) {
        throw StateError('拍摄会话已结束');
      }
      await _controller!.takePicture(callback);
      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () async {
          abandoned = true;
          await suspend();
          throw TimeoutException('拍摄超时，请重新打开相机');
        },
      );
    } finally {
      _taking = false;
    }
  }

  /// 回收拍摄失败或超时的临时文件，删除失败不能吞掉原本的设备完成回调。
  Future<void> _removeTemporary(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* 文件位于系统缓存，空间/权限异常时允许系统后续回收。 */
    }
  }

  /// 设置硬件支持范围内的缩放，调用方须避免拖动请求积压。
  Future<void> setZoom(double value) async {
    if (!ready || _closed) return;
    final next = value.clamp(minZoom, maxZoom);
    await _controller!.setZoomRatio(next);
    if (ready && !_closed) {
      zoom = next;
      _notify();
    }
  }

  /// 构建中心对焦并禁止自动取消，实现真正的对焦锁定。
  Future<cx.FocusMeteringAction> _focusAction() async {
    final point = await cx.SurfaceOrientedMeteringPointFactory(
      1,
      1,
    ).createPoint(.5, .5);
    final builder = cx.FocusMeteringAction$Builder(point, [
      cx.FocusMeteringAction$MeteringMode.af,
    ]);
    await builder.disableAutoCancel();
    return builder.build();
  }

  /// 在设备确认成功后更新对焦锁定状态。
  Future<void> setFocusLocked(bool value) async {
    if (!ready || !focusLockSupported) throw StateError('此镜头不支持对焦锁定');
    final control = await _controller!.getCameraControl();
    if (control == null) throw StateError('相机控制器不可用');
    if (value) {
      final result = await control.startFocusAndMetering(await _focusAction());
      if (!result.isFocusSuccessful) throw StateError('未能锁定对焦，请调整物体距离');
    } else {
      await control.cancelFocusAndMetering();
    }
    await _controller!.setTapToFocusEnabled(!value);
    focusLocked = value;
    _notify();
  }

  /// 通过包已有 Camera2 互操作接口设置曝光或白平衡锁定。
  Future<void> setLocks({bool? exposure, bool? whiteBalance}) async {
    if (!ready) throw StateError('相机尚未就绪');
    if (exposure != null && !exposureLockSupported ||
        whiteBalance != null && !whiteBalanceLockSupported) {
      throw StateError('当前镜头不支持此项锁定');
    }
    final control = await _controller!.getCameraControl();
    if (control == null) throw StateError('相机控制器不可用');
    final builder = cx.CaptureRequestOptions$Builder();
    if (exposure != null) {
      await builder.setCaptureRequestOption(
        cx.CaptureRequest.controlAeLock,
        exposure,
      );
    }
    if (whiteBalance != null) {
      await builder.setCaptureRequestOption(
        cx.CaptureRequest.controlAwbLock,
        whiteBalance,
      );
    }
    await cx.Camera2CameraControl.from(control)
        .addCaptureRequestOptions(await builder.build());
    if (exposure != null) exposureLocked = exposure;
    if (whiteBalance != null) whiteBalanceLocked = whiteBalance;
    _notify();
  }

  /// 切换镜头前释放旧会话，再重新查询能力。
  Future<void> switchLens() async {
    await suspend();
    front = !front;
    await start();
  }

  /// 解绑相机释放硬件，过期初始化结果不会重新激活会话。
  Future<void> suspend() {
    _wanted = false;
    _generation++;
    ready = false;
    _notify();
    return _stopping = (_stopping ?? Future<void>.value()).then((_) async {
      try {
        await _controller?.unbind();
      } catch (_) {
        /* 已解绑时允许重复关闭。 */
      }
    });
  }

  /// 标记关闭并释放相机与状态监听。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await suspend();
    await _starting;
    _controller = null;
    super.dispose();
  }
}
