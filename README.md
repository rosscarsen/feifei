# 飞帧 · Android 定格动画试玩版

Flutter 实现的本地定格动画创作应用。暖白作品页、深色创作工作台、薄荷绿与金色点缀；界面与插画重新设计，未复制参考视频的品牌或声音。

## 直接试看

常见 ARM64 手机使用 `dist/feifei-android-arm64-1.0.6.apk`（约 54 MiB）。Android 7.0 / API 24 及以上，Flutter 版本 1.0.6+7，ARM64 分包的 Android versionCode 为 2007，包名 `com.lamb.feifei`。本轮按项目当前 Release 签名配置构建，校验和在 dist/SHA256SUMS.txt；与 dist 中 1.0.5 测试包的证书不同，不能直接覆盖旧测试包，请保留作品并先保存成片。

首页默认打开“作品”，底部固定“作品／示例／开始”。点击“开始”选择横屏或竖屏；在“示例”栏目点击“体验示例”，生成 24 帧“风起小岛”，直接体验预览、声音和导出。实际拍摄请允许相机权限，录音时允许麦克风权限。

## 已实现

- 本地作品创建、横竖画幅、重命名、删除、自动保存和再次打开。
- 原生应用图标、Android 自适应及单色图标、Android 12 前后的原生启动屏；暖白底色与首页一致，没有固定停留时间。
- 首页固定导航，取消画幅选择后保留所在栏目；新建成功后回到作品栏目，示例可生成独立的可编辑副本。
- 新建时并排展示横屏和竖屏卡片，点选后直接创作，不唤起键盘、不滚动；名称自动采用未占用的“我的动画 01、02……”编号，可在作品菜单修改。
- 所有应用页面使用沉浸全面屏；按工程画幅自动横屏或竖屏，声音编辑、应用内音频选择、导出及返回作品列表均保持所选方向，直到新建或打开另一画幅的工程。拍摄画面按原比例放大到屏幕内最大尺寸，操作栏悬浮显示；挖孔和刘海区域由按钮安全边距避让。
- 前后镜头、点击对焦、缩放、单张和定时间隔拍摄；设备支持时提供对焦、曝光、白平衡锁定。
- 上一帧洋葱皮、透明度设置、拍摄提示音；每次进入拍摄页默认关闭洋葱皮，手动开启后叠加上一帧，叠加图层不写入照片。
- 打开已有工程直接进入实时取景；从照片预览开启洋葱皮会恢复镜头。照片使用原版 CameraX 的逐张旋转角设置 EXIF，避免重复应用硬件已完成的旋转。
- 拍摄页上方固定“洋葱皮”“循环播放”文字开关及开关状态，横竖屏无需滚动；快门固定保留。洋葱皮在拍过照片后的实时取景中生效，透明度在拍摄设置调整。
- 帧预览、独立复制、删除、前后移动和长按拖动排序；4 / 6 / 12 FPS，播放、暂停和循环。播放中、暂停后或播放结束后可直接按快门，自动停止预览、恢复镜头并拍摄一帧；恢复期间拦截重复点击，退后台取消尚未执行的快门请求。
- 单音轨的导入、试听、麦克风配音、实际波形、裁剪、音量、循环及帧锚点。
- Android 默认打开应用内音频选择页，顶部固定返回和取消；仅请求音频读取权限，按页读取元数据。未收录文件可通过“其他文件”调用系统选择器，其界面由系统管理。
- 内置三分类六段原创程序合成素材：乐器、自然、生活；无在线下载依赖。
- 1080p MP4 / H.264 / AAC 导出、取消、成片播放、保存系统相册与系统分享。
- 每个项目保留最近一次完整成片。作品菜单“查看上次成片”可重试保存或分享。

本阶段只验收 Android。iOS、Windows 工程模板尚未适配或验收；账号、素材云服务、多音轨、4K 和后台持续创作不在试玩范围。

## 资源与边界

项目最多 600 帧；拍摄间隔 1–60 秒；配音最多 150 秒；导入声音不超过 100 MiB、10 分钟。照片统一到项目画幅，Android 通过 image_editor 原生处理队列完成旋转、裁剪和压缩，其他平台保留独立 isolate 路径；缩略图及屏幕预览按需加载。快门提示在 CameraX 开始曝光时触发，保存期间仍限制重复拍摄。

数据库保存元数据，原图和声音保存在应用私有目录。文件写入串行处理，引用提交后才清理旧文件；删除保留墓碑，防止迟到保存复活作品。启动会恢复中断删除、回收无引用素材及未完成导出。

相机代理在 finally 中关闭；离开页面或退后台停止拍摄、预览与录音。录音启停均有互斥和过期结果检查。导出取消等待插件准备及渲染任务安全结束，之后才清理文件。

卸载会删除应用内作品；请先把成片保存到相册。应用内没有云端备份。

