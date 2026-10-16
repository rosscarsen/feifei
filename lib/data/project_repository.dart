import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:image_editor/image_editor.dart' as native_image;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../domain/project.dart';

/// 使用 SQLite 保存工程元数据，不把图片或声音加载进数据库。
class ProjectDatabase extends GeneratedDatabase {
  /// 接收真实数据库连接，也允许测试使用内存连接。
  ProjectDatabase(super.executor);

  /// 当前只有一版项目元数据表。
  @override
  int get schemaVersion => 1;

  /// SQL 表由迁移创建，不使用代码生成表。
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  /// 首次打开时创建带删除标记的工程表。
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await customStatement(
        'CREATE TABLE projects (id TEXT PRIMARY KEY, payload TEXT NOT NULL, modified INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)',
      );
    },
  );
}

/// 统一管理项目持久化、串行文件事务和私有目录边界。
class ProjectRepository {
  /// 绑定私有根目录与数据库；使用 open 完成恢复后再交给界面。
  ProjectRepository._(this.root, this._database, this.freeBytes);

  final Directory root;
  final ProjectDatabase _database;
  final Future<int?> Function()? freeBytes;
  Future<void> _tail = Future.value();
  bool _closed = false;
  int unreadableProjects = 0;
  static const _uuid = Uuid();

  /// 打开数据库、恢复删除标记并清理未引用的临时资源。
  static Future<ProjectRepository> open(
    Directory root, {
    Future<int?> Function()? freeBytes,
    QueryExecutor? executor,
  }) async {
    await root.create(recursive: true);
    final database = ProjectDatabase(
      executor ??
          NativeDatabase.createInBackground(
            File(p.join(root.path, 'projects.sqlite')),
          ),
    );
    final repository = ProjectRepository._(root, database, freeBytes);
    try {
      await repository._recover();
      return repository;
    } catch (_) {
      await database.close();
      rethrow;
    }
  }

