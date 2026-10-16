/// 定义成片画幅；布局方向改变不会修改项目画幅。
enum CanvasFormat {
  landscape,
  portrait;

  /// 返回 1080p 成片宽度。
  int get width => this == landscape ? 1920 : 1080;

  /// 返回 1080p 成片高度。
  int get height => this == landscape ? 1080 : 1920;

  /// 返回取景、洋葱皮与导出共用的宽高比。
  double get aspectRatio => width / height;

  /// 返回面向用户的画幅说明。
  String get label => this == landscape ? '横屏 16:9' : '竖屏 9:16';
}

/// 保存一张动画帧的稳定编号与项目内文件引用。
class AnimationFrame {
  /// 创建帧记录；路径由仓库校验并解析。
  const AnimationFrame({
    required this.id,
    required this.imagePath,
    required this.thumbnailPath,
  });

  final String id;
  final String imagePath;
  final String thumbnailPath;

  /// 将帧元数据转换为可持久化结构。
  Map<String, dynamic> toJson() => {
    'id': id,
    'image': imagePath,
    'thumbnail': thumbnailPath,
  };

  /// 从工程记录恢复文件引用，类型异常交由上层处理损坏项目。
  factory AnimationFrame.fromJson(Map<String, dynamic> json) => AnimationFrame(
    id: json['id'] as String,
    imagePath: json['image'] as String,
    thumbnailPath: json['thumbnail'] as String,
  );
}

/// 描述项目唯一音轨的源裁剪区间、音量与帧锚点。
class ProjectAudio {
  /// 创建音轨配置；毫秒区间以源文件为基准。
  const ProjectAudio({
    required this.path,
    required this.label,
    this.sourceStartMs = 0,
    required this.sourceEndMs,
    this.anchorFrameId,
    this.volume = .8,
    this.loop = false,
  });

  final String path;
  final String label;
  final int sourceStartMs;
  final int sourceEndMs;
  final String? anchorFrameId;
  final double volume;
  final bool loop;

  /// 返回裁剪后每次播放的长度。
  Duration get clipDuration =>
      Duration(milliseconds: sourceEndMs - sourceStartMs);

  /// 拒绝空裁剪、过长声音与非法音量。
  void validate() {
    if (path.isEmpty ||
        label.trim().isEmpty ||
        sourceStartMs < 0 ||
        sourceEndMs <= sourceStartMs ||
        sourceEndMs > 600000 ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 1) {
      throw const FormatException('声音裁剪范围或音量无效');
    }
  }

  /// 创建修改后的音轨；传入锚点时明确替换原锚点。
  ProjectAudio copyWith({
    int? sourceStartMs,
    int? sourceEndMs,
    String? anchorFrameId,
    double? volume,
    bool? loop,
  }) => ProjectAudio(
    path: path,
    label: label,
    sourceStartMs: sourceStartMs ?? this.sourceStartMs,
    sourceEndMs: sourceEndMs ?? this.sourceEndMs,
    anchorFrameId: anchorFrameId ?? this.anchorFrameId,
    volume: volume ?? this.volume,
    loop: loop ?? this.loop,
  );

  /// 序列化音轨参数，不嵌入音频数据。
  Map<String, dynamic> toJson() => {
    'path': path,
    'label': label,
    'start': sourceStartMs,
    'end': sourceEndMs,
    'anchor': anchorFrameId,
    'volume': volume,
    'loop': loop,
  };

  /// 恢复已持久化的音轨配置。
  factory ProjectAudio.fromJson(Map<String, dynamic> json) => ProjectAudio(
    path: json['path'] as String,
    label: json['label'] as String,
    sourceStartMs: json['start'] as int,
    sourceEndMs: json['end'] as int,
    anchorFrameId: json['anchor'] as String?,
    volume: (json['volume'] as num).toDouble(),
    loop: json['loop'] as bool,
  );
}

/// 保存不可变动画工程快照，统一帧顺序、播放时间和声音锚点。
class AnimationProject {
  /// 创建工程快照，复制帧列表防止外部并发修改。
  AnimationProject({
    required this.id,
    required this.name,
    required this.format,
    required this.updatedAt,
    this.fps = 4,
    List<AnimationFrame> frames = const [],
    this.audio,
    this.onionOpacity = .35,
    this.loop = true,
    this.intervalSeconds = 3,
  }) : frames = List.unmodifiable(frames);

