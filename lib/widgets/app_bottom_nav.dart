import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 底部导航与桌面侧边栏共用的条目数据。
class AppNavEntry {
  const AppNavEntry({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class AppBottomNav extends StatelessWidget {
  const AppBottomNav({super.key, required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const List<AppNavEntry> entries = <AppNavEntry>[
    AppNavEntry(
      label: '首页',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
    ),
    AppNavEntry(
      label: '分类',
      icon: Icons.grid_view_outlined,
      selectedIcon: Icons.grid_view_rounded,
    ),
    AppNavEntry(
      label: '看剧',
      icon: Icons.play_circle_outline_rounded,
      selectedIcon: Icons.play_circle_rounded,
    ),
    AppNavEntry(
      label: '追剧',
      icon: Icons.favorite_border_rounded,
      selectedIcon: Icons.favorite_rounded,
    ),
    AppNavEntry(
      label: '我的',
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.navBar.withValues(alpha: 0.85),
            border: Border(top: BorderSide(color: colors.hairline, width: 0.8)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < entries.length; i++)
                    Expanded(
                      child: _NavItem(
                        entry: entries[i],
                        selected: i == index,
                        onTap: () => onChanged(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面宽窗布局用的左侧导航栏（条目与 [AppBottomNav] 完全同源）。
class AppSideNav extends StatelessWidget {
  const AppSideNav({super.key, required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.navBar,
        border: Border(right: BorderSide(color: colors.hairline, width: 0.8)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: 84,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 12),
                child: Image.asset(
                  'assets/images/logo.png',
                  width: 34,
                  height: 34,
                ),
              ),
              for (int i = 0; i < AppBottomNav.entries.length; i++)
                _SideNavItem(
                  entry: AppBottomNav.entries[i],
                  selected: i == index,
                  onTap: () => onChanged(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideNavItem extends StatelessWidget {
  const _SideNavItem({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final AppNavEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;
    final Color color = selected
        ? (context.isDark ? colors.brand : colors.brandDeep)
        : colors.textTertiary;

    return Semantics(
      button: true,
      selected: selected,
      label: entry.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 54,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: selected ? color.withAlpha(20) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                selected ? entry.selectedIcon : entry.icon,
                size: 23,
                color: color,
              ),
              const SizedBox(height: 3),
              Text(
                entry.label,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final AppNavEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = context.colors;
    final Color color = selected
        ? (context.isDark ? colors.brand : colors.brandDeep)
        : colors.textTertiary;

    return Semantics(
      button: true,
      selected: selected,
      label: entry.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 48,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AnimatedScale(
                scale: selected ? 1.05 : 1,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(
                  selected ? entry.selectedIcon : entry.icon,
                  size: 23,
                  color: color,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
                child: Text(entry.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