五项客户约定的逐项复核与本轮音频选择器内存风险修正，见 docs/five-features-audit.md。

1.0.2 全面屏、拍摄画幅放大及相机绑定时序修复的验证记录，见 docs/fullscreen-audit.md。

1.0.3 无滚动画幅选择、自动命名及横竖屏截图，见 docs/create-dialog-audit.md。

1.0.4 首页导航与预览开关的验证记录，见 docs/navigation-audit.md。

1.0.5 图标、原生启动屏及播放器按需初始化，见 docs/startup-audit.md。

1.0.6 拍摄延迟、洋葱皮方向及音频选择退出入口，见 docs/camera-feedback-audit.md。旧版已经错误裁剪的照片不能恢复丢失内容；方向修正对新拍照片生效。

## 图标与启动屏

使用 [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons) 0.14.4 和 [flutter_native_splash](https://pub.dev/packages/flutter_native_splash) 2.4.8，均放在开发依赖。配置分别为 flutter_launcher_icons.yaml、flutter_native_splash.yaml；可编辑母版及 PNG 在 assets/branding。

```powershell
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

本阶段仅生成 Android 资源。启动屏随首个 Flutter 帧自动移除，不调用 preserve/remove、不添加延时和额外启动页面。播放器在首次创建 MediaSession 时初始化，首页不提前创建播放器；数据库恢复仍在展示作品前完成。原图不打入 Flutter 运行时 assets，应用直接使用生成的原生资源。

## 开发与验证

已验证工具链：Flutter 3.47.7 / Dart 3.13.5、JDK 17+、compileSdk 37、minSdk 24。依赖版本以 pubspec.lock 为准。

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d <Android设备ID>
flutter build apk --release
```

真实 Android 插件测试（先启动模拟器）：

```powershell
./tool/run_android_checks.ps1
./tool/run_android_checks.ps1 -TestFile integration_test/android_resources_test.dart -LogName android-resources -ArtifactName device-resources
./tool/run_android_checks.ps1 -TestFile integration_test/android_fullscreen_test.dart -LogName fullscreen-android -ArtifactName fullscreen-validation
./tool/run_camera_feedback_checks.ps1
```

旧版 run_android_checks.ps1 会由 Flutter 安装、卸载测试包，仅用于可清空数据的测试设备。run_camera_feedback_checks.ps1 仅操作模拟器，覆盖安装 Debug 测试入口，保留作品数据，并在 finally 中只删除它自己写入的单个测试音频；权限拒绝由组件回归测试单独检查。

若本机 Java 下载 Maven 依赖需要代理，在当前构建终端设置 GRADLE_OPTS 的 http.proxyHost/http.proxyPort/https.proxyHost/https.proxyPort，不把个人代理地址写进项目全局配置。

`tool/verify_media.py` 使用 ffmpeg、ffprobe、NumPy、Pillow 比较实际成片与原始缩略图；`tool/generate_sounds.py` 可按固定种子重新生成声音。完整证据与物理设备待验项见 docs/android-validation.md。

## 依赖使用

相机使用 camerax 1.2.2；照片合成与音轨封装使用 pro_video_editor 2.33.0；试听与成片播放统一使用 media_kit 1.2.6、media_kit_video 2.0.1、media_kit_libs_video 1.0.7，播放层可供后续 Windows 复用。图片处理使用 image_editor 1.6.0，Android 音频元数据读取使用 photo_manager 3.12.0。录音、文件选择、图库、分享与数据库均使用现有包。

相机直接使用包仓库发布的原版 camerax，其 Android 实现 camerax_android 由插件自动引入，没有 dependency_overrides 或本地相机源码副本。照片保存以 ImageProxy.imageInfo.rotationDegrees 为准，把剩余旋转角写入 JPEG 的 EXIF，由现有图片处理流程应用一次。照片方向遵循 CameraX 的拍摄目标方向；工程画幅和拍摄页的横竖屏限制由应用单独设置。

原版 CameraController 会根据手机的物理方向更新拍摄目标。锁定页面横竖屏不会锁定这个目标；锁屏后改变握持方向时，照片可能与当前取景窗口方向不同。此次不再用矩阵补丁强制对齐窗口，前后摄与各握持方向的实际效果仍需在目标手机验证。

camerax 1.2.2 没有暴露原生初始化 Future，Dart 层对“尚未初始化”的能力查询做有限重试，拍摄前等待实际 CameraState.open。音轨合成保留完整无声视频与原帧率；单图编码补一个结束采样，避免零时长。均通过现有 API 组合解决。

当前部分 Android 插件仍会触发 Flutter 的 Kotlin Gradle 插件迁移提示，具体名单以当前构建输出为准。升级 Flutter 或任一媒体包后应重跑集成与帧数检查，并验证横竖屏、前后摄的照片方向。

设计与视频解析：docs/superpowers/specs/2026-10-15-android-stop-motion-design.md。
