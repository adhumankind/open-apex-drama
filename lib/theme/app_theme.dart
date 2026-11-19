import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  /// 统一中文字体。
  ///
  /// Windows 下默认正文是 Segoe UI，它没有中文字形，每个汉字都要回退到
  /// 微软雅黑；而字重变化时又会命中不同字面（Regular / Bold / 合成粗体），
  /// 于是同一屏里中文、数字、英文像是几种字体拼起来的。这里按平台钉死一套
  /// 中文优先的字体族，中英数字同出一源。Android 本身中英统一走 Noto，
  /// 保持系统默认，避免指定了不存在的字族反而更乱。
  static String? get _platformFontFamily {
    if (Platform.isWindows) {
      return 'Microsoft YaHei UI';
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return 'PingFang SC';
    }
    return null;
  }

  /// 字族回退链：平台首选字体缺失时按序尝试，最后回到系统默认。
  static const List<String> _fontFamilyFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
  ];

  static ThemeData get light => _build(Brightness.light, AppColors.light);

  static ThemeData get dark => _build(Brightness.dark, AppColors.dark);

  static ThemeData _build(Brightness brightness, AppColors palette) {
    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: palette.brand,
        brightness: brightness,
      ),
    );

    final ColorScheme scheme = base.colorScheme.copyWith(
      primary: palette.brand,
      onPrimary: palette.onBrand,
      primaryContainer: palette.accentSoft,
      onPrimaryContainer: palette.accentText,
      secondary: AppTokens.goldDeep,
      onSecondary: const Color(0xFF2E1B00),
      surface: palette.surface,
      onSurface: palette.textPrimary,
      surfaceContainerHighest: palette.surfaceMuted,
      outline: palette.hairline,
      outlineVariant: palette.hairline,
      surfaceTint: Colors.transparent,
    );

    final TextTheme baseText = base.textTheme;
    final TextTheme textTheme = baseText
        .copyWith(
          displaySmall: baseText.displaySmall?.copyWith(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            height: 1.22,
          ),
          headlineSmall: baseText.headlineSmall?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          titleLarge: baseText.titleLarge?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
          titleMedium: baseText.titleMedium?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
          titleSmall: baseText.titleSmall?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
          bodyLarge: baseText.bodyLarge?.copyWith(fontSize: 15, height: 1.5),
          bodyMedium: baseText.bodyMedium?.copyWith(fontSize: 14, height: 1.5),
          bodySmall: baseText.bodySmall?.copyWith(fontSize: 12, height: 1.45),
          labelLarge: baseText.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          labelMedium: baseText.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          labelSmall: baseText.labelSmall?.copyWith(
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        )
        .apply(
          bodyColor: palette.textPrimary,
          displayColor: palette.textPrimary,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: _platformFontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.page,
      canvasColor: palette.page,
      cardColor: palette.surface,
      dividerColor: palette.hairline,
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[palette],
      splashFactory: InkSparkle.splashFactory,
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>((
          Set<WidgetState> states,
        ) {
          return states.contains(WidgetState.selected)
              ? Colors.white
              : palette.surface;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color>((
          Set<WidgetState> states,
        ) {
          return states.contains(WidgetState.selected)
              ? palette.brand
              : palette.surfaceMuted;
        }),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.brand,
        linearTrackColor: palette.surfaceMuted,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }
}
