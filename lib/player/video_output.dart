import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 播放流请求使用的 User-Agent（官方客户端 UA，机型与 SDK 默认注册的
/// 匿名设备小米 14 一致）。W2 Windows 实测：mpv 默认 UA（libmpv）拉
/// 视频 CDN 会被拒/掐断（播放约 3 秒即停、连接关闭；CDN 域名本身
/// 60ms 直连可达），桌面端验证同样以官方 UA
/// 「防止 CDN 拒绝」。Android 沿用同值，与注册设备口径一致。
const String kCdnUserAgent =
    'com.phoenix.newsclient/7.9.3 (Linux; Android 14; 23127PN0CC; '
    'Build/UKQ1.230917.001;)';

/// 视频渲染输出模式。
///
/// 背景：Android 模拟器上 mpv 默认的 `vo=gpu` 无法创建 OpenGL 上下文
/// （日志 `vo/gpu/opengl: Could not create a GL context`），
/// 表现为解码正常推进（position/size 都有值）但画面全黑。
/// 改用 `vo=mediacodec_embed` 让 MediaCodec 直接输出到 Surface 即可正常显示。
///
/// 桌面教训（W2 实测）：Windows 上显式设 `vo=gpu` 会让 mpv 创建**独立的
/// 原生输出窗口**，绕开 media_kit 的纹理渲染管线——视频不出现在应用内
/// Video 组件里，而是弹窗播放。桌面必须不设 vo（[texture]），
/// 让 media_kit 默认 `vo=libmpv`（render API → 纹理 → Flutter widget）。
enum VideoOutputMode {
  /// MediaCodec 直出 Surface（模拟器可用，真机同样有效）。
  embed,

  /// mpv GPU 输出（OpenGL），Android 真机的回落路径；模拟器上不可用，
  /// **桌面禁止使用**（会弹独立原生窗口，见枚举文档）。
  gpu,

  /// mpv render API 纹理输出（media_kit 默认 `vo=libmpv`），帧渲染进
  /// Flutter Video widget 内。Windows 等桌面平台的正确路径；vo/hwdec
  /// 都不显式设置，交给 media_kit 平台默认（桌面 `hwdec=auto`）。
  texture,
}

/// 当前平台默认的渲染输出模式。
///
/// - Android：[VideoOutputMode.embed]（mediacodec_embed 是模拟器
///   workaround，真机同样有效，见枚举背景说明）；
/// - 非 Android（Windows 桌面等）：[VideoOutputMode.texture]——桌面
///   `vo=gpu` 会让 mpv 弹独立原生窗口（W2 实测），`mediacodec_embed`
///   为 Android 专用，二者都禁止作为桌面默认。
///
/// widget 测试环境 `defaultTargetPlatform` 默认 android，行为与线上一致。
VideoOutputMode defaultVideoOutputMode() {
  return defaultTargetPlatform == TargetPlatform.android
      ? VideoOutputMode.embed
      : VideoOutputMode.texture;
}

/// 构造 VideoController 配置。
///
/// [mode] 的取值要点：
/// - `embed` 必须配 `hwdec: mediacodec`，否则 MediaCodec 不会接管解码；
/// - 显式传 `hwdec` 会跳过 media_kit 内部的「模拟器强制软渲染」逻辑
///   （`hwdec ?? await getDefaultHwdec()` 是惰性求值）；
/// - `texture` 的 vo/hwdec 都不显式设置——media_kit 原生侧默认
///   `vo=libmpv`（render API）+ 桌面 `hwdec=auto`，帧走纹理管线进
///   Video widget。
VideoControllerConfiguration videoOutputConfiguration(VideoOutputMode mode) {
  switch (mode) {
    case VideoOutputMode.embed:
      return const VideoControllerConfiguration(
        vo: 'mediacodec_embed',
        hwdec: 'mediacodec',
      );
    case VideoOutputMode.gpu:
      return const VideoControllerConfiguration(
        vo: 'gpu',
        hwdec: 'auto-safe',
      );
    case VideoOutputMode.texture:
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
          hwdec: 'videotoolbox',
        );
      }
      // 决断实验：enableHardwareAcceleration=false 排查 ANGLE/D3D11 路径死锁。
      return const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      );
  }
}
