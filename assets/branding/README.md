# 飞帧品牌素材

图形由矢量路径绘制：薄荷绿场记板、播放镂空与暖金星光，沿用应用的深色和暖白配色。

- `mark.svg`：可编辑母版。
- `icon.png`：1024 像素传统桌面图标，保留圆角。
- `adaptive_foreground.png`：Android 8+ 自适应图标前景，背景由配置提供。
- `adaptive_monochrome.png`：Android 13+ 单色主题图标，镂空仍保持透明。
- `splash.png`：1152 像素透明画布；标志位于 Android 12 系统圆形遮罩安全区域，背景由原生主题填充暖白。

只需 PNG 即可重新生成原生资源：

```powershell
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

配置分别在项目根目录的 flutter_launcher_icons.yaml 和 flutter_native_splash.yaml。仅生成 Android，其他平台未启用。

这些原图未声明为 Flutter 运行时 assets，应用使用生成后的原生各密度资源，不在 Dart 首帧重复解码大图。启动屏无固定停留时间、无联网、无额外启动 Activity。

需要调整图形时修改 `mark.svg`，用本地开发脚本 `tool/generate_branding.cjs` 重新栅格化；脚本需要 Node.js 与 sharp，不参与运行和 APK 构建。
