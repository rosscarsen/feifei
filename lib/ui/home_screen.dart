import 'dart:io';

import 'package:flutter/material.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';
import 'editor_screen.dart';
import 'export_screen.dart';
import 'project_dialog.dart';
import 'storyboard_art.dart';
import 'studio_theme.dart';

/// 展示本地作品、创建入口与可实际编辑的示例工程。
class HomeScreen extends StatefulWidget {
  /// 共享应用级仓库，不在页面退出时关闭数据库。
  const HomeScreen({super.key, required this.repository});
  final ProjectRepository repository;

  /// 创建作品列表页面状态。
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 管理作品刷新、项目操作与示例生成进度。
class _HomeScreenState extends State<HomeScreen> {
  List<AnimationProject> _projects = [];
  bool _loading = true;
  bool _working = false;
  bool _showExamples = false;
  double _demoProgress = 0;
  String? _error;

  /// 页面打开后从数据库加载作品。
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 刷新作品并保留可重试错误状态。
  Future<void> _refresh() async {
    try {
      final projects = await widget.repository.list();
      if (mounted) {
        setState(() {
          _projects = projects;
          _loading = false;
          _error = null;
        });
      }
    } catch (exception) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = exception.toString();
        });
      }
    }
  }

  /// 读取最新作品自动编号，用户点选画幅后直接创建并进入工作台。
  Future<void> _create() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final projects = await widget.repository.list();
      if (!mounted) return;
      final names = projects.map((project) => project.name).toSet();
      var number = 1;
      String name;
      do {
        name = '我的动画 ${number.toString().padLeft(2, '0')}';
        number++;
      } while (names.contains(name));
      final draft = await showDialog<ProjectDraft>(
        context: context,
        builder: (_) => ProjectDialog(suggestedName: name),
      );
      if (draft == null || !mounted) return;
      final project = await widget.repository.create(draft.name, draft.format);
      if (mounted) {
        setState(() => _showExamples = false);
        await _open(project);
      }
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// 打开工作台，返回后重新读取自动保存的版本。
  Future<void> _open(AnimationProject project) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            EditorScreen(repository: widget.repository, project: project),
      ),
    );
    if (mounted) await _refresh();
  }

  /// 生成原创二十四帧示例，生成过程中阻止重复创建。
  Future<void> _demo() async {
    if (_working) return;
    setState(() {
      _working = true;
      _demoProgress = 0;
    });
    try {
      final project = await createDemoProject(
        widget.repository,
        onProgress: (value) {
          if (mounted) setState(() => _demoProgress = value);
        },
      );
      if (mounted) await _open(project);
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// 按菜单操作重命名、导出或删除，删除需要二次确认。
  Future<void> _action(AnimationProject project, String action) async {
    if (_working) return;
    try {
      switch (action) {
        case 'rename':
          final draft = await showDialog<ProjectDraft>(
            context: context,
            builder: (_) => ProjectDialog(initialName: project.name),
          );
          if (draft != null) {
            await widget.repository.save(project.copyWith(name: draft.name));
          }
        case 'export':
        case 'last-export':
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ExportScreen(
                repository: widget.repository,
                project: project,
                reuseLatest: action == 'last-export',
              ),
            ),
          );
        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('删除这部作品？'),
              content: Text('“${project.name}”的照片和声音会从应用中删除，已保存到相册的视频保留。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('保留'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('删除作品'),
                ),
              ],
            ),
          );
          if (confirmed == true) await widget.repository.delete(project);
      }
      if (mounted) await _refresh();
    } catch (exception) {
      if (mounted) showStudioMessage(context, exception);
    }
  }

  /// 展示本地使用指引，不需要跳转外部网站。
  void _help() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('从一帧开始，创造一个世界'),
      content: const SingleChildScrollView(
        child: Text(
          '1. 新建作品，选择横屏或竖屏画幅。\n\n'
          '2. 固定手机与灯光，轻轻移动角色，每移动一点拍一张。洋葱皮能帮你对齐上一帧。\n\n'
          '3. 点击底部照片编辑，长按拖动调整顺序；4、6、12 FPS 决定播放速度。\n\n'
          '4. 打开声音库，选用原创素材、导入音频或录制配音。一个项目使用一条音轨。\n\n'
          '5. 导出 1080p 视频，再保存到系统相册。拍摄和导出期间请保持应用在前台。\n\n'
          '可以先打开“风起小岛”示例，体验编辑、声音与导出。\n\n'
          '飞帧 · Android 试玩版\n作品保存在本机；卸载应用会移除应用内的项目，请先保存成片。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('开始探索'),
        ),
      ],
    ),
  );

  /// 默认展示作品，将示例与创作入口放在固定导航中并懒加载作品封面。
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final padding = constraints.maxWidth > 800 ? 48.0 : 22.0;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: CustomScrollView(
                key: PageStorageKey(
                  _showExamples ? 'home-examples' : 'home-works',
                ),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      padding,
                      constraints.maxHeight < 400 ? 12 : 24,
                      padding,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: StudioColors.ink,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.movie_filter_rounded,
                              color: StudioColors.mint,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '飞帧',
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 2,
                                  ),
                                ),
                                Text(
                                  'FRAME BY FRAME, MAKE IT YOURS',
                                  style: TextStyle(
                                    fontSize: 9,
                                    letterSpacing: 1,
                                    color: Color(0xff68756c),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _help,
                            tooltip: '使用教程与关于',
                            icon: const Icon(Icons.help_outline_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showExamples)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        padding,
                        constraints.maxHeight < 400 ? 12 : 28,
                        padding,
                        18,
                      ),
                      sliver: SliverToBoxAdapter(child: _hero()),
                    ),
                  if (!_showExamples) ...[
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(padding, 24, padding, 0),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '我的作品',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              '${_projects.length} 部故事',
                              style: const TextStyle(color: Color(0xff758077)),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: _working ? null : _refresh,
                              tooltip: '刷新作品',
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (widget.repository.unreadableProjects > 0)
                      SliverPadding(
                        padding: EdgeInsets.all(padding),
                        sliver: SliverToBoxAdapter(
                          child: Text(
                            '有 ${widget.repository.unreadableProjects} 个工程记录无法读取，原文件已保留。',
                            style: const TextStyle(color: Colors.deepOrange),
                          ),
                        ),
                      ),
                    if (_loading)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(48),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      )
                    else if (_error != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(padding),
                          child: TextButton(
                            onPressed: _refresh,
                            child: const Text('加载失败，点击重试'),
                          ),
                        ),
                      )
                    else if (_projects.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: padding,
                            vertical: 38,
                          ),
                          child: const Column(
                            children: [
                              Icon(
                                Icons.auto_awesome_outlined,
                                size: 42,
                                color: Color(0xff8da095),
                              ),
                              SizedBox(height: 16),
                              Text(
                                '第一部故事，就从这里开始。',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                '点击下方“开始”，选择画幅，拍下第一帧。',
                                style: TextStyle(color: Color(0xff758077)),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(padding, 16, padding, 32),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: constraints.maxWidth > 680
                                    ? 2
                                    : 1,
                                mainAxisExtent: 274,
                                crossAxisSpacing: 20,
                                mainAxisSpacing: 20,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => _projectCard(_projects[index]),
                            childCount: _projects.length,
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            '灵感在当下，故事在每一帧。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xff89948b),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
    bottomNavigationBar: _navigation(),
  );

  /// 固定作品、示例与开始入口；开始只弹出画幅选择，不切换空白页面。
  Widget _navigation() => Material(
    color: StudioColors.paper,
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xffe1e7e1)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  Expanded(
                    child: _destination(
                      false,
                      Icons.video_library_outlined,
                      '作品',
                    ),
                  ),
                  Expanded(
                    child: _destination(
                      true,
                      Icons.auto_awesome_outlined,
                      '示例',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('create-project'),
                      onPressed: _working ? null : _create,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_rounded, size: 24),
                          SizedBox(height: 2),
                          Text('开始'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// 用文字、底色及无障碍选中语义显示当前首页栏目。
  Widget _destination(bool examples, IconData icon, String label) {
    final selected = _showExamples == examples;
    return Semantics(
      selected: selected,
      child: TextButton(
        onPressed: _working
            ? null
            : () => setState(() => _showExamples = examples),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? const Color(0xff18735f)
              : const Color(0xff758077),
          backgroundColor: selected
              ? const Color(0xffe7f3ec)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24),
            const SizedBox(height: 2),
            Text(label),
          ],
        ),
      ),
    );
  }

  /// 在示例栏目展示原创纸艺动画，点击后生成可编辑的本地副本。
  Widget _hero() => Container(
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).height < 500 ? 16 : 22),
    decoration: BoxDecoration(
      color: const Color(0xffe7eee7),
      borderRadius: BorderRadius.circular(28),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = MediaQuery.sizeOf(context).height < 500;
        final details = _exampleDetails(compact);
        final art = ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: const AspectRatio(
            aspectRatio: 16 / 9,
            child: CustomPaint(painter: StoryboardPainter(progress: .28)),
          ),
        );
        if (constraints.maxWidth >= 500) {
          return Row(
            children: [
              Expanded(flex: 5, child: details),
              const SizedBox(width: 24),
              Expanded(flex: 4, child: art),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [art, const SizedBox(height: 20), details],
        );
      },
    ),
  );

  /// 将示例说明与打开按钮放在同一列，横屏时不被大幅封面推到屏幕下方。
  Widget _exampleDetails(bool compact) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '原创示例 · 24 帧',
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 1.2,
          color: Color(0xff627d6e),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        '风起小岛',
        style: TextStyle(
          fontSize: compact ? 26 : 30,
          height: 1.2,
          fontWeight: FontWeight.w800,
          color: StudioColors.ink,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        '打开一段小故事，\n试试播放、配乐和导出。',
        style: TextStyle(height: 1.5, fontSize: 12, color: Color(0xff5f7568)),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _working ? null : _demo,
        icon: const Icon(Icons.play_circle_outline_rounded),
        label: const Text('体验示例'),
      ),
      if (_working && _demoProgress > 0 && _demoProgress < 1)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(value: _demoProgress),
        ),
    ],
  );

  /// 绘制封面并提供带文字的作品菜单。
  Widget _projectCard(AnimationProject project) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(22),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: _working ? null : () => _open(project),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (project.frames.isEmpty)
                  const CustomPaint(painter: StoryboardPainter())
                else
                  Image.file(
                    File(
                      widget.repository.resolve(
                        project,
                        project.frames.first.thumbnailPath,
                      ),
                    ),
                    fit: BoxFit.cover,
                    cacheWidth: 600,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Color(0xffe7eee7),
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
                Positioned(
                  left: 14,
                  top: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .88),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      project.format.label,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(17, 10, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${project.frames.length} 帧  ·  ${project.fps} FPS  ·  ${durationLabel(project.duration)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff78857b),
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '作品操作',
                  onSelected: (value) => _action(project, value),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('修改名称')),
                    PopupMenuItem(value: 'export', child: Text('导出视频')),
                    PopupMenuItem(value: 'last-export', child: Text('查看上次成片')),
                    PopupMenuItem(value: 'delete', child: Text('删除作品')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
