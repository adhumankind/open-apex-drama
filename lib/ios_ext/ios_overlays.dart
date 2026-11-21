import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../services/dlna/dlna_manager.dart';
import '../widgets/cast_remote_overlay.dart';

/// 右侧操作栏扩展：在原操作栏上方附加「投屏」「旋转」两个按钮。
class IosActionRailExtra extends StatelessWidget {
  const IosActionRailExtra({
    super.key,
    required this.child,
    required this.onCast,
    required this.onRotate,
  });

  final Widget child;
  final VoidCallback onCast;
  final VoidCallback onRotate;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DlnaManager.instance.isCastingNotifier,
      builder: (BuildContext context, bool isCasting, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _IosRailAction(
              icon: Icons.cast_rounded,
              label: isCasting ? '投屏中' : '投屏',
              tooltip: '投屏到电视',
              iconColor: isCasting ? const Color(0xFFFF4D4F) : null,
              onTap: onCast,
            ),
            const SizedBox(height: 10),
            _IosRailAction(
              icon: Icons.screen_rotation_rounded,
              label: '旋转',
              tooltip: '旋转屏幕',
              onTap: onRotate,
            ),
            const SizedBox(height: 10),
            child,
          ],
        );
      },
    );
  }
}

class _IosRailAction extends StatelessWidget {
  const _IosRailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.tooltip,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String tooltip;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: label,
        child: InkResponse(
          onTap: onTap,
          radius: 26,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 27,
                color: iconColor ?? Colors.white.withValues(alpha: 0.94),
                shadows: <Shadow>[
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 8,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.86),
                  shadows: <Shadow>[
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 播放器最外层叠加容器：承接锁屏盾、亮度蒙层、悬浮锁屏键、提示胶囊与投屏遥控浮层。
class IosPlayerOverlayStack extends StatelessWidget {
  const IosPlayerOverlayStack({
    super.key,
    required this.child,
    required this.listenable,
    required this.isScreenLocked,
    required this.lockButtonVisible,
    required this.screenBrightness,
    required this.centerHintText,
    required this.isMobile,
    required this.controlsVisible,
    required this.drama,
    required this.episode,
    required this.episodeTitle,
    required this.onToggleLock,
    required this.onPulseLock,
    required this.onPlayPrevious,
    required this.onPlayNext,
    required this.onExitCast,
  });

  final Widget child;
  final Listenable listenable;
  final bool Function() isScreenLocked;
  final bool Function() lockButtonVisible;
  final double Function() screenBrightness;
  final String? Function() centerHintText;
  final bool isMobile;
  final bool controlsVisible;
  final Drama drama;
  final int episode;
  final String episodeTitle;
  final VoidCallback onToggleLock;
  final VoidCallback onPulseLock;
  final VoidCallback onPlayPrevious;
  final VoidCallback onPlayNext;
  final VoidCallback onExitCast;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child,
        Positioned.fill(
          child: ListenableBuilder(
            listenable: listenable,
            builder: (BuildContext context, _) {
              final bool locked = isScreenLocked();
              final bool lockVisible = lockButtonVisible();
              final double brightness = screenBrightness();
              final String? hint = centerHintText();

              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (locked)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onPulseLock,
                        onDoubleTap: onPulseLock,
                        onLongPress: onPulseLock,
                        onPanStart: (_) => onPulseLock(),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  if (brightness < 0.99)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: Colors.black.withValues(
                            alpha: (1.0 - brightness).clamp(0.0, 0.8),
                          ),
                        ),
                      ),
                    ),
                  if (isMobile)
                    Positioned(
                      left: 16,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 240),
                          opacity: locked
                              ? (lockVisible ? 0.92 : 0.22)
                              : (controlsVisible ? 0.88 : 0.0),
                          child: IgnorePointer(
                            ignoring: !locked && !controlsVisible,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: onToggleLock,
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.58),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.22),
                                    width: 0.8,
                                  ),
                                  boxShadow: const <BoxShadow>[
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 8,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  locked
                                      ? Icons.lock_rounded
                                      : Icons.lock_open_rounded,
                                  color: locked
                                      ? const Color(0xFFFF4D4F)
                                      : Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (hint != null)
                    IgnorePointer(
                      child: Center(
                        child: Material(
                          type: MaterialType.transparency,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.68),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.16),
                                    width: 0.5,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(
                                      hint.contains('快退')
                                          ? Icons.replay_5_rounded
                                          : Icons.forward_5_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      hint,
                                      style: const TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Positioned.fill(
          child: ValueListenableBuilder<bool>(
            valueListenable: DlnaManager.instance.isCastingNotifier,
            builder: (BuildContext context, bool isCasting, _) {
              if (!isCasting) {
                return const SizedBox.shrink();
              }
              return Material(
                type: MaterialType.transparency,
                child: CastRemoteOverlay(
                  drama: drama,
                  episodeNumber: episode,
                  episodeTitle: episodeTitle,
                  onPlayPrevious: onPlayPrevious,
                  onPlayNext: onPlayNext,
                  onExitCast: onExitCast,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 剧终祝贺与操作弹层。
void showIosSeriesFinishedSheet(
  BuildContext context, {
  required Drama drama,
  required int episodeCount,
  required VoidCallback onReplayFirst,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) {
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
            decoration: BoxDecoration(
              color: const Color(0xFF161822).withValues(alpha: 0.92),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
                width: 0.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('🎉', style: TextStyle(fontSize: 40)),
                const SizedBox(height: 8),
                const Text(
                  '恭喜追完全部剧集',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '《${drama.title}》全 $episodeCount 集已播放完毕',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          onReplayFirst();
                        },
                        child: const Text('重温第 1 集'),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF4D4F),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          Navigator.of(context).maybePop();
                        },
                        child: const Text('返回发现新剧'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
