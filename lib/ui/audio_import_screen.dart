import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'studio_theme.dart';

/// 在应用内分页选择本机音频，权限拒绝和加载期间也保留返回与取消入口。
class AudioImportScreen extends StatefulWidget {
  /// 其他文件入口沿用系统选择器，用于媒体库尚未收录的文件。
  const AudioImportScreen({super.key, required this.onOtherLocation});
  final VoidCallback onOtherLocation;

  /// 创建只保存当前一页元数据的选择状态。
  @override
  State<AudioImportScreen> createState() => _AudioImportScreenState();
}

/// 管理权限、分页与选择互斥，离开后忽略所有迟到结果。
class _AudioImportScreenState extends State<AudioImportScreen> {
  static const _pageSize = 50;
  List<AssetEntity> _items = [];
  int _page = 0;
  bool _loading = true;
  bool _authorized = false;
  String? _error;
  String? _selecting;
  bool _leaving = false;

  /// 同步标记退出，退场动画期间的迟到读取也不能再操作导航。
  void _cancel({bool otherLocation = false}) {
    if (_leaving) return;
    _leaving = true;
    if (otherLocation) {
      widget.onOtherLocation();
    } else {
      Navigator.pop(context);
    }
  }

  /// 页面挂载后才查询音频权限，不影响首页和相机启动。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(0, requestPermission: true));
    });
  }

  /// 读取一页音频元数据；不会读取音频字节或申请照片、视频权限。
  Future<void> _load(int page, {bool requestPermission = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (requestPermission) {
        final access = await PhotoManager.requestPermissionExtend(
          requestOption: const PermissionRequestOption(
            androidPermission: AndroidPermission(
              type: RequestType.audio,
              mediaLocation: false,
            ),
          ),
        );
        if (!mounted || _leaving) return;
        _authorized = access.isAuth;
      }
      if (!_authorized) return;
      final items = await PhotoManager.getAssetListPaged(
        page: page,
        pageCount: _pageSize,
        type: RequestType.audio,
      );
      if (!mounted || _leaving) return;
      setState(() {
        _items = items;
        _page = page;
      });
    } catch (exception) {
      if (mounted && !_leaving) setState(() => _error = '暂时无法读取音频，请重试或从其他文件选择');
    } finally {
      if (mounted && !_leaving) setState(() => _loading = false);
    }
  }

  /// 在获取本机文件前检查大小，取消后不再弹提示或操作导航。
  Future<void> _select(AssetEntity item) async {
    if (_selecting != null || _leaving) return;
    setState(() => _selecting = item.id);
    try {
      final size = await item.fileSize;
      if (!mounted || _leaving) return;
      if (size <= 0 || size > 100 * 1024 * 1024) {
        throw const FormatException('声音文件须大于 0 且不超过 100 MB');
      }
      _leaving = true;
      Navigator.pop(context, item);
    } catch (exception) {
      if (mounted && !_leaving) showStudioMessage(context, exception);
    } finally {
      if (mounted && !_leaving) setState(() => _selecting = null);
    }
  }

  /// 构建固定退出入口、懒加载列表与分页操作，不要求用户滑动才能取消。
  @override
  Widget build(BuildContext context) => PopScope<AssetEntity>(
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) _leaving = true;
    },
    child: Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _cancel),
        title: const Text('选择本机音频'),
        actions: [
          TextButton(onPressed: _cancel, child: const Text('取消')),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择一条声音 · 最大 100 MB',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _cancel(otherLocation: true),
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('其他文件'),
                  ),
                ],
              ),
            ),
            Expanded(child: _content()),
            if (_authorized && !_loading && _error == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _page == 0 ? null : () => _load(_page - 1),
                      child: const Text('上一页'),
                    ),
                    Text(
                      '第 ${_page + 1} 页',
                      style: const TextStyle(fontSize: 12),
                    ),
                    TextButton(
                      onPressed: _items.length < _pageSize
                          ? null
                          : () => _load(_page + 1),
                      child: const Text('下一页'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  /// 展示加载、授权、空列表或音频列表，所有状态共用固定顶部工具栏。
  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_authorized || _error != null || _items.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.audio_file_outlined, size: 42),
                const SizedBox(height: 16),
                Text(
                  _error ??
                      (_authorized
                          ? '没有找到音频，可从“其他文件”选择。'
                          : '允许读取本机音频后，即可在这里选择声音。'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => _load(0, requestPermission: true),
                  child: Text(_authorized ? '重新读取' : '允许读取音频'),
                ),
                if (!_authorized)
                  TextButton(
                    onPressed: PhotoManager.openSetting,
                    child: const Text('打开系统设置'),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.music_note_rounded)),
          title: Text(
            item.title ?? '未命名音频',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(durationLabel(item.videoDuration)),
          trailing: _selecting == item.id
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_circle_outline),
          onTap: _selecting == null ? () => _select(item) : null,
        );
      },
    );
  }
}
