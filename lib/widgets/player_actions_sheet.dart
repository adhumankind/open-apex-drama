import 'package:flutter/material.dart';

import '../ios_ext/player_actions_ios_ext.dart';
import '../theme/app_colors.dart';

/// 移动端播放页的「播放设置」弹层。
///
/// 承接右栏和长按中间两个入口：清晰度、弹幕设置、自动播放、音量。
/// 不常用但需要在播放中快速调整的项集中在这里，避免底部控制行拥挤。
Future<void> showPlayerActionsSheet(
  BuildContext context, {
  required bool autoPlay,
  required ValueChanged<bool> onAutoPlayChanged,
  required double volume,
  required bool muted,
  required ValueChanged<double> onVolumeChanged,
  required String qualityLabel,
  required VoidCallback onQuality,
  required VoidCallback onDanmakuSettings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (BuildContext context) => PlayerActionsSheet(
      autoPlay: autoPlay,
      onAutoPlayChanged: onAutoPlayChanged,
      volume: volume,
      muted: muted,
      onVolumeChanged: onVolumeChanged,
      qualityLabel: qualityLabel,
      onQuality: onQuality,
      onDanmakuSettings: onDanmakuSettings,
    ),
  );
}

class PlayerActionsSheet extends StatefulWidget {
  const PlayerActionsSheet({
    super.key,
    required this.autoPlay,
    required this.onAutoPlayChanged,
    required this.volume,
    required this.muted,
    required this.onVolumeChanged,
    required this.qualityLabel,
    required this.onQuality,
    required this.onDanmakuSettings,
  });

  final bool autoPlay;
  final ValueChanged<bool> onAutoPlayChanged;
  final double volume;
  final bool muted;
  final ValueChanged<double> onVolumeChanged;
  final String qualityLabel;
  final VoidCallback onQuality;
  final VoidCallback onDanmakuSettings;

  @override
  State<PlayerActionsSheet> createState() => _PlayerActionsSheetState();
}

class _PlayerActionsSheetState extends State<PlayerActionsSheet> {
  late bool _autoPlay = widget.autoPlay;
  late double _volume = widget.volume;
  late bool _muted = widget.muted;

  void _dismissThen(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final String quality = widget.qualityLabel.isEmpty
        ? '自动'
        : widget.qualityLabel;
    return IosFrostedSheetShell(
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 8, 4),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '播放设置',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                  ),
                ],
              ),
            ),
            _SheetRow(
              icon: Icons.high_quality_rounded,
              label: '清晰度',
              value: quality,
              onTap: () => _dismissThen(widget.onQuality),
            ),
            _SheetRow(
              icon: Icons.subtitles_rounded,
              label: '弹幕设置',
              onTap: () => _dismissThen(widget.onDanmakuSettings),
            ),
            _SheetRow(
              icon: Icons.play_circle_outline_rounded,
              label: '自动播放',
              trailing: _SheetSwitch(
                value: _autoPlay,
                onChanged: (bool value) {
                  setState(() => _autoPlay = value);
                  widget.onAutoPlayChanged(value);
                },
              ),
            ),
            const IosSkipPrefsRows(),
            _VolumeRow(
              volume: _muted ? 0 : _volume,
              muted: _muted,
              onChanged: (double value) {
                setState(() {
                  _volume = value;
                  _muted = value <= 0.01;
                });
                widget.onVolumeChanged(value);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Container(
        width: 34,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget row = Padding(
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
          if (value != null)
            Text(
              value!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.2,
                color: Colors.white.withValues(alpha: 0.52),
              ),
            ),
          ?trailing,
          if (onTap != null)
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: Colors.white.withValues(alpha: 0.34),
            ),
        ],
      ),
    );
    if (onTap == null) {
      return row;
    }
    return InkWell(onTap: onTap, child: row);
  }
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({
    required this.volume,
    required this.muted,
    required this.onChanged,
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Row(
        children: <Widget>[
          Icon(
            muted || volume <= 0.01
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
            size: 20,
            color: Colors.white.withValues(alpha: 0.78),
          ),
          const SizedBox(width: 12),
          Text(
            '音量',
            style: TextStyle(
              fontSize: 14,
              height: 1.2,
              color: Colors.white.withValues(alpha: 0.90),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: AppTokens.immersiveAccent,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: volume.clamp(0.0, 1.0),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetSwitch extends StatelessWidget {
  const _SheetSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: '自动播放',
      child: GestureDetector(
        onTap: () => onChanged(!value),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 38,
          height: 22,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: value
                ? AppTokens.immersiveAccent
                : Colors.white.withValues(alpha: 0.20),
            borderRadius: BorderRadius.circular(11),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
