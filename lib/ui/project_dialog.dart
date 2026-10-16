import 'package:flutter/material.dart';

import '../domain/project.dart';
import 'studio_theme.dart';

/// 保存新建项目输入，不在界面层创建任何文件。
class ProjectDraft {
  /// 记录已确定的作品名称与画幅，交由调用者保存。
  const ProjectDraft(this.name, this.format);
  final String name;
  final CanvasFormat format;
}

/// 新建时直接选择画幅，重命名时单独展示输入表单并管理控制器生命周期。
class ProjectDialog extends StatefulWidget {
  /// initialName 非空时修改名称；新建时采用调用方提供的自动编号。
  const ProjectDialog({
    super.key,
    this.initialName,
    this.suggestedName = '我的动画 01',
  });
  final String? initialName;
  final String suggestedName;

  /// 创建表单状态。
  @override
  State<ProjectDialog> createState() => _ProjectDialogState();
}

/// 分离无需键盘的画幅入口与名称校验，防止用户连续点击导致重复返回。
class _ProjectDialogState extends State<ProjectDialog> {
  TextEditingController? _name;
  final _form = GlobalKey<FormState>();
  bool _completed = false;

  /// 仅重命名模式创建输入控制器，新建模式不唤起键盘。
  @override
  void initState() {
    super.initState();
    if (widget.initialName != null) {
      _name = TextEditingController(text: widget.initialName);
    }
  }

  /// 释放文本控制器。
  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  /// 验证用户修改的名称，画幅由原工程保留。
  void _saveName() {
    if (!mounted || _completed) return;
    if (_form.currentState?.validate() ?? false) {
      _finish(ProjectDraft(_name!.text.trim(), CanvasFormat.landscape));
    }
  }

  /// 一个弹窗只提交一次结果，避免快速点选两张卡片时误退出下一层页面。
  void _finish(ProjectDraft draft) {
    if (!mounted || _completed) return;
    _completed = true;
    Navigator.pop(context, draft);
  }

  /// 将关闭按钮也纳入提交互斥，避免关闭动画期间再次点选触发返回。
  void _cancel() {
    if (!mounted || _completed) return;
    _completed = true;
    Navigator.pop(context);
  }

  /// 将新建入口与重命名表单分开，画幅选择不会受到键盘挤压。
  @override
  Widget build(BuildContext context) =>
      widget.initialName == null ? _creationDialog() : _renameDialog();

  /// 以并排卡片直接创建工程，低矮窗口收起装饰和提示，保留全部选择入口。
  Widget _creationDialog() => Dialog(
    insetPadding: const EdgeInsets.all(16),
    backgroundColor: StudioColors.paper,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tight = constraints.maxHeight < 240;
          final compact =
              constraints.maxHeight < 400 ||
              MediaQuery.textScalerOf(context).scale(16) > 22;
          return Padding(
            padding: EdgeInsets.all(
              tight
                  ? 12
                  : compact
                  ? 16
                  : 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择画幅',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 20 : 24,
                          fontWeight: FontWeight.w700,
                          color: StudioColors.ink,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _cancel,
                      tooltip: '取消新建',
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                if (!compact)
                  const Text(
                    '选一个画幅，开始你的故事。',
                    style: TextStyle(fontSize: 13, color: Color(0xff66776d)),
                  ),
                SizedBox(
                  height: tight
                      ? 8
                      : compact
                      ? 12
                      : 20,
                ),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final format in CanvasFormat.values) ...[
                        if (format != CanvasFormat.values.first)
                          const SizedBox(width: 12),
                        Expanded(
                          child: _CanvasFormatCard(
                            key: ValueKey('create-format-${format.name}'),
                            format: format,
                            compact: compact,
                            tight: tight,
                            onSelected: () => _finish(
                              ProjectDraft(widget.suggestedName, format),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 18),
                  const Text(
                    '自动命名，作品名称可稍后在作品菜单中修改。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Color(0xff66776d)),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ),
  );

  /// 重命名单独提供名称输入框，保留小窗口与键盘下的滚动避让。
  Widget _renameDialog() => AlertDialog(
    title: const Text('修改作品名称'),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 360,
        child: Form(
          key: _form,
          child: TextFormField(
            controller: _name,
            maxLength: 80,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: '作品名称'),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请输入作品名称' : null,
            onFieldSubmitted: (_) => _saveName(),
          ),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: _cancel, child: const Text('取消')),
      FilledButton(onPressed: _saveName, child: const Text('保存')),
    ],
  );
}

/// 以真实画幅轮廓展示横屏和竖屏，整张卡片均可点击创建工程。
class _CanvasFormatCard extends StatelessWidget {
  /// 接收画幅和完成操作，紧凑模式只减少装饰，不隐藏文字入口。
  const _CanvasFormatCard({
    super.key,
    required this.format,
    required this.compact,
    required this.tight,
    required this.onSelected,
  });

  final CanvasFormat format;
  final bool compact;
  final bool tight;
  final VoidCallback onSelected;

  /// 使用清晰的画幅文字与独立无障碍操作，避免只依赖示意图辨别方向。
  @override
  Widget build(BuildContext context) {
    final landscape = format == CanvasFormat.landscape;
    final accent = landscape
        ? const Color(0xff18735f)
        : const Color(0xff94723d);
    return Semantics(
      label: '${format.label}，创建动画',
      button: true,
      onTap: onSelected,
      excludeSemantics: true,
      child: Material(
        color: landscape ? const Color(0xffe4eee6) : const Color(0xfff0e9da),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: accent.withValues(alpha: .16)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelected,
          child: Padding(
            padding: EdgeInsets.all(
              tight
                  ? 8
                  : compact
                  ? 12
                  : 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!tight) ...[
                  SizedBox(
                    height: compact ? 48 : 76,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: format.aspectRatio,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: .15),
                                blurRadius: 12,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: Icon(
                            landscape
                                ? Icons.landscape_rounded
                                : Icons.person_rounded,
                            size: compact ? 24 : 32,
                            color: Colors.white.withValues(alpha: .85),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 8 : 14),
                ],
                Text(
                  landscape ? '横屏' : '竖屏',
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: StudioColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  landscape ? '16:9' : '9:16',
                  style: TextStyle(fontSize: 12, height: 1.2, color: accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
