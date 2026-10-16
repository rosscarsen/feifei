import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';

import 'package:feifei/app.dart';
import 'package:feifei/data/project_repository.dart';
import 'package:feifei/domain/project.dart';
import 'package:feifei/ui/editor_screen.dart';
import 'package:feifei/ui/sound_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

/// 验证用户可见的新建流程和窄横屏首页布局。
void main() {
  testWidgets('首页默认作品，切换示例和取消开始均不创建工程', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('feifei-navigation-'),
    ))!;
    final repository = (await tester.runAsync(
      () =>
          ProjectRepository.open(directory, executor: NativeDatabase.memory()),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final closing = repository.close().then((_) => closed = true);
      await _pumpUntil(tester, () => closed);
      await closing;
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    await tester.pumpWidget(StudioApp(repository: repository));
    await _pumpUntil(
      tester,
      () => find.text('第一部故事，就从这里开始。').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('体验示例'), findsNothing);
    expect(find.text('作品').hitTestable(), findsOneWidget);
    expect(find.text('示例').hitTestable(), findsOneWidget);
    expect(find.text('开始').hitTestable(), findsOneWidget);
    await tester.tap(find.text('示例'));
    await tester.pumpAndSettle();
    expect(find.text('体验示例').hitTestable(), findsOneWidget);
    expect(find.text('我的作品'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('create-project')));
    await _pumpUntil(tester, () => find.text('选择画幅').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('create-format-landscape')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('create-format-portrait')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('取消新建'));
    await tester.pumpAndSettle();
    expect(find.text('体验示例'), findsOneWidget);
    expect(await tester.runAsync(repository.list), isEmpty);
    await tester.tap(find.text('作品'));
    await tester.pumpAndSettle();
    expect(find.text('我的作品'), findsOneWidget);
    expect(find.text('体验示例'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final scenario in ['oversize', 'cancel', 'failure']) {
    testWidgets('外部音频选择 $scenario 不读取整文件并清理选择器缓存', (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('feifei-picker-'),
      ))!;
      final repository = (await tester.runAsync(
        () => ProjectRepository.open(
          directory,
          executor: NativeDatabase.memory(),
        ),
      ))!;
      final project = (await tester.runAsync(
        () => repository.create('选择器边界', CanvasFormat.landscape),
      ))!;
      final previousPicker = FilePickerPlatform.instance;
      final picker = MetadataAudioPicker(scenario);
      FilePickerPlatform.instance = picker;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        FilePickerPlatform.instance = previousPicker;
        var closed = false;
        final closing = repository.close().then((_) => closed = true);
        await _pumpUntil(tester, () => closed);
        await closing;
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SoundScreen(repository: repository, project: project),
        ),
      );
      await tester.tap(find.text('导入音频'));
      await _pumpUntil(tester, () => find.text('其他文件').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('其他文件'));
      await _pumpUntil(tester, () => picker.called);
      expect(picker.called, isTrue);
      await _pumpUntil(tester, () => picker.cleaned);
      await tester.pumpAndSettle();
      if (scenario == 'oversize') {
        expect(find.textContaining('100 MB'), findsOneWidget);
      } else if (scenario == 'failure') {
        expect(find.textContaining('选择器读取失败'), findsOneWidget);
      }
      expect(picker.called, isTrue);
      expect(picker.cleaned, isTrue);
      expect(picker.file.readRequested, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('删除最后一帧会重新进入可恢复的取景状态', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('feifei-last-frame-'),
    ))!;
    final repository = (await tester.runAsync(
      () =>
          ProjectRepository.open(directory, executor: NativeDatabase.memory()),
    ))!;
    final project = (await tester.runAsync(() async {
      final created = await repository.create('最后一帧', CanvasFormat.landscape);
      final source = File('${directory.path}/source.jpg');
      await source.writeAsBytes(
        image.encodeJpg(image.Image(width: 32, height: 32)),
      );
      return repository.importFrame(created, source);
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final closing = repository.close().then((_) => closed = true);
      await _pumpUntil(tester, () => closed);
      await closing;
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(repository: repository, project: project),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('001'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _pumpUntil(tester, () => find.text('0 帧').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    // 主机不支持相机，应明确提示设备要求，不能永久停留在准备镜头。
    expect(find.text('拍摄功能需要在 Android 设备上使用'), findsOneWidget);
    expect(find.text('正在准备镜头…'), findsNothing);
  });
  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('工作台在 $size 与放大字体下没有溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('feifei-accessibility-'),
      ))!;
      final repository = (await tester.runAsync(
        () => ProjectRepository.open(
          directory,
          executor: NativeDatabase.memory(),
        ),
      ))!;
      final project = (await tester.runAsync(
        () => repository.create('大字体布局', CanvasFormat.portrait),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await repository.close();
          await directory.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EditorScreen(repository: repository, project: project),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0 帧'), findsOneWidget);
      expect(find.text('洋葱皮').hitTestable(), findsOneWidget);
      expect(find.text('循环播放').hitTestable(), findsOneWidget);
      expect(find.byTooltip('拍摄一帧').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('点选竖屏后自动采用未占用的名称并进入真实工作台', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('feifei-widget-'),
    ))!;
    final repository = await tester.runAsync(
      () =>
          ProjectRepository.open(directory, executor: NativeDatabase.memory()),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await repository!.close();
        if (await directory.exists()) await directory.delete(recursive: true);
      });
    });
    await tester.runAsync(
      () => repository!.create('我的动画 01', CanvasFormat.landscape),
    );
    await tester.pumpWidget(StudioApp(repository: repository!));
    await _pumpUntil(
      tester,
      () => find.text('我的动画 01', skipOffstage: false).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-project')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('create-format-portrait'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-format-portrait')));
    await _pumpUntil(tester, () => find.text('0 帧').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('我的动画 02'), findsOneWidget);
    expect(find.text('0 帧'), findsOneWidget);
    final saved = await tester.runAsync(() => repository.list());
    expect(saved, hasLength(2));
    expect(
      saved!
          .firstWhere((project) => project.name == '我的动画 02')
          .format
          .aspectRatio,
      closeTo(9 / 16, .001),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await repository.close();
      await directory.delete(recursive: true);
    });
  });
  testWidgets('小尺寸横屏首页没有布局溢出', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('feifei-layout-'),
    ))!;
    final repository = await tester.runAsync(
      () =>
          ProjectRepository.open(directory, executor: NativeDatabase.memory()),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await repository!.close();
        if (await directory.exists()) await directory.delete(recursive: true);
      });
    });
    await tester.pumpWidget(StudioApp(repository: repository!));
    await _pumpUntil(
      tester,
      () =>
          find.text('第一部故事，就从这里开始。', skipOffstage: false).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('我的作品', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.text('我的作品'), findsOneWidget);
    await tester.tap(find.text('示例'));
    await tester.pumpAndSettle();
    expect(find.text('体验示例').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await repository.close();
      await directory.delete(recursive: true);
    });
  });
  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('首页 $size 大字体时作品示例和开始保持可见', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('feifei-nav-size-'),
      ))!;
      final repository = (await tester.runAsync(
        () => ProjectRepository.open(
          directory,
          executor: NativeDatabase.memory(),
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = repository.close().then((_) => closed = true);
        await _pumpUntil(tester, () => closed);
        await closing;
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      await tester.pumpWidget(StudioApp(repository: repository));
      await _pumpUntil(
        tester,
        () => find
            .text('第一部故事，就从这里开始。', skipOffstage: false)
            .evaluate()
            .isNotEmpty,
      );
      for (final tab in ['作品', '示例']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        for (final label in ['作品', '示例', '开始']) {
          expect(find.text(label).hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }
    });
  }
}

/// 返回超限的文件元数据；任何整文件读取都会使测试失败。
final class MetadataAudioFile extends PlatformFile {
  bool readRequested = false;

  /// 保留选择器原始名称，避免以缓存扩展名误导用户。
  @override
  String get name => 'large.m4a';

  /// 不创建实际大文件，检查大小前不得读取此路径。
  @override
  Uri get uri => Uri.file('C:/unread-picker-audio.m4a');

  /// 返回原生已知大小，验证超限文件在解码前被拒绝。
  @override
  int? lengthSync() => 100 * 1024 * 1024 + 1;

  /// 未提供同步长度时仍只读取元数据。
  @override
  Future<int?> length() async => lengthSync();

  /// 禁止将整段音频复制到 Dart 内存。
  @override
  Future<Uint8List> readAsBytes() async {
    readRequested = true;
    throw StateError('不允许读取整文件');
  }

  /// 超限选择也不应启动后续数据流。
  @override
  Stream<Uint8List> readAsByteStream() {
    readRequested = true;
    throw StateError('超限文件不应开始复制');
  }

  /// 未使用的设备访问不参与此边界验证。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 模拟选择取消、超限元数据和原生读取失败，并记录缓存清理。
class MetadataAudioPicker extends FilePickerPlatform {
  /// 指定此次选择器返回的设备情形。
  MetadataAudioPicker(this.scenario);
  final String scenario;
  final file = MetadataAudioFile();
  bool called = false;
  bool cleaned = false;

  /// 仅返回路径和大小，不读取文件内容。
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    called = true;
    if (scenario == 'failure') throw StateError('选择器读取失败');
    return scenario == 'cancel' ? null : file;
  }

  /// 无论选择成功或失败，都记录应用是否释放选择器缓存。
  @override
  Future<void> clearTemporaryFiles() async {
    cleaned = true;
  }
}

/// 在假时钟的帧推进之间处理真实 SQLite 工作线程的消息，避免跨区等待死锁。
Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  final labels = find
      .byType(Text, skipOffstage: false)
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .take(30)
      .join(' | ');
  fail('界面在允许时间内没有进入预期状态：$labels');
}
