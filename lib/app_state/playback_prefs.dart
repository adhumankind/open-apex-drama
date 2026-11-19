import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局播放偏好：倍速与自动连播。
///
/// 倍速与自动连播是「用户习惯」而不是「单集状态」：在任意一部剧里调过之后，
/// 换剧、切集、重启应用都沿用同一个值。模式与 appearance.dart /
/// profile.dart 一致——全局 ValueNotifier + 启动加载 + 写入即通知。
final ValueNotifier<double> playbackRateNotifier = ValueNotifier<double>(1.0);
final ValueNotifier<bool> autoPlayNotifier = ValueNotifier<bool>(true);

const String _kRateKey = 'playback.rate.v1';
const String _kAutoPlayKey = 'playback.autoplay.v1';

/// 本地默认倍速；1.0 表示原速。
const double kDefaultPlaybackRate = 1.0;

/// 启动时恢复上次选择的倍速与自动连播偏好（在 runApp 前调用）。
///
/// SharedPreferences 不可用（widget 测试 / 插件未注册）时降级为默认值，
/// 接口行为一致。
Future<void> loadPlaybackPrefs() async {
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final double? rate = prefs.getDouble(_kRateKey);
    if (rate != null && rate > 0) {
      playbackRateNotifier.value = rate;
    }
    final bool? autoPlay = prefs.getBool(_kAutoPlayKey);
    if (autoPlay != null) {
      autoPlayNotifier.value = autoPlay;
    }
  } catch (_) {
    playbackRateNotifier.value = kDefaultPlaybackRate;
    autoPlayNotifier.value = true;
  }
}

/// 记住用户新选的倍速：更新全局状态并落盘，失败只影响下次启动的恢复。
Future<void> savePlaybackRate(double rate) async {
  if (rate <= 0) {
    return;
  }
  playbackRateNotifier.value = rate;
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kRateKey, rate);
  } catch (_) {
    // 落盘失败不影响本次播放。
  }
}

/// 记住用户设置的自动连播开关：更新全局状态并落盘。
Future<void> saveAutoPlay(bool autoPlay) async {
  autoPlayNotifier.value = autoPlay;
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoPlayKey, autoPlay);
  } catch (_) {
    // 落盘失败不影响本次播放。
  }
}
