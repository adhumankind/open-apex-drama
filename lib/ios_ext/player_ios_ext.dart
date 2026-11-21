import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../app_state/playback_prefs.dart';
import '../models/drama.dart';
import '../services/dlna/dlna_device.dart';
import '../services/dlna/dlna_manager.dart';
import '../widgets/dlna_sheet.dart';
import 'ios_overlays.dart';

/// 播放器 iOS 定制扩展控制器（锁屏、方向旋转、边缘亮度/音量、跳过片头片尾、DLNA 投屏、剧终提示）。
///
/// 抽离于 `player_screen.dart` 之外，保持上游主文件仅留薄钩子，便于跟随上游升级。
class PlayerIosExt extends ChangeNotifier {
  bool _disposed = false;

  bool _isScreenLocked = false;
  bool _lockButtonVisible = true;
  Timer? _lockButtonHideTimer;

  ({IconData icon, String text})? _centerHint;
  Timer? _centerHintTimer;

  int _verticalDragMode = 0; // 0: 上下滑切集, 1: 左边缘亮度, 2: 右边缘音量
  double _screenBrightness = 1.0;

  bool get isScreenLocked => _isScreenLocked;

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void showHint(String text, {IconData icon = Icons.info_outline_rounded}) {
    _centerHintTimer?.cancel();
    _centerHint = (icon: icon, text: text);
    _notify();
    _centerHintTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_disposed) {
        _centerHint = null;
        _notify();
      }
    });
  }

  void pulseLockButton() {
    _lockButtonHideTimer?.cancel();
    _lockButtonVisible = true;
    _notify();
    _lockButtonHideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!_disposed && _isScreenLocked) {
        _lockButtonVisible = false;
        _notify();
      }
    });
  }

  void toggleScreenLock(ValueChanged<bool> onSetControls) {
    _isScreenLocked = !_isScreenLocked;
    if (_isScreenLocked) {
      onSetControls(false);
      pulseLockButton();
      showHint('屏幕已锁定', icon: Icons.lock_rounded);
    } else {
      onSetControls(true);
      showHint('屏幕已解锁', icon: Icons.lock_open_rounded);
    }
    HapticFeedback.mediumImpact();
    _notify();
  }

  void rotateOrientation(
    BuildContext context, {
    required bool isFullscreen,
    required VoidCallback onAfter,
  }) {
    final Orientation current = MediaQuery.orientationOf(context);
    if (current == Orientation.portrait) {
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      showHint('已切换为横屏', icon: Icons.screen_rotation_rounded);
    } else {
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      if (!isFullscreen) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
      showHint('已切换为竖屏', icon: Icons.screen_rotation_rounded);
    }
    HapticFeedback.lightImpact();
    onAfter();
  }

  void applyFullscreenOrientation(Player? player) {
    final int? vWidth = player?.state.width;
    final int? vHeight = player?.state.height;
    final bool isVideoLandscape =
        vWidth != null && vHeight != null && vWidth > vHeight;
    if (isVideoLandscape) {
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void seekRelative(Player? player, int seconds, VoidCallback onPersist) {
    if (player == null) {
      return;
    }
    final Duration current = player.state.position;
    final Duration total = player.state.duration;
    final Duration target = current + Duration(seconds: seconds);
    final Duration clamped = target < Duration.zero
        ? Duration.zero
        : (total > Duration.zero && target > total ? total : target);
    player.seek(clamped);
    onPersist();
    HapticFeedback.lightImpact();
    showHint(
      seconds > 0 ? '+5s 快进' : '-5s 快退',
      icon: seconds > 0 ? Icons.forward_5_rounded : Icons.replay_5_rounded,
    );
  }

  void onDoubleTapDown(
    BuildContext context,
    TapDownDetails details,
    Player? player,
    VoidCallback onPersist,
    VoidCallback onTogglePlay,
  ) {
    final double width = MediaQuery.sizeOf(context).width;
    if (width <= 0) {
      onTogglePlay();
      return;
    }
    final double ratio = details.localPosition.dx / width;
    if (ratio < 0.38) {
      seekRelative(player, -5, onPersist);
    } else if (ratio > 0.62) {
      seekRelative(player, 5, onPersist);
    } else {
      onTogglePlay();
    }
  }

  Future<void> handleCastTap(
    BuildContext context, {
    required String streamUrl,
    required Player? player,
    required int episode,
    required Drama drama,
  }) async {
    final DlnaDevice? picked = await showCastDeviceSheet(context);
    if (picked == null || !context.mounted || _disposed) {
      return;
    }
    await _startCastToDevice(
      context,
      picked,
      streamUrl: streamUrl,
      player: player,
      episode: episode,
      drama: drama,
    );
  }

  Future<void> _startCastToDevice(
    BuildContext context,
    DlnaDevice device, {
    required String streamUrl,
    required Player? player,
    required int episode,
    required Drama drama,
  }) async {
    if (streamUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前集视频地址正在加载，请稍候...')),
      );
      return;
    }
    if (player != null) {
      unawaited(player.pause());
    }
    final Duration curPos = player?.state.position ?? Duration.zero;
    final bool ok = await DlnaManager.instance.cast(
      device: device,
      mediaUrl: streamUrl,
      title: '第$episode集 ${drama.title}',
      posterUrl: drama.coverUrl,
      startPosition: curPos,
    );
    if (!context.mounted || _disposed) {
      return;
    }
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('投屏至 ${device.name} 失败，请确认电视与手机在同一 Wi-Fi'),
        ),
      );
    } else {
      _notify();
    }
  }

  Future<void> exitCast(Player? player, VoidCallback onResumed) async {
    final Duration tvPos = DlnaManager.instance.castPositionNotifier.value;
    await DlnaManager.instance.stop();
    if (_disposed) {
      return;
    }
    if (player != null) {
      if (tvPos > Duration.zero) {
        await player.seek(tvPos);
      }
      await player.play();
    }
    onResumed();
    _notify();
  }

  Future<void> onStreamOpened(
    Player player,
    String streamUrl,
    Duration resumeFrom,
    int episode,
    Drama drama,
  ) async {
    if (resumeFrom <= Duration.zero) {
      final int skipIntro = skipIntroSecondsNotifier.value;
      if (skipIntro > 0) {
        await player.seek(Duration(seconds: skipIntro));
        showHint('已跳过片头 $skipIntro 秒', icon: Icons.fast_forward_rounded);
      }
    }
    if (DlnaManager.instance.isCastingNotifier.value) {
      final DlnaDevice? dev = DlnaManager.instance.activeDeviceNotifier.value;
      if (dev != null) {
        await player.pause();
        unawaited(
          DlnaManager.instance.cast(
            device: dev,
            mediaUrl: streamUrl,
            title: '第$episode集 ${drama.title}',
            posterUrl: drama.coverUrl,
            startPosition: resumeFrom,
          ),
        );
      }
    }
  }

  bool shouldSkipOutro(Duration position, Duration total, bool enabled) {
    final int skipOutro = skipOutroSecondsNotifier.value;
    if (skipOutro <= 0 || !enabled) {
      return false;
    }
    return total.inSeconds > skipOutro &&
        position >= total - Duration(seconds: skipOutro);
  }

  bool onVerticalDragStart(BuildContext context, DragStartDetails details) {
    final double width = MediaQuery.sizeOf(context).width;
    if (width <= 0) {
      _verticalDragMode = 0;
      return false;
    }
    final double xRatio = details.localPosition.dx / width;
    if (xRatio < 0.18) {
      _verticalDragMode = 1;
      return true;
    }
    if (xRatio > 0.82) {
      _verticalDragMode = 2;
      return true;
    }
    _verticalDragMode = 0;
    return false;
  }

  bool onVerticalDragUpdate(
    DragUpdateDetails details,
    double currentVolume,
    ValueChanged<double> setVolume,
  ) {
    if (_verticalDragMode == 1) {
      final double delta = -details.delta.dy / 250.0;
      _screenBrightness = (_screenBrightness + delta).clamp(0.2, 1.0);
      showHint(
        '亮度 ${(_screenBrightness * 100).toInt()}%',
        icon: Icons.brightness_6_rounded,
      );
      return true;
    }
    if (_verticalDragMode == 2) {
      final double delta = -details.delta.dy / 250.0;
      final double next = (currentVolume + delta).clamp(0.0, 1.0);
      setVolume(next);
      showHint(
        next <= 0.01 ? '静音' : '音量 ${(next * 100).toInt()}%',
        icon: next <= 0.01 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      );
      return true;
    }
    return false;
  }

  bool onVerticalDragEnd() {
    if (_verticalDragMode != 0) {
      _verticalDragMode = 0;
      return true;
    }
    return false;
  }

  void showSeriesFinished(
    BuildContext context,
    Drama drama,
    int episodeCount,
    VoidCallback onReplay,
  ) {
    showIosSeriesFinishedSheet(
      context,
      drama: drama,
      episodeCount: episodeCount,
      onReplayFirst: onReplay,
    );
  }

  Widget wrapActionRail(
    BuildContext context,
    Widget rail,
    String streamUrl,
    Player? player,
    int episode,
    Drama drama,
    bool isFullscreen,
    VoidCallback onAfterRotate,
  ) {
    return IosActionRailExtra(
      onCast: () => unawaited(
        handleCastTap(
          context,
          streamUrl: streamUrl,
          player: player,
          episode: episode,
          drama: drama,
        ),
      ),
      onRotate: () => rotateOrientation(
        context,
        isFullscreen: isFullscreen,
        onAfter: onAfterRotate,
      ),
      child: rail,
    );
  }

  Widget wrapPlayerTree(
    BuildContext context,
    Widget child,
    bool isMobile,
    bool controlsVisible,
    Drama drama,
    int episode,
    String episodeTitle, {
    required ValueChanged<bool> onSetControls,
    required VoidCallback onPrev,
    required VoidCallback onNext,
    required VoidCallback onExitCast,
  }) {
    return IosPlayerOverlayStack(
      listenable: this,
      isScreenLocked: () => _isScreenLocked,
      lockButtonVisible: () => _lockButtonVisible,
      screenBrightness: () => _screenBrightness,
      centerHint: () => _centerHint,
      isMobile: isMobile,
      controlsVisible: controlsVisible,
      drama: drama,
      episode: episode,
      episodeTitle: episodeTitle,
      onToggleLock: () => toggleScreenLock(onSetControls),
      onPulseLock: pulseLockButton,
      onPlayPrevious: onPrev,
      onPlayNext: onNext,
      onExitCast: onExitCast,
      child: child,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _centerHintTimer?.cancel();
    _lockButtonHideTimer?.cancel();
    if (!Platform.isWindows) {
      try {
        SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.portraitUp,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (_) {}
    }
    try {
      unawaited(DlnaManager.instance.stop());
    } catch (_) {}
    super.dispose();
  }
}