  /// 将文件与数据库操作串行化，失败不会污染后续队列。
  Future<T> _run<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('工程仓库已经关闭'));
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  /// 解析项目内相对路径，拒绝绝对路径、越界与符号链接。
  String resolve(AnimationProject project, String relative) {
    project.validate();
    if (relative.isEmpty ||
        p.isAbsolute(relative) ||
        p.windows.isAbsolute(relative) ||
        relative.split(RegExp(r'[/\\]')).contains('..')) {
      throw ArgumentError('文件路径必须位于当前项目内');
    }
    final base = p.join(root.path, 'projects', project.id);
    final result = p.normalize(p.join(base, relative));
    if (!p.isWithin(base, result)) throw ArgumentError('文件路径超出当前项目');
    var current = result;
    while (p.isWithin(root.path, current)) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw ArgumentError('项目文件不允许使用符号链接');
      }
      current = p.dirname(current);
    }
    return result;
  }

  /// 查询可见项目，损坏记录保留原数据并通过计数提示用户。
  Future<List<AnimationProject>> list() => _run(_list);

  /// 读取并解析数据库记录，供队列内部复用。
  Future<List<AnimationProject>> _list() async {
    final rows = await _database
        .customSelect(
          'SELECT payload FROM projects WHERE deleted=0 ORDER BY modified DESC',
        )
        .get();
    final projects = <AnimationProject>[];
    unreadableProjects = 0;
    for (final row in rows) {
      try {
        final project = AnimationProject.fromJson(
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        );
        _validatePaths(project);
        projects.add(project);
      } catch (_) {
        unreadableProjects++;
      }
    }
    return projects;
  }

  /// 校验所有工程引用，不允许持久化逃逸路径。
  void _validatePaths(AnimationProject project) {
    project.validate();
    for (final frame in project.frames) {
      resolve(project, frame.imagePath);
      resolve(project, frame.thumbnailPath);
    }
    if (project.audio != null) resolve(project, project.audio!.path);
  }

  /// 创建项目目录并保存第一份元数据。
  Future<AnimationProject> create(String name, CanvasFormat format) =>
      _run(() async {
        final project = AnimationProject(
          id: _uuid.v4(),
          name: name.trim(),
          format: format,
          updatedAt: DateTime.now(),
        );
        project.validate();
        for (final folder in ['frames', 'thumbs', 'audio', 'exports']) {
          await Directory(resolve(project, folder)).create(recursive: true);
        }
        await _save(project);
        return project;
      });

  /// 原子写入工程；只在提交成功后清理被移除的旧文件。
  Future<void> save(AnimationProject project) => _run(() => _save(project));

  /// 提交一份已校验的快照，并安全回收旧引用。
  Future<void> _save(AnimationProject project) async {
    _validatePaths(project);
    final previousRows = await _database
        .customSelect(
          'SELECT payload,deleted FROM projects WHERE id=?',
          variables: [Variable.withString(project.id)],
        )
        .get();
    AnimationProject? old;
    if (previousRows.isNotEmpty) {
      if (previousRows.first.read<int>('deleted') != 0) {
        throw StateError('作品已经删除，不能保存迟到的编辑结果');
      }
      old = AnimationProject.fromJson(
        jsonDecode(previousRows.first.read<String>('payload'))
            as Map<String, dynamic>,
      );
    }
    await _database.transaction(
      () => _database.customStatement(
        'INSERT INTO projects(id,payload,modified,deleted) VALUES(?,?,?,0) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,modified=excluded.modified',
        [
          project.id,
          jsonEncode(project.toJson()),
          project.updatedAt.microsecondsSinceEpoch,
        ],
      ),
    );
    if (old != null) {
      final removed = _references(old).difference(_references(project));
      for (final relative in removed) {
        await _tryDelete(File(resolve(project, relative)));
      }
    }
  }

  /// 返回工程真实引用的文件集合，用于提交后的安全回收。
  Set<String> _references(AnimationProject project) => {
    for (final frame in project.frames) ...[
      frame.imagePath,
      frame.thumbnailPath,
    ],
    if (project.audio != null) project.audio!.path,
  };

  /// 先标记删除再清理目录，中断后可以在下次启动重试。
  Future<void> delete(AnimationProject project) => _run(() async {
    project.validate();
    await _database.customStatement(
      'UPDATE projects SET deleted=1 WHERE id=?',
      [project.id],
    );
    final directory = Directory(p.dirname(resolve(project, 'marker')));
    if (await directory.exists()) await directory.delete(recursive: true);
    await _database.customStatement(
      "UPDATE projects SET deleted=2,payload='{}' WHERE id=?",
      [project.id],
    );
  });

  /// 在导入、拍摄和导出前核查可用空间；实际写入仍需捕获 I/O 错误。
  Future<void> requireSpace(int bytes) async {
    final available = await freeBytes?.call();
    if (available != null && available < bytes) {
      throw const FileSystemException('存储空间不足，请先清理手机空间');
    }
  }

  /// 导入并统一图片方向与画幅，生成缩略图后再提交工程。
  Future<AnimationProject> importFrame(
    AnimationProject project,
    File source, {
    int rotationDegrees = 0,
    bool mirror = false,
  }) => _run(() async {
    if (project.frames.length >= AnimationProject.maxFrames) {
      throw StateError('已达到 600 帧上限');
    }
    await requireSpace(128 * 1024 * 1024);
    if (await source.length() > 40 * 1024 * 1024) {
      throw const FormatException('图片文件过大');
    }
    final input = <String, Object>{
      'bytes': await source.readAsBytes(),
      'width': project.format.width,
      'height': project.format.height,
      'rotation': rotationDegrees,
      'mirror': mirror,
    };
    // Android 用插件一次完成方向、裁切和 JPEG 编码，避免每帧纯 Dart 像素遍历。
    final result = Platform.isAndroid
        ? await _prepareAndroidImage(input)
        : await compute(_prepareImage, input);
    final id = _uuid.v4();
    final frame = AnimationFrame(
      id: id,
      imagePath: 'frames/$id.jpg',
      thumbnailPath: 'thumbs/$id.jpg',
    );
    final original = File(resolve(project, frame.imagePath));
    final thumbnail = File(resolve(project, frame.thumbnailPath));
    try {
      await _write(original, result['image']!);
      await _write(thumbnail, result['thumbnail']!);
      final next = project.withFrames([...project.frames, frame]);
      await _save(next);
      return next;
    } catch (_) {
      await _tryDelete(original);
      await _tryDelete(thumbnail);
      rethrow;
    }
  });

  /// 复制原图和缩略图到新编号，副本不共享可删除文件。
  Future<AnimationProject> duplicateFrame(
    AnimationProject project,
    int index,
  ) => _run(() async {
    if (index < 0 || index >= project.frames.length) {
      throw RangeError.index(index, project.frames);
    }
    if (project.frames.length >= AnimationProject.maxFrames) {
      throw StateError('已达到 600 帧上限');
    }
    await requireSpace(128 * 1024 * 1024);
    final id = _uuid.v4();
    final frame = AnimationFrame(
      id: id,
      imagePath: 'frames/$id.jpg',
      thumbnailPath: 'thumbs/$id.jpg',
    );
    final target = File(resolve(project, frame.imagePath));
    final thumb = File(resolve(project, frame.thumbnailPath));
    try {
      await File(resolve(project, project.frames[index].imagePath))
          .copy(target.path);
      await File(resolve(project, project.frames[index].thumbnailPath))
          .copy(thumb.path);
      final frames = [...project.frames]..insert(index + 1, frame);
      final next = project.withFrames(frames);
      await _save(next);
      return next;
    } catch (_) {
      await _tryDelete(target);
      await _tryDelete(thumb);
      rethrow;
    }
  });

  /// 复制音频到项目内，流式读取并限制单文件大小。
  Future<String> importAudio(AnimationProject project, File source) =>
      _run(() async {
        final length = await source.length();
        if (length <= 0 || length > 100 * 1024 * 1024) {
          throw const FormatException('声音文件须大于 0 且不超过 100 MB');
        }
        await requireSpace(length + 128 * 1024 * 1024);
        final extension = p.extension(source.path).toLowerCase();
        if (![
          '.mp3',
          '.m4a',
          '.aac',
          '.wav',
          '.ogg',
          '.flac',
        ].contains(extension)) {
          throw const FormatException('不支持的声音文件格式');
        }
        final relative = 'audio/${_uuid.v4()}$extension';
        final target = File(resolve(project, relative));
        final temporary = File('${target.path}.tmp');
        try {
          await source.openRead().pipe(temporary.openWrite());
          if (await temporary.length() != length) {
            throw const FileSystemException('声音文件复制不完整');
          }
          await temporary.rename(target.path);
          return relative;
        } catch (_) {
          await _tryDelete(temporary);
          rethrow;
        }
      });

  /// 为录音或导出分配项目内的新文件路径。
  String newPath(AnimationProject project, String folder, String extension) {
    if (!['audio', 'exports'].contains(folder) ||
        !RegExp(r'^\.[a-z0-9]+(?:\.[a-z0-9]+)*$').hasMatch(extension)) {
      throw ArgumentError('无效的资源类型');
    }
    return resolve(project, '$folder/${_uuid.v4()}$extension');
  }

  /// 读取最后一次完整成片；保留相册保存失败后可直接重试的文件。
  Future<String?> lastExport(AnimationProject project) =>
      _run(() => _lastExport(project));

  /// 校验成片索引及实际文件，不把未完成的编码文件当成成片。
  Future<String?> _lastExport(AnimationProject project) async {
    try {
      final manifest = File(resolve(project, 'exports/latest.json'));
      if (!await manifest.exists()) return null;
      final payload =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      final relative = payload['path'] as String;
      final path = resolve(project, relative);
      if (!p.isWithin(resolve(project, 'exports'), path) ||
          !path.endsWith('.mp4')) {
        return null;
      }
      final file = File(path);
      return await file.exists() && await file.length() > 0 ? path : null;
    } on Object {
      return null;
    }
  }

  /// 原子记录新成片后回收旧版本，每个项目只保留最近一次完整导出。
  Future<void> keepExport(AnimationProject project, String path) =>
      _run(() async {
        final base = resolve(project, 'exports');
        if (!p.isWithin(base, path) ||
            !path.endsWith('.mp4') ||
            !await File(path).exists() ||
            await File(path).length() == 0) {
          throw const FileSystemException('导出文件无效');
        }
        final relative = p.relative(path, from: p.dirname(base));
        await _write(
          File(resolve(project, 'exports/latest.json')),
          Uint8List.fromList(utf8.encode(jsonEncode({'path': relative}))),
        );
        await _cleanExports(project, path);
      });

  /// 清理中断编码和旧成片，只保留持久索引指向的完整文件。
  Future<void> _cleanExports(AnimationProject project, String? keep) async {
    final directory = Directory(resolve(project, 'exports'));
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          entry.path != keep &&
          p.basename(entry.path) != 'latest.json') {
        await _tryDelete(entry);
      }
    }
  }

  /// 用临时文件替换最终文件，避免部分写入被当成完整资源。
  Future<void> _write(File file, Uint8List bytes) async {
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      await _tryDelete(temporary);
    }
  }

  /// 删除已无引用文件；失败留给下次启动回收，不撤销有效事务。
  Future<void> _tryDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* 下次启动重试。 */
    }
  }

  /// 恢复中断删除，回收项目内没有数据库引用的拍摄/音频临时文件。
  Future<void> _recover() async {
    final deleted = await _database
        .customSelect('SELECT id FROM projects WHERE deleted=1')
        .get();
    for (final row in deleted) {
      final id = row.read<String>('id');
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) continue;
      final stub = AnimationProject(
        id: id,
        name: '恢复',
        format: CanvasFormat.landscape,
        updatedAt: DateTime.now(),
      );
      final directory = Directory(p.dirname(resolve(stub, 'marker')));
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        await _database.customStatement(
          "UPDATE projects SET deleted=2,payload='{}' WHERE id=?",
          [id],
        );
      } on FileSystemException {
        /* 保留删除标记，后续重试。 */
      }
    }
    for (final project in await _list()) {
      final referenced = _references(project)
          .map((relative) => resolve(project, relative))
          .toSet();
      for (final folder in ['frames', 'thumbs', 'audio']) {
        final directory = Directory(resolve(project, folder));
        if (!await directory.exists()) continue;
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is File && !referenced.contains(entry.path)) {
            await _tryDelete(entry);
          }
        }
      }
      await _cleanExports(project, await _lastExport(project));
    }
  }

  /// 等待所有已提交的写入，再关闭数据库；可重复调用。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _tail;
    await _database.close();
  }
}

