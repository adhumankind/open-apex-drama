import 'dart:async' show unawaited;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_state/playback_prefs.dart';

/// 播放设置弹窗的 iOS 磨砂毛玻璃外壳。
class IosFrostedSheetShell extends StatelessWidget {
  const IosFrostedSheetShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF14161E).withValues(alpha: 0.88),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 播放设置弹窗中的跳过片头 / 跳过片尾设置项。
class IosSkipPrefsRows extends StatefulWidget {
  const IosSkipPrefsRows({super.key});

  @override
  State<IosSkipPrefsRows> createState() => _IosSkipPrefsRowsState();
}

class _IosSkipPrefsRowsState extends State<IosSkipPrefsRows> {
  late int _skipIntro = skipIntroSecondsNotifier.value;
  late int _skipOutro = skipOutroSecondsNotifier.value;

  void _showSkipDialog({required bool isIntro}) {
    final int current = isIntro ? _skipIntro : _skipOutro;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2028),
          title: Text(
            isIntro ? '跳过片头' : '跳过片尾',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <int>[0, 3, 5, 8, 10].map((int seconds) {
              final bool selected = current == seconds;
              return ListTile(
                title: Text(
                  seconds == 0 ? '不跳过' : '跳过 $seconds 秒',
                  style: TextStyle(
                    color: selected ? const Color(0xFFFF4D4F) : Colors.white,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                trailing: selected
                    ? const Icon(Icons.check, color: Color(0xFFFF4D4F))
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    if (isIntro) {
                      _skipIntro = seconds;
                      unawaited(saveSkipIntroSeconds(seconds));
                    } else {
                      _skipOutro = seconds;
                      unawaited(saveSkipOutroSeconds(seconds));
                    }
                  });
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _IosActionRow(
          icon: Icons.fast_forward_rounded,
          label: '跳过片头',
          value: _skipIntro == 0 ? '不跳过' : '$_skipIntro秒',
          onTap: () => _showSkipDialog(isIntro: true),
        ),
        _IosActionRow(
          icon: Icons.skip_next_rounded,
          label: '跳过片尾',
          value: _skipOutro == 0 ? '不跳过' : '$_skipOutro秒',
          onTap: () => _showSkipDialog(isIntro: false),
        ),
      ],
    );
  }
}

class _IosActionRow extends StatelessWidget {
  const _IosActionRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.78)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.90),
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.2,
                color: Colors.white.withValues(alpha: 0.52),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: Colors.white.withValues(alpha: 0.34),
            ),
          ],
        ),
      ),
    );
  }
}
