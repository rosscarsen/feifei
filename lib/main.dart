import 'dart:io';

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/project_repository.dart';
import 'ui/studio_theme.dart';

/// 只初始化必要的作品仓库与缓存；播放器延迟到首次使用，原生启动屏随首帧移除。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 120;
  try {
    final documents = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(documents.path, 'feifei-studio'));
    final repository = await ProjectRepository.open(
      root,
      freeBytes: () async {
        if (!Platform.isAndroid) return null;
        final megabytes = await DiskSpacePlus().getFreeDiskSpaceForPath(
          root.path,
        );
        return megabytes == null ? null : (megabytes * 1024 * 1024).floor();
      },
    );
    runApp(StudioApp(repository: repository));
  } catch (_) {
    runApp(const StartupFailureApp());
  }
}

/// 存储初始化失败时提供重试入口，不停留在空白启动页。
class StartupFailureApp extends StatelessWidget {
  /// 创建不依赖数据库的启动错误页面。
  const StartupFailureApp({super.key});

  /// 提示用户检查存储并重新初始化应用。
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: StudioColors.theme(),
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_off_outlined, size: 48),
                const SizedBox(height: 20),
                const Text(
                  '暂时无法打开作品库',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text('请检查手机存储空间，然后重试。', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: main, child: const Text('重新打开')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