/// 先校验图片头再调用现成原生插件，EXIF 与相机方向只应用一次。
Future<Map<String, Uint8List>> _prepareAndroidImage(
  Map<String, Object> input,
) async {
  final bytes = input['bytes'] as Uint8List;
  final decoder = image.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 20000000) {
    throw const FormatException('图片损坏或尺寸超过 2000 万像素');
  }
  final orientation = image.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1;
  final hasOrientation = orientation != 1;
  final rotation = hasOrientation ? 0 : (input['rotation'] as int) % 360;
  if (rotation % 90 != 0) throw const FormatException('不支持的相机方向');
  final swapped = hasOrientation
      ? orientation >= 5 && orientation <= 8
      : rotation == 90 || rotation == 270;
  final sourceWidth = swapped ? info.height : info.width;
  final sourceHeight = swapped ? info.width : info.height;
  final width = input['width'] as int;
  final height = input['height'] as int;
  final ratio = width / height;
  final cropWidth = sourceWidth / sourceHeight > ratio
      ? (sourceHeight * ratio).round().clamp(1, sourceWidth)
      : sourceWidth;
  final cropHeight = sourceWidth / sourceHeight > ratio
      ? sourceHeight
      : (sourceWidth / ratio).round().clamp(1, sourceHeight);
  final options = native_image.ImageEditorOption()
    ..outputFormat = const native_image.OutputFormat.jpeg(90);
  if (rotation != 0) {
    options.addOption(native_image.RotateOption(rotation));
  }
  if (input['mirror'] as bool) {
    options.addOption(const native_image.FlipOption(horizontal: true));
  }
  options
    ..addOption(
      native_image.ClipOption(
        x: (sourceWidth - cropWidth) ~/ 2,
        y: (sourceHeight - cropHeight) ~/ 2,
        width: cropWidth,
        height: cropHeight,
      ),
    )
    ..addOption(native_image.ScaleOption(width, height));
  final normalized = await native_image.ImageEditor.editImage(
    image: bytes,
    imageEditorOption: options,
  );
  if (normalized == null || normalized.isEmpty) {
    throw const FormatException('无法处理拍摄照片');
  }
  final thumbnail = await native_image.ImageEditor.editImage(
    image: normalized,
    imageEditorOption: native_image.ImageEditorOption()
      ..outputFormat = const native_image.OutputFormat.jpeg(75)
      ..addOption(native_image.ScaleOption(240, (240 / ratio).round())),
  );
  if (thumbnail == null || thumbnail.isEmpty) {
    throw const FormatException('无法生成照片缩略图');
  }
  return {'image': normalized, 'thumbnail': thumbnail};
}

