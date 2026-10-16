import 'package:flutter/material.dart';

/// 集中定义工作室的明暗色彩，保持项目页与创作页一致。
abstract final class StudioColors {
  static const paper = Color(0xfff6f4ef);
  static const ink = Color(0xff172126);
  static const mint = Color(0xff47bfa7);
  static const night = Color(0xff101a1e);
  static const panel = Color(0xff223137);
  static const gold = Color(0xffd7b477);

  /// 创建以留白和清晰文字为主的 Material 主题。
  static ThemeData theme({bool dark = false}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: mint,
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: dark ? night : paper,
      primary: dark ? mint : const Color(0xff18735f),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? night : paper,
      fontFamily: 'sans-serif',
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? night : paper,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? panel : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: DividerThemeData(
        color: dark ? Colors.white12 : const Color(0xffe0e4de),
      ),
    );
  }
}

/// 将设备与存储错误转换为简短的可操作提示。
void showStudioMessage(BuildContext context, Object error) {
  final message = error.toString().replaceFirst(
    RegExp(r'^(Bad state: |FormatException: |Exception: )'),
    '',
  );
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// 为作品和声音显示紧凑的时长，保留短动画的小数秒。
String durationLabel(Duration duration) {
  if (duration.inSeconds < 60) {
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(duration.inMilliseconds % 1000 == 0 ? 0 : 1)} 秒';
  }
  return '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}