  static const maxFrames = 600;
  static const supportedFps = [4, 6, 12];
  final String id;
  final String name;
  final CanvasFormat format;
  final DateTime updatedAt;
  final int fps;
  final List<AnimationFrame> frames;
  final ProjectAudio? audio;
  final double onionOpacity;
  final bool loop;
  final int intervalSeconds;

  /// 从总帧数计算时长，避免逐次累加毫秒误差。
  Duration get duration =>
      Duration(microseconds: (frames.length * 1000000 / fps).round());

  /// 按稳定帧编号计算音轨开始时间。
  Duration get audioOffset {
    final index = frames.indexWhere(
      (frame) => frame.id == audio?.anchorFrameId,
    );
    return Duration(
      microseconds: ((index < 0 ? 0 : index) * 1000000 / fps).round(),
    );
  }

  /// 校验工程边界，拒绝损坏元数据进入写入和导出流程。
  void validate() {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) ||
        name.trim().isEmpty ||
        name.length > 80 ||
        !supportedFps.contains(fps) ||
        frames.length > maxFrames ||
        frames.map((frame) => frame.id).toSet().length != frames.length ||
        !onionOpacity.isFinite ||
        onionOpacity < 0 ||
        onionOpacity > 1 ||
        intervalSeconds < 1 ||
        intervalSeconds > 60) {
      throw const FormatException('工程数据超出允许范围');
    }
    audio?.validate();
  }

  /// 返回修改后的快照；移除音轨必须显式使用 clearAudio。
  AnimationProject copyWith({
    String? name,
    int? fps,
    List<AnimationFrame>? frames,
    ProjectAudio? audio,
    bool clearAudio = false,
    double? onionOpacity,
    bool? loop,
    int? intervalSeconds,
  }) => AnimationProject(
    id: id,
    name: name ?? this.name,
    format: format,
    updatedAt: DateTime.now(),
    fps: fps ?? this.fps,
    frames: frames ?? this.frames,
    audio: clearAudio ? null : audio ?? this.audio,
    onionOpacity: onionOpacity ?? this.onionOpacity,
    loop: loop ?? this.loop,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
  );

  /// 替换时间轴；锚点被删除时将声音移到新首帧。
  AnimationProject withFrames(List<AnimationFrame> value) {
    final anchor = audio?.anchorFrameId;
    final nextAudio =
        audio != null &&
            anchor != null &&
            !value.any((frame) => frame.id == anchor)
        ? ProjectAudio(
            path: audio!.path,
            label: audio!.label,
            sourceStartMs: audio!.sourceStartMs,
            sourceEndMs: audio!.sourceEndMs,
            anchorFrameId: value.isEmpty ? null : value.first.id,
            volume: audio!.volume,
            loop: audio!.loop,
          )
        : audio;
    return copyWith(frames: value, audio: nextAudio);
  }

  /// 将工程保存为元数据，不包含图片或声音二进制。
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'format': format.name,
    'updated': updatedAt.toIso8601String(),
    'fps': fps,
    'frames': frames.map((frame) => frame.toJson()).toList(),
    'audio': audio?.toJson(),
    'onionOpacity': onionOpacity,
    'loop': loop,
    'interval': intervalSeconds,
  };

  /// 恢复工程后立即校验，拒绝非法设置。
  factory AnimationProject.fromJson(Map<String, dynamic> json) {
    final project = AnimationProject(
      id: json['id'] as String,
      name: json['name'] as String,
      format: CanvasFormat.values.byName(json['format'] as String),
      updatedAt: DateTime.parse(json['updated'] as String),
      fps: json['fps'] as int,
      frames: (json['frames'] as List)
          .map(
            (item) =>
                AnimationFrame.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(),
      audio: json['audio'] == null
          ? null
          : ProjectAudio.fromJson(
              Map<String, dynamic>.from(json['audio'] as Map),
            ),
      onionOpacity: (json['onionOpacity'] as num).toDouble(),
      loop: json['loop'] as bool,
      intervalSeconds: json['interval'] as int,
    );
    project.validate();
    return project;
  }
}