/// 在独立 isolate 中规范化照片并生成小缩略图，避免阻塞界面。
Map<String, Uint8List> _prepareImage(Map<String, Object> input) {
  final bytes = input['bytes'] as Uint8List;
  final decoder = image.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 20000000) {
    throw const FormatException('图片损坏或尺寸超过 2000 万像素');
  }
  var source = decoder!.decodeFrame(0);
  if (source == null) throw const FormatException('无法解码图片');
  final hasExifOrientation = (source.exif.imageIfd.orientation ?? 1) != 1;
  source = image.bakeOrientation(source);
  final rotation = input['rotation'] as int;
  if (!hasExifOrientation && rotation != 0) {
    source = image.copyRotate(source, angle: rotation);
  }
  if (input['mirror'] as bool) source = image.flipHorizontal(source);
  final width = input['width'] as int;
  final height = input['height'] as int;
  final ratio = width / height;
  final cropWidth = source.width / source.height > ratio
      ? (source.height * ratio).round()
      : source.width;
  final cropHeight = source.width / source.height > ratio
      ? source.height
      : (source.width / ratio).round();
  final cropped = image.copyCrop(
    source,
    x: (source.width - cropWidth) ~/ 2,
    y: (source.height - cropHeight) ~/ 2,
    width: cropWidth,
    height: cropHeight,
  );
  final normalized = image.copyResize(
    cropped,
    width: width,
    height: height,
    interpolation: image.Interpolation.average,
  );
  final thumbnail = image.copyResize(normalized, width: 240);
  return {
    'image': Uint8List.fromList(image.encodeJpg(normalized, quality: 90)),
    'thumbnail': Uint8List.fromList(image.encodeJpg(thumbnail, quality: 75)),
  };
}
