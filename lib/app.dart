import 'package:flutter/material.dart';

import 'data/project_repository.dart';
import 'ui/home_screen.dart';
import 'ui/studio_theme.dart';

/// 装配主题与作品首页，仓库由启动入口统一持有。
class StudioApp extends StatefulWidget {
  /// 注入已完成恢复的项目仓库。
  const StudioApp({super.key, required this.repository});
  final ProjectRepository repository;

  /// 创建应用级内存压力观察者。
  @override
  State<StudioApp> createState() => _StudioAppState();
}

/// 在系统报告内存压力时收紧全局图像缓存预算。
class _StudioAppState extends State<StudioApp> with WidgetsBindingObserver {
  /// 注册应用级资源信号。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 内存紧张时降为 24 MiB 并回收已不在显示的缓存图像。
  @override
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.maximumSizeBytes = 24 * 1024 * 1024;
    PaintingBinding.instance.imageCache.clear();
  }

  /// 移除观察者，仓库仍由应用启动层持有。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 构建应用根路由与无调试角标的主题。
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '飞帧',
    debugShowCheckedModeBanner: false,
    theme: StudioColors.theme(),
    home: HomeScreen(repository: widget.repository),
  );
}
