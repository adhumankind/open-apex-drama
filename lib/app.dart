import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_state/appearance.dart';
import 'screens/app_shell.dart';
import 'theme/app_theme.dart';

class ApexApp extends StatelessWidget {
  const ApexApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appearanceMode,
      builder: (BuildContext context, ThemeMode mode, _) => MaterialApp(
        title: '红果-阿帝版',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        // 桌面默认不允许鼠标拖动列表（横向列表在 Windows 上因此完全
        // 滑不动，如详情页季选择行）；放开鼠标拖拽，移动端无感。
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          dragDevices: <PointerDeviceKind>{
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.trackpad,
          },
        ),
        home: const AppShell(),
      ),
    );
  }
}
