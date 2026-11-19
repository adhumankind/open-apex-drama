import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state/danmaku_prefs.dart';
import '../app_state/playback_prefs.dart';
import '../app_state/sync_settings.dart';
import '../data/local/watch_store.dart';
import '../data/remote/openhongguo_service.dart';
import '../data/repository/repositories.dart';
import '../models/danmaku_cue.dart';
import '../models/drama.dart';
import '../models/playback.dart';
import '../models/series_detail.dart';
import '../player/video_output.dart';
import '../providers/data_providers.dart';
import '../providers/watch_providers.dart';
import '../theme/app_colors.dart';
import '../widgets/danmaku_layer.dart';
import '../widgets/danmaku_settings.dart';
import '../widgets/player_actions_sheet.dart';
import '../widgets/poster_artwork.dart';

Future<void> openPlayer(
  BuildContext context,
  Drama drama, {
  int episodeNumber = 1,
  bool assumePlayable = false,
}) async {
  // 预约中 / 未开播的剧集没有分集，分集接口会返回空结果，SDK 会把它当成
  // 「匿名设备受限」报错（实测多季剧的新一季显示"全0集"）。在这里直接拦住。
  // 看剧流已经实际播放过第一集，可使用 assumePlayable 跳过该兜底。
  if (!assumePlayable && drama.episodes <= 0) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('该剧暂未开播，敬请期待')));
    return;
  }
  await Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) {
            return PlayerScreen(drama: drama, episodeNumber: episodeNumber);
          },
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) {
            return FadeTransition(opacity: animation, child: child);
          },
    ),
  );
}

/// 沉浸式播放页：解析真实播放地址（含加密密钥）后用 media_kit 播放。
///
/// 渲染输出模式按平台选择（[defaultVideoOutputMode]）：Android 用
/// [VideoOutputMode.embed]（MediaCodec 直出 Surface，mpv 的 vo=gpu 在
/// Android 模拟器上无法创建 GL 上下文）；Windows 等桌面平台用
/// [VideoOutputMode.texture]（render API 纹理渲染，vo=gpu 会弹独立
/// 原生窗口）。
///
/// 桌面键盘快捷键（CallbackShortcuts 挂在本页范围，随路由销毁失效）：
/// ↑/PgUp 上一集、↓/PgDn 下一集、空格 播放/暂停、←/→ 快退/快进、
/// M 静音切换、F 全屏切换（Windows 为窗口全屏）、Esc 全屏中退出全屏。
///
/// 支持多档清晰度切换（dispose 重建整条链路，避免 Surface 复用黑屏）
/// 与倍速调节（切集 / 切清晰度后保持）。
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.drama, this.episodeNumber = 1});

  final Drama drama;
  final int episodeNumber;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with SingleTickerProviderStateMixin {
  // media_kit 依赖原生库；纯 Dart 环境（如 widget 测试）初始化会抛错，
  // 因此构建失败时降级为「仅 UI」而不是崩溃。
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;

  /// 复用预取地址开流时的一次性错误监听：地址过期时丢弃缓存重试一次。
  StreamSubscription<String>? _cachedOpenErrorSub;

  // 当前分集解析结果（含全部清晰度档位）与正在播放的流。
  PlaybackBundle? _bundle;
  StreamInfo? _currentStream;

  /// 相邻集预解析缓存：只缓存解析结果，不建第二个 Player。
  ///
  /// Android 的 `vo=mediacodec_embed` 在真机上无法稳定共存两路视频输出，
  /// 双播放器会抢走主画面，表现为「有声音、没画面」（v1.5.0 线上问题）。
  /// 解析额度才是真正贵的一步，缓存 bundle 已足够让切集免二次解析。
  PlaybackBundle? _prefetchedBundle;
  int? _prefetchedEpisode;
  bool _prefetching = false;
  bool _prefetchQueued = false;

  /// 播放进度落盘节流间隔（毫秒）：播放中每 5 秒最多写一次。
  static const int _progressWriteIntervalMs = 5000;
  int _lastProgressWriteAt = 0;

  /// 用户最近一次选择的清晰度；切集后尽量保持同一档位。
  String _preferredDefinition = '';

  /// 用户倍速：全局值（上次选的），切集 / 切清晰度后保持，不回落 1.0。
  double _rate = playbackRateNotifier.value;

  /// 清晰度切换进行中（防重入）。
  bool _switchingQuality = false;

  late int _episode;
  int _episodeCount = 0;
  List<EpisodeInfo> _episodes = const <EpisodeInfo>[];

  /// 当前播放的那一季对应的剧；切季时整体替换（进度/收藏都按 seriesId 记账）。
  late Drama _activeDrama = widget.drama;

  /// 当前季的 seriesId：拉分集、解析播放都用它，而不是固定的 widget.drama.id。
  late String _seriesId = widget.drama.id;

  bool _autoPlay = autoPlayNotifier.value;

  /// 自然播完自动切集中的防重入（动画期间 completed 可能再次触发）。
  bool _autoAdvancing = false;
  bool _loading = true;
  bool _controlsVisible = true;
  bool _muted = false;
  bool _isFullscreen = false;
  double _volume = 1.0;
  Offset? _pointerStart;
  String? _error;

  /// 当前集的弹幕与开关。弹幕是锦上添花：拉取失败就当没有，不影响播放。
  List<DanmakuCue> _danmakuCues = const <DanmakuCue>[];
  String _danmakuEpisodeId = '';
  bool _danmakuOn = danmakuEnabledNotifier.value;

  /// 弹幕层用的播放位置（随 position 流更新，层内部再做补间）。
  final ValueNotifier<Duration> _danmakuClock =
      ValueNotifier<Duration>(Duration.zero);

  /// 弹幕层用的播放状态：暂停时弹幕停住，避免脱离进度条继续滚动。
  final ValueNotifier<bool> _danmakuPlaying = ValueNotifier<bool>(false);

  /// 当前视频显示尺寸：把弹幕限制在画面内，竖屏手机不落到黑边/状态栏。
  int _videoWidth = 0;
  int _videoHeight = 0;
  StreamSubscription<VideoParams>? _videoParamsSub;

  /// 启动序号：每次 [_boot] 自增，异步返回后比对。重试连点 / 切集途中
  /// 会同时存在多次启动，只有最后一次的结果允许改写界面状态，否则先失败的
  /// 旧启动会把已经开播的画面覆盖成错误态（表现为有声音、没画面、还挂着报错）。
  int _bootToken = 0;

  /// 长按画面：临时切到 [_holdRate] 倍速，松手恢复用户原倍速。
  /// 快进/快退由左右滑动与键盘 ←/→ 承担，长按不再做 10 秒步进。
  bool _holdSpeedActive = false;
  static const double _holdRate = 2.0;

  /// 桌面 ←/→ 单次快进/快退的步长。
  static const Duration _keyboardSeekStep = Duration(seconds: 5);

  /// 左右滑调进度：拖动中持续更新目标位置（整屏宽 = 整集时长），
  /// 松手提交 seek。
  bool _scrubbing = false;
  Duration _scrubTarget = Duration.zero;

  /// 上下滑切集：跟手位移与动画控制器。
  /// [_swipeDirection] 1 = 下一集（从底部进入），-1 = 上一集（从顶部进入）。
  double _swipeDy = 0;
  int _swipeDirection = 0;
  int _swipeToken = 0;
  late final AnimationController _swipeController;
  Animation<double>? _swipeAnimation;

  /// 空格播放/暂停的硬件级兜底：控件点击后焦点会落到按钮上，
  /// CallbackShortcuts 随之失效（空格变成「按下聚焦的按钮」）；
  /// HardwareKeyboard 处理器优先于焦点链，保证任意焦点下空格
  /// 都切播放。仅在播放页路由处于栈顶时接管。
  ModalRoute<Object?>? _route;
  bool _handleKeyEvent(KeyEvent event) {
    // 只响应按下；KeyUp 不处理——否则按下切一次、松开又切一次，
    // 表现为「短暂切状态然后切回来」。
    if (event is! KeyDownEvent) {
      return false;
    }
    if (event.logicalKey != LogicalKeyboardKey.space) {
      return false;
    }
    final ModalRoute<Object?>? route = _route;
    if (route == null || !route.isCurrent) {
      return false;
    }
    _togglePlay();
    return true;
  }

  /// 鼠标滚轮切集：累计滚动量过阈值触发，带冷却防一格滚多切。
  double _wheelAccum = 0;
  DateTime _lastWheelAt = DateTime.fromMillisecondsSinceEpoch(0);
  void _handleWheelSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final DateTime now = DateTime.now();
    _wheelAccum += event.scrollDelta.dy;
    if (_wheelAccum.abs() < 90 ||
        now.difference(_lastWheelAt) < const Duration(milliseconds: 350)) {
      return;
    }
    final int direction = _wheelAccum > 0 ? 1 : -1;
    _wheelAccum = 0;
    _lastWheelAt = now;
    if (direction > 0) {
      _playNext();
    } else {
      _playPrevious();
    }
  }

  /// 控制层自动隐藏延时：桌面鼠标静置 3 秒；移动端全屏 2 秒。
  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  static const Duration _mobileControlsAutoHideDelay = Duration(seconds: 2);
  Timer? _controlsHideTimer;
  bool _playing = false;

  /// 当前是否横屏全屏布局（全屏请求或物理旋转任一成立）。
  bool get _isWideLayout =>
      _isFullscreen ||
      MediaQuery.orientationOf(context) == Orientation.landscape;

  /// 是否走移动端竖屏播放布局。
  ///
  /// 用 [defaultTargetPlatform] 而不是 [Platform.isWindows]：运行时桌面仍然
  /// 走原布局，widget 测试则能直接覆盖移动分支。macOS/Linux 桌面不在
  /// 发版范围，按桌面处理。
  bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  void _onMouseHover(PointerEvent event) {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleControlsHide();
  }

  /// 安排控制层自动隐藏。
  ///
  /// 移动端只在全屏播放时隐藏（竖屏播放页保留常显的操作与下一集面板）；
  /// 桌面沿用鼠标静置隐藏。
  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    final bool mobile = _isMobilePlatform;
    if (mobile && !_isWideLayout) {
      return;
    }
    final Duration delay = mobile
        ? _mobileControlsAutoHideDelay
        : _controlsAutoHideDelay;
    _controlsHideTimer = Timer(delay, () {
      // 暂停中不自动隐藏；正在拖动进度也不隐藏。
      if (mounted && _playing && !_scrubbing && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// 桌面单击画面：切换播放状态。控制层隐藏时先唤出，再切播放
  /// （与主流桌面播放器一致：单击永远切播放，控制层靠移动鼠标）。
  void _onDesktopTap() {
    _togglePlay();
  }

  /// 移动端单击画面：控制层隐藏时先唤出（2 秒后再次自动隐藏），
  /// 已显示时切播放/暂停，与主流短剧一致。
  void _onMobileTap() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      _scheduleControlsHide();
      return;
    }
    _togglePlay();
  }

  /// 播放状态流回调：维护 [_playing] 并驱动控制层自动隐藏。
  void _onPlayingChanged(bool playing) {
    _playing = playing;
    if (playing) {
      _scheduleControlsHide();
    } else {
      // 暂停时常显，方便操作面板。
      _controlsHideTimer?.cancel();
      if (mounted && !_controlsVisible) {
        setState(() => _controlsVisible = true);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _swipeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(_onSwipeTick);
    _episode = widget.episodeNumber;
    _episodeCount = _activeDrama.episodes;
    try {
      _buildPlayer();
      _boot();
    } catch (error) {
      _loading = false;
      _error = '播放器初始化失败';
    }
  }

  /// 创建 Player / VideoController 并挂好事件监听。
  ///
  /// 首次进入与「切清晰度销毁重建」共用：mediacodec_embed 下在旧
  /// Player 上直接 open 新流，Surface 复用可能导致 MediaCodec 初始化
  /// 失败黑屏，因此切档走 dispose → 重建 → 重新 open 的完整链路。
  void _buildPlayer() {
    final Player player = Player();
    _player = player;
    _controller = VideoController(
      player,
      configuration: videoOutputConfiguration(defaultVideoOutputMode()),
    );
    _completedSub = player.stream.completed.listen((bool done) {
      // 开流中 / 切档中不重复响应，避免 completed 连发时连跳两集。
      if (done && _autoPlay && mounted && !_loading && !_switchingQuality) {
        _onEpisodeCompleted();
      }
    });
    _observeProgress(player);
    // 音轨诊断：mpv 的音频输出/解码报错只会出现在日志里，静默失败时
    // 表现为「有画面没声音」，因此在 debug 下转发出来便于排查。
    player.stream.log.listen((PlayerLog event) {
      if (event.level.contains('error')) {
        debugPrint('[player-audio][${event.level}] ${event.text}');
      }
    });
  }

  @override
  void dispose() {
    // 全屏态退出时最先恢复窗口/系统形态——必须放在最前且独立保护，
    // 后续进度落盘/播放器销毁若抛错，不能跳过恢复（否则退出播放页后
    // 桌面残留全屏窗口、移动端残留横屏）。
    if (_isFullscreen) {
      _isFullscreen = false;
      if (Platform.isWindows) {
        // 窗口全屏态退出时恢复窗口样式；dispose 不能 await，fire-and-forget。
        windowManager.setFullScreen(false);
      } else {
        SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.portraitUp,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
    // 退出前的最后一次进度落盘（fire-and-forget，不阻塞销毁）。
    try {
      _persistProgress(force: true);
    } catch (_) {}
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _controlsHideTimer?.cancel();
    _swipeController.dispose();
    _clearPrefetch();
    _completedSub?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _cachedOpenErrorSub?.cancel();
    _videoParamsSub?.cancel();
    _danmakuPlaying.dispose();
    _danmakuClock.dispose();
    // 先同步发出停止命令（立即静音），再销毁；media_kit 的 dispose 是
    // 异步释放 native 资源，直接 dispose 偶尔会残留音频线程出声。
    try {
      _player?.stop();
    } catch (_) {}
    _player?.dispose();
    super.dispose();
  }

  /// 监听 position 流做节流写入（每 5 秒一次），并捕获暂停节点。
  ///
  /// 切清晰度销毁重建 Player 时由 [_buildPlayer] 重新挂载，旧订阅先取消。
  void _observeProgress(Player player) {
    _positionSub?.cancel();
    _playingSub?.cancel();
    _positionSub = player.stream.position.listen((Duration position) {
      _danmakuClock.value = position;
      _persistProgress();
    });
    // 弹幕层与播放状态同步：暂停即冻结，恢复后按真实进度继续。
    _danmakuPlaying.value = player.state.playing;
    _playingSub = player.stream.playing.listen((bool playing) {
      _danmakuPlaying.value = playing;
      // 暂停（含播完自动暂停）立即落盘当前进度。
      if (!playing) {
        _persistProgress(force: true);
      }
      _onPlayingChanged(playing);
    });
    // 视频尺寸：弹幕层据此收进画面区域（手机竖屏上下黑边不放弹幕）。
    _videoParamsSub?.cancel();
    _videoSizeFromParams(player.state.videoParams, notify: false);
    _videoParamsSub = player.stream.videoParams.listen(_videoSizeFromParams);
  }

  /// 更新视频显示尺寸：优先用 display 宽高（已含旋转），否则用原始宽高
  /// 并按旋转角度交换，避免竖拍视频被当成横屏而算错弹幕区域。
  void _videoSizeFromParams(VideoParams params, {bool notify = true}) {
    int width = params.dw ?? 0;
    int height = params.dh ?? 0;
    if (width <= 0 || height <= 0) {
      width = params.w ?? 0;
      height = params.h ?? 0;
      if ((params.rotate ?? 0) % 180 != 0) {
        final int swap = width;
        width = height;
        height = swap;
      }
    }
    if (!mounted || width <= 0 || height <= 0) {
      return;
    }
    if (width == _videoWidth && height == _videoHeight) {
      return;
    }
    if (notify) {
      setState(() {
        _videoWidth = width;
        _videoHeight = height;
      });
    } else {
      _videoWidth = width;
      _videoHeight = height;
    }
  }

  /// 写入观看进度：seriesId / 集号 / 集标题 / 已播秒数 / 总秒数。
  ///
  /// [force] 为 true 时跳过节流（暂停 / 切集 / 切清晰度 / 退出等关键
  /// 节点）；尚未解析出有效时长且未开播时不写，避免覆盖已有进度。
  void _persistProgress({bool force = false}) {
    final Player? player = _player;
    if (player == null) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastProgressWriteAt < _progressWriteIntervalMs) {
      return;
    }
    final int positionSeconds = player.state.position.inSeconds;
    final int durationSeconds = player.state.duration.inSeconds;
    if (positionSeconds <= 0 && durationSeconds <= 0) {
      return;
    }
    _lastProgressWriteAt = now;
    ref
        .read(historyProvider.notifier)
        .upsertWatchProgress(
          snapshotFromDrama(
            _activeDrama,
            episodeNumber: _episode,
            episodeTitle: _titleForEpisode(_episode),
            progressSeconds: positionSeconds,
            durationSeconds: durationSeconds,
          ),
        );
  }

  /// 拉取分集 → resolve → 设密钥 → open 的完整启动链路。
  ///
  /// [stream] 指定要播放的清晰度档位（切清晰度时传入）；
  /// [resumeFrom] 打开后回跳的进度（切清晰度时保持原位置）；
  /// [playWhenReady] 为 false 时打开后保持暂停；
  /// [isQualitySwitch] 标记本次启动来自切档，失败时走专属兜底。
  Future<void> _boot({
    StreamInfo? stream,
    Duration resumeFrom = Duration.zero,
    bool playWhenReady = true,
    bool isQualitySwitch = false,
  }) async {
    final Player? player = _player;
    if (player == null) {
      return;
    }
    final int token = ++_bootToken;
    _cachedOpenErrorSub?.cancel();
    _cachedOpenErrorSub = null;
    // 本次是否复用了相邻集预解析结果（失败时丢弃缓存重试一次）。
    bool usedCachedBundle = false;
    bool superseded() => !mounted || token != _bootToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PlaybackRepository repo = ref.read(playbackRepositoryProvider);
      final List<EpisodeInfo> episodes = await repo.episodes(_seriesId);
      if (superseded()) {
        return; // 已有更新的启动在跑，旧结果丢弃。
      }
      _episodes = episodes;
      if (episodes.isNotEmpty) {
        _episodeCount = episodes.length;
      }
      EpisodeInfo? episode;
      for (final EpisodeInfo item in episodes) {
        if (item.number == _episode) {
          episode = item;
          break;
        }
      }
      episode ??= episodes.isNotEmpty ? episodes.first : null;
      if (episode == null) {
        throw StateError('没有可用分集');
      }
      _episode = episode.number;

      // 优先复用相邻集预解析结果：解析额度是限量的，切集不再重复请求。
      PlaybackBundle? cached;
      if (stream == null && _prefetchedEpisode == episode.number) {
        cached = _prefetchedBundle;
        _clearPrefetch();
      }
      usedCachedBundle = cached != null;
      final PlaybackBundle bundle = cached ?? await repo.resolve(episode.id);
      if (superseded()) {
        return; // 页面已退出或已被更新的启动取代：不再 open，避免覆盖现场。
      }
      _bundle = bundle;
      final StreamInfo chosen = _pickStream(bundle, stream);
      if (chosen.url.isEmpty) {
        throw StateError('没有可用播放地址');
      }

      // Surface 就绪后再 open，否则 MediaCodec 会因 surface 为空初始化失败。
      if (mounted) {
        setState(() {});
      }
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (superseded()) {
        return; // 等待期间退出或已被取代：保持销毁状态，不再 open。
      }

      // 缓存地址有时效：开流失败（典型是 CDN 403）时丢弃缓存重试一次。
      // 只在复用预取结果时挂一次，正常解析不监听。
      if (usedCachedBundle) {
        StreamSubscription<String>? sub;
        sub = player.stream.error.listen((String message) {
          debugPrint('[player] 缓存地址开流失败: $message');
          unawaited(sub?.cancel());
          if (identical(_cachedOpenErrorSub, sub)) {
            _cachedOpenErrorSub = null;
          }
          if (mounted && token == _bootToken) {
            unawaited(
              _boot(
                stream: stream,
                resumeFrom: resumeFrom,
                playWhenReady: playWhenReady,
              ),
            );
          }
        });
        _cachedOpenErrorSub = sub;
      }

      // 加密流：内容密钥交给 ffmpeg 解复用层（解密后编码器收到明文）。
      // 每次重建 / 切流后都必须重设，否则黑屏或无声。
      if (bundle.hasKey) {
        await (player.platform as dynamic).setProperty(
          'demuxer-lavf-o',
          'decryption_key=${bundle.contentKeyHex}',
        );
      }
      // 官方 UA：mpv 默认 UA 拉视频 CDN 会被拒（W2 Windows 实测 + POC
      // 结论），open 前设置（媒体网络层每次 open 重置）。
      await (player.platform as dynamic).setProperty(
        'user-agent',
        kCdnUserAgent,
      );
      await player.open(Media(chosen.url));

      // 确保声音开启（部分设备/模拟器默认音量或静音状态会继承系统设置）。
      await player.setVolume(_muted ? 0 : _volume * 100);
      // 保持用户设置的倍速（切集 / 切清晰度不回落 1.0）。
      await player.setRate(_rate);
      if (!playWhenReady) {
        await player.pause();
      }
      if (resumeFrom > Duration.zero) {
        // 新流时长未知时直接 seek；已知且短于原进度则钳到结尾。
        final Duration total = player.state.duration;
        final Duration target = total > Duration.zero && resumeFrom > total
            ? total
            : resumeFrom;
        if (target > Duration.zero) {
          await player.seek(target);
        }
      }
      _currentStream = chosen;
      _preferredDefinition = chosen.definition;
      unawaited(_loadDanmaku(episode.id));

      if (mounted) {
        setState(() => _loading = false);
        // 当前集开播后再预解析下一集，避免未观看也消耗解析额度。
        unawaited(_prefetchNext());
      }
    } on ApiException catch (error) {
      debugPrint('[player] 解析失败 ${error.code}: ${error.message}');
      if (superseded()) {
        return; // 旧启动的失败不能覆盖新启动的结果。
      }
      if (usedCachedBundle && !isQualitySwitch) {
        // 预取地址有时效，暂停久了可能已过期：丢弃缓存按正常链路重试一次。
        unawaited(
          _boot(
            stream: stream,
            resumeFrom: resumeFrom,
            playWhenReady: playWhenReady,
          ),
        );
        return;
      }
      if (isQualitySwitch) {
        await _handleSwitchFailure(stream, resumeFrom);
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = error.userMessage;
        });
      }
    } catch (error) {
      if (superseded()) {
        return;
      }
      if (usedCachedBundle && !isQualitySwitch) {
        unawaited(
          _boot(
            stream: stream,
            resumeFrom: resumeFrom,
            playWhenReady: playWhenReady,
          ),
        );
        return;
      }
      if (isQualitySwitch) {
        await _handleSwitchFailure(stream, resumeFrom);
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = '播放失败，请重试';
        });
      }
    }
  }

  /// 从 bundle 里挑出要播放的流：优先显式指定的档位，其次用户最近
  /// 选择的清晰度，最后按 [PlaybackBundle.preferred]（未加密 + 最高分辨率）。
  StreamInfo _pickStream(PlaybackBundle bundle, StreamInfo? requested) {
    if (requested != null) {
      for (final StreamInfo item in bundle.streams) {
        if (item.definition == requested.definition && item.url.isNotEmpty) {
          return item;
        }
      }
    }
    if (_preferredDefinition.isNotEmpty) {
      for (final StreamInfo item in bundle.streams) {
        if (item.definition == _preferredDefinition && item.url.isNotEmpty) {
          return item;
        }
      }
    }
    return bundle.preferred ??
        const StreamInfo(definition: '未知', url: '', backupUrl: '');
  }

  /// 清晰度切换：mediacodec_embed 下在旧 Player 上复用 Surface 直接
  /// open 新流可能黑屏，因此走 dispose → 重建 Player → [._boot] 重开
  /// → seek 回原位置的整条链路，Surface 等待时序与首次进场完全一致。
  Future<void> _switchQuality(StreamInfo target) async {
    if (_switchingQuality || _loading) {
      return;
    }
    final Player? player = _player;
    if (player == null) {
      return;
    }
    final Duration resume = player.state.position;
    final bool wasPlaying = player.state.playing;
    // 换流前落盘当前进度；重建后节流写入会在新流上继续。
    _persistProgress(force: true);
    _switchingQuality = true;
    try {
      await _completedSub?.cancel();
      _completedSub = null;
      try {
        await player.dispose();
      } catch (_) {
        // 旧 Player 销毁失败不阻塞重建，继续尝试换新实例。
      }
      _player = null;
      _controller = null;
      if (mounted) {
        setState(() {});
      }
      try {
        _buildPlayer();
      } catch (_) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '播放器初始化失败';
          });
        }
        return;
      }
      await _boot(
        stream: target,
        resumeFrom: resume,
        playWhenReady: wasPlaying,
        isQualitySwitch: true,
      );
    } finally {
      _switchingQuality = false;
    }
  }

  /// 切档失败兜底：流 URL 带 expiresAt，过期是失败主因。
  /// 作废解析缓存（下次 resolve 强制重新拉取），提示后用新地址重试一次；
  /// 重试再失败则落到通用错误态，不无限递归。
  Future<void> _handleSwitchFailure(
    StreamInfo? target,
    Duration resumeFrom,
  ) async {
    ref.invalidate(playbackRepositoryProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('清晰度切换失败，请重新解析'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
    if (_player == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '播放器初始化失败';
        });
      }
      return;
    }
    await _boot(stream: target, resumeFrom: resumeFrom);
  }

  /// 本集自然播完：移动端竖屏先走与手动上滑一致的上滑动画，再切集；
  /// 其余场景（桌面 / 全屏 / 最后一集）沿用直接切集。
  void _onEpisodeCompleted() {
    if (_autoAdvancing) {
      return;
    }
    if (_episodeCount > 0 && _episode + 1 > _episodeCount) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已看完全部剧集 🎉'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    if (!_isMobilePlatform || _isWideLayout) {
      _playNext();
      return;
    }
    _autoAdvancing = true;
    setState(() => _swipeDirection = 1);
    unawaited(
      _commitSwipe(1).whenComplete(() => _autoAdvancing = false),
    );
  }

  void _playNext() {
    if (_switchingQuality) {
      return;
    }
    final int next = _episode + 1;
    if (_episodeCount > 0 && next > _episodeCount) {
      return;
    }
    // 切集前把当前集的最终进度落盘（播完时 progress==duration，
    // 该集会自然移出「继续观看」但保留在历史里）。
    _persistProgress(force: true);
    setState(() => _episode = next);
    _boot();
  }

  void _playPrevious() {
    if (_switchingQuality) {
      return;
    }
    final int previous = _episode - 1;
    if (previous < 1) {
      return;
    }
    _persistProgress(force: true);
    setState(() => _episode = previous);
    _boot();
  }

  /// 全屏切换：桌面（Windows）用窗口全屏（setFullScreen，不转方向、
  /// 不动系统栏）；移动端维持原「强制横屏 + 沉浸式系统栏」。
  Future<void> _toggleFullscreen() async {
    setState(() => _isFullscreen = !_isFullscreen);
    if (Platform.isWindows) {
      try {
        await windowManager.setFullScreen(_isFullscreen);
      } catch (error) {
        debugPrint('windowManager fullscreen error: $error');
      }
      return;
    }
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // 进入全屏即开始计时，播放中 2 秒后收起控制层。
      _scheduleControlsHide();
    } else {
      // 退出全屏回到竖屏：取消计时并保证控制层可见。
      _controlsHideTimer?.cancel();
      if (mounted && !_controlsVisible) {
        setState(() => _controlsVisible = true);
      }
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // 等方向恢复后再预取，避免仍处于横屏时被 gate 掉。
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          unawaited(_prefetchNext());
        }
      });
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _player?.setVolume(_muted ? 0 : _volume * 100);
  }

  void _setVolume(double value) {
    setState(() {
      _volume = value;
      _muted = value <= 0.01;
    });
    _player?.setVolume(_volume * 100);
  }

  /// 播放页底部弹层统一容器（选集 / 清晰度 / 倍速共用同款样式）。
  Future<T?> _showPlayerSheet<T>({required WidgetBuilder builder}) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppTokens.immersiveSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: builder,
    );
  }

  /// 移动端播放设置：右栏「设置」和长按中间共用同一入口。
  void _showPlayerActions() {
    showPlayerActionsSheet(
      context,
      autoPlay: _autoPlay,
      onAutoPlayChanged: (bool value) {
        setState(() => _autoPlay = value);
        saveAutoPlay(value);
      },
      volume: _muted ? 0 : _volume,
      muted: _muted,
      onVolumeChanged: (double value) {
        setState(() {
          _volume = value;
          _muted = value <= 0.01;
        });
        _player?.setVolume(_volume * 100);
      },
      qualityLabel: _currentStream?.definition ?? '',
      onQuality: _showQualitySheet,
      onDanmakuSettings: () => showDanmakuSettings(context),
    );
  }

  Future<void> _showEpisodes() async {
    final List<SeasonInfo> seasons = await _loadSeasons();
    if (!mounted) {
      return;
    }
    final _EpisodePick? picked = await _showPlayerSheet<_EpisodePick>(
      builder: (BuildContext context) => _EpisodeSheet(
        episodes: _episodes,
        current: _episode,
        seasons: seasons,
        currentSeriesId: _seriesId,
        // 点其他季时按需拉该季分集，面板内先切列表、等用户选集。
        loadEpisodes: (String seriesId) =>
            ref.read(playbackRepositoryProvider).episodes(seriesId),
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    if (picked.seriesId != _seriesId) {
      // 换季 + 换集一起生效：找到对应季信息后整条重开。
      for (final SeasonInfo season in seasons) {
        if (season.seriesId == picked.seriesId) {
          _switchSeason(season, episode: picked.number);
          break;
        }
      }
      return;
    }
    if (picked.number != _episode) {
      if (_switchingQuality) {
        return;
      }
      _persistProgress(force: true);
      setState(() => _episode = picked.number);
      _boot();
    }
  }

  /// 取多季列表；播放页可能是从追剧/历史直接进来的，缓存未命中时补拉一次。
  Future<List<SeasonInfo>> _loadSeasons() async {
    final SeriesDetailData? cached =
        ref.read(seriesDetailProvider(widget.drama.id)).value;
    if (cached != null) {
      return cached.isMultiSeason ? cached.seasons : const <SeasonInfo>[];
    }
    try {
      final SeriesDetailData detail =
          await ref.read(seriesDetailProvider(widget.drama.id).future);
      return detail.isMultiSeason ? detail.seasons : const <SeasonInfo>[];
    } catch (_) {
      return const <SeasonInfo>[];
    }
  }

  /// 拉取这一集的弹幕；失败或切集后返回的旧结果直接丢弃。
  Future<void> _loadDanmaku(String episodeId) async {
    final String seriesId = _seriesId;
    _danmakuEpisodeId = episodeId;
    if (mounted) {
      setState(() => _danmakuCues = const <DanmakuCue>[]);
    }
    final List<DanmakuCue> cues =
        await ref.read(playbackRepositoryProvider).danmaku(seriesId, episodeId);
    if (!mounted || _danmakuEpisodeId != episodeId) {
      return;
    }
    setState(() => _danmakuCues = cues);
  }

  /// 弹幕开关：全局记忆，与倍速一样跨剧、跨会话保持。
  void _toggleDanmaku() {
    setState(() => _danmakuOn = !_danmakuOn);
    unawaited(saveDanmakuEnabled(_danmakuOn));
  }

  /// 切季：进度按季独立记账，所以先落盘当前季，再整体替换为新季并开播
  /// [episode]（选集面板里选的那一集，默认第 1 集）。
  void _switchSeason(SeasonInfo season, {int episode = 1}) {
    if (season.seriesId == _seriesId || _switchingQuality) {
      return;
    }
    if (season.episodeCount <= 0) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('该季暂未开播，敬请期待')),
        );
      return;
    }
    _persistProgress(force: true);
    setState(() {
      _activeDrama = dramaForSeason(widget.drama, season);
      _seriesId = season.seriesId;
      _episode = episode;
      _episodeCount = season.episodeCount;
      _episodes = const <EpisodeInfo>[];
    });
    _boot();
  }

  Future<void> _showQualitySheet() async {
    if (_switchingQuality) {
      return;
    }
    final StreamInfo? picked = await _showPlayerSheet<StreamInfo>(
      builder: (BuildContext context) => _QualitySheet(
        streams: _bundle?.streams ?? const <StreamInfo>[],
        currentDefinition: _currentStream?.definition ?? '',
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    // 同档不切换。
    if (picked.definition == _currentStream?.definition) {
      return;
    }
    await _switchQuality(picked);
  }

  Future<void> _showSpeedSheet() async {
    final double? picked = await _showPlayerSheet<double>(
      builder: (BuildContext context) => _SpeedSheet(current: _rate),
    );
    if (picked == null || picked == _rate) {
      return;
    }
    _applyRate(picked);
  }

  /// 倍速即时生效并记住：状态记在 [_rate]，切集 / 切清晰度后由 _boot 保持，
  /// 同时写入本地偏好，下次进任何一部剧都沿用这个值。
  void _applyRate(double rate) {
    setState(() => _rate = rate);
    _player?.setRate(rate);
    unawaited(rememberPlaybackRate(rate));
  }

  /// 倍速在右侧按钮上的短标签：1.0 显示「倍速」，其余显示如「1.5x」。
  String get _speedLabel => _rate == 1.0 ? '倍速' : '${_compactRate(_rate)}x';

  static String _compactRate(double rate) {
    if (rate == rate.roundToDouble()) {
      return rate.toStringAsFixed(0);
    }
    return '$rate';
  }

  void _togglePlay() {
    _player?.playOrPause();
  }

  /// 桌面键盘快捷键表（↔ 移动端手势的键鼠映射，见类文档）。
  ///
  /// 空格不在表内：由 HardwareKeyboard 处理器兜底（控件点击夺走焦点
  /// 后 CallbackShortcuts 会失效，见 [_handleKeyEvent]）。
  ///
  /// 复用现有手势/按钮的同一批 handler；[Focus] 的 autofocus 只是普通
  /// 焦点节点（非文本输入），不弹软键盘也不抢别处输入框焦点——本页
  /// 范围内没有文本输入，弹层（选集/清晰度/倍速）是独立路由，打开时
  /// 焦点随之切走、快捷键自然暂停生效，关闭后回到本页继续。
  Map<ShortcutActivator, VoidCallback> get _shortcutBindings {
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.arrowUp): _playPrevious,
      const SingleActivator(LogicalKeyboardKey.pageUp): _playPrevious,
      const SingleActivator(LogicalKeyboardKey.arrowDown): _playNext,
      const SingleActivator(LogicalKeyboardKey.pageDown): _playNext,
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _seekBy(-_keyboardSeekStep),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _seekBy(_keyboardSeekStep),
      const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
      const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
      // Esc：全屏中退出全屏（桌面惯例）；非全屏时不抢按键。
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_isFullscreen) {
          _toggleFullscreen();
        }
      },
    };
  }

  void _seekToFraction(double fraction) {
    final Player? player = _player;
    if (player == null) {
      return;
    }
    final Duration total = player.state.duration;
    if (total == Duration.zero) {
      return;
    }
    player.seek(total * fraction.clamp(0.0, 1.0));
  }

  /// 长按开始：临时切到 [_holdRate] 倍速，松手恢复用户原倍速。
  /// 左右两侧行为一致（快进/快退交给左右滑动）。
  void _startHoldSpeed() {
    final Player? player = _player;
    if (player == null || _holdSpeedActive) {
      return;
    }
    _holdSpeedActive = true;
    player.setRate(_holdRate);
    if (mounted) {
      setState(() {});
    }
  }

  void _stopHoldSpeed() {
    if (!_holdSpeedActive) {
      return;
    }
    _holdSpeedActive = false;
    _player?.setRate(_rate);
    if (mounted) {
      setState(() {});
    }
  }

  void _onSwipeTick() {
    final Animation<double>? animation = _swipeAnimation;
    if (animation == null || !mounted) {
      return;
    }
    setState(() => _swipeDy = animation.value);
  }

  Future<void> _animateSwipe(
    double target, {
    Duration duration = const Duration(milliseconds: 240),
  }) {
    final Completer<void> done = Completer<void>();
    _swipeController.stop();
    _swipeAnimation = Tween<double>(begin: _swipeDy, end: target).animate(
      CurvedAnimation(parent: _swipeController, curve: Curves.easeOutCubic),
    );
    _swipeController.duration = duration;
    // stop() 会取消 ticker；用 whenCompleteOrCancel 保证 Future 一定落地，
    // 否则快速二次滑动会让上一次 _commitSwipe 永久挂起。
    final TickerFuture ticker = _swipeController.forward(from: 0);
    ticker.whenCompleteOrCancel(() {
      _swipeAnimation = null;
      if (!done.isCompleted) {
        done.complete();
      }
    });
    return done.future;
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (!_isMobilePlatform || _isWideLayout) {
      return;
    }
    // 作废上一次未完成的提交/回弹，避免旧动画在松手后继续改集号。
    _swipeToken++;
    _swipeController.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_isMobilePlatform || _isWideLayout) {
      return;
    }
    final double height = MediaQuery.sizeOf(context).height;
    final double next = (_swipeDy + details.delta.dy).clamp(-height, height);
    if (next == _swipeDy) {
      return;
    }
    setState(() {
      _swipeDy = next;
      _swipeDirection = next < 0
          ? 1
          : next > 0
          ? -1
          : 0;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_isMobilePlatform || _isWideLayout) {
      return;
    }
    final double height = MediaQuery.sizeOf(context).height;
    final int direction = swipeCommitDirection(
      dy: _swipeDy,
      velocity: details.velocity.pixelsPerSecond.dy,
      height: height,
    );
    if (direction == 0) {
      final int token = ++_swipeToken;
      unawaited(
        _animateSwipe(0, duration: const Duration(milliseconds: 220)).then((_) {
          if (mounted && token == _swipeToken) {
            setState(() => _swipeDirection = 0);
          }
        }),
      );
      return;
    }
    unawaited(_commitSwipe(direction));
  }

  Future<void> _commitSwipe(int direction) async {
    final int token = ++_swipeToken;
    final double height = MediaQuery.sizeOf(context).height;
    await _animateSwipe(-direction * height);
    if (!mounted || token != _swipeToken) {
      return;
    }
    if (direction > 0) {
      _playNext();
      setState(() {
        _swipeDy = 0;
        _swipeDirection = 0;
      });
      return;
    }
    _playPrevious();
    setState(() {
      _swipeDy = 0;
      _swipeDirection = 0;
    });
  }

  EpisodeInfo? _episodeByNumber(int number) {
    for (final EpisodeInfo item in _episodes) {
      if (item.number == number) {
        return item;
      }
    }
    return null;
  }

  /// 当前集画面 + 弹幕。
  ///
  /// 独立成方法：静止时不要包 Transform——Android mediacodec_embed 的
  /// Video 是原生 PlatformView，放进 Transform 层会导致整块黑屏。
  Widget _buildCurrentVideoLayer(Drama drama) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (_controller == null ||
            (_currentStream == null && (_loading || _error != null)))
          PosterArtwork(drama: drama, variant: PosterVariant.full)
        else
          IgnorePointer(
            child: Center(
              child: Video(
                controller: _controller!,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              ),
            ),
          ),
        // 弹幕层压在画面上、控制层之下；关掉时不构建。
        // 只画在视频画面内：手机竖屏上下黑边、状态栏都不放弹幕。
        if (_danmakuOn && _danmakuCues.isNotEmpty)
          Positioned.fromRect(
            rect: danmakuVideoRect(
              area: MediaQuery.sizeOf(context),
              videoWidth: _videoWidth,
              videoHeight: _videoHeight,
            ),
            child: ValueListenableBuilder<DanmakuSettings>(
              valueListenable: danmakuSettingsNotifier,
              builder:
                  (
                    BuildContext context,
                    DanmakuSettings settings,
                    _,
                  ) {
                    return DanmakuLayer(
                      cues: _danmakuCues,
                      position: _danmakuClock,
                      playing: _danmakuPlaying,
                      travel: settings.travel,
                      fontSize: settings.fontSize,
                      area: settings.area,
                      // 长按临时倍速同样需要让弹幕跟上进度。
                      rate: _holdSpeedActive ? _holdRate : _rate,
                    );
                  },
            ),
          ),
      ],
    );
  }

  /// 预解析相邻一集：只缓存解析结果，不创建第二个播放器。
  ///
  /// Android 真机上第二路 `mediacodec_embed` 会抢占视频输出（有声无画），
  /// 而真正稀缺的是解析额度——缓存 bundle 已足够让切集免二次解析。
  Future<void> _prefetchNext() async {
    if (!_kEnablePrefetch || !_isMobilePlatform || _isWideLayout) {
      return;
    }
    final int next = nextPreloadEpisode(_episode, _episodeCount);
    if (next == 0) {
      _clearPrefetch();
      return;
    }
    if (_prefetchedEpisode == next) {
      return;
    }
    if (_prefetching) {
      // 切集很快时把请求排队，等当前预取结束后按新集重跑。
      _prefetchQueued = true;
      return;
    }
    _prefetching = true;
    try {
      final EpisodeInfo? info = _episodeByNumber(next);
      if (info == null) {
        return;
      }
      final PlaybackBundle bundle = await ref
          .read(playbackRepositoryProvider)
          .resolve(info.id);
      if (!mounted || !_isMobilePlatform || _isWideLayout) {
        return;
      }
      if (_episode != next - 1) {
        return;
      }
      _prefetchedBundle = bundle;
      _prefetchedEpisode = next;
    } catch (error) {
      // 预解析失败不打扰正片：切集时 _boot 会重新解析。
      debugPrint('[player] 预解析失败 第$next集: $error');
    } finally {
      _prefetching = false;
      if (_prefetchQueued) {
        _prefetchQueued = false;
        unawaited(_prefetchNext());
      }
    }
  }

  void _clearPrefetch() {
    _prefetchedBundle = null;
    _prefetchedEpisode = null;
  }

  /// 单步 seek（桌面 ←/→ 快捷键用）：在当前位置上叠加
  /// [delta]（正 = 快进、负 = 快退），钳制在 [0, duration]；
  /// 时长未知时忽略。
  void _seekBy(Duration delta) {
    final Player? player = _player;
    if (player == null) {
      return;
    }
    final Duration total = player.state.duration;
    if (total == Duration.zero) {
      return;
    }
    Duration target = player.state.position + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (target > total) {
      target = total;
    }
    player.seek(target);
    if (mounted) {
      setState(() {}); // 刷新中央指示器的时间。
    }
  }

  /// 左右滑调进度：整屏宽的位移 = 整集时长的比例换算，松手提交。
  void _startScrub() {
    final Player? player = _player;
    if (player == null || player.state.duration == Duration.zero) {
      return;
    }
    _scrubbing = true;
    _scrubTarget = player.state.position;
    setState(() {});
  }

  void _updateScrub(double dx, double width) {
    final Player? player = _player;
    if (player == null || width <= 0) {
      return;
    }
    final Duration total = player.state.duration;
    if (total == Duration.zero) {
      return;
    }
    Duration next = _scrubTarget + total * (dx / width);
    if (next < Duration.zero) {
      next = Duration.zero;
    }
    if (next > total) {
      next = total;
    }
    _scrubTarget = next;
    setState(() {});
  }

  void _endScrub() {
    if (!_scrubbing) {
      return;
    }
    _scrubbing = false;
    final Player? player = _player;
    if (player != null && player.state.duration > Duration.zero) {
      player.seek(_scrubTarget);
      _persistProgress(force: true);
    }
    // 拖动结束后重新计时，让控制层回到自动隐藏节奏。
    _scheduleControlsHide();
    setState(() {});
  }

  /// 收藏 / 分享操作栏（竖屏与横屏全屏共用一份）。
  /// 收藏与详情页 / 追剧页共用同一 store，状态天然联动。
  /// 手机端将高频的倍速 / 选集移到右侧，并隐藏分享。
  Widget _buildActionRail({required bool compact}) {
    return _ActionRail(
      onFavorite: _toggleFavorite,
      onShare: () {},
      favorited: ref.watch(isFavoriteProvider(_seriesId)),
      compact: compact,
      speedLabel: _speedLabel,
      onSpeed: _showSpeedSheet,
      onOpenEpisodes: _showEpisodes,
      danmakuOn: _danmakuOn,
      onToggleDanmaku: _toggleDanmaku,
      onDanmakuSettings: () => showDanmakuSettings(context),
      onMore: _showPlayerActions,
    );
  }

  /// 收藏切换：带上当前集与播放进度，收藏列表可显示「看到第 N 集」。
  Future<void> _toggleFavorite() async {
    final Player? player = _player;
    await ref
        .read(favoritesProvider.notifier)
        .toggleFavorite(
          snapshotFromDrama(
            _activeDrama,
            episodeNumber: _episode,
            episodeTitle: _titleForEpisode(_episode),
            progressSeconds: player?.state.position.inSeconds ?? 0,
            durationSeconds: player?.state.duration.inSeconds ?? 0,
          ),
        );
  }

  /// 中央指示器的文案与图标：左右滑动 = 松手跳转，长按 = 临时 2x。
  ({IconData icon, String label, String time}) _seekIndicatorData() {
    final Duration total = _player?.state.duration ?? Duration.zero;
    final Duration shown = _scrubbing
        ? _scrubTarget
        : (_player?.state.position ?? Duration.zero);
    final String time = '${_formatDuration(shown)} / ${_formatDuration(total)}';
    if (_scrubbing) {
      return (
        icon: shown >= (_player?.state.position ?? Duration.zero)
            ? Icons.fast_forward_rounded
            : Icons.fast_rewind_rounded,
        label: '松手跳转',
        time: time,
      );
    }
    return (
      icon: Icons.fast_forward_rounded,
      label: '${_compactRate(_holdRate)}x 播放中',
      time: time,
    );
  }

  /// 取某一集的标题：优先真实分集数据，回退到剧集内置的占位标题。
  String _titleForEpisode(int number) {
    for (final EpisodeInfo item in _episodes) {
      if (item.number == number) {
        return item.title;
      }
    }
    return _activeDrama.episodeTitle(number);
  }

  @override
  Widget build(BuildContext context) {
    final Drama drama = _activeDrama;
    final int nextEpisode = _episodeCount > 0 && _episode >= _episodeCount
        ? 1
        : _episode + 1;
    // 横屏布局跟随实际屏幕方向：全屏按钮（SystemChrome 请求）与物理旋转
    // （系统自动旋转）任一生效即采用横屏布局，避免部分设备方向请求被
    // 系统忽略时竖屏锚点把操作栏顶到画面上半部。
    final bool isWide =
        _isFullscreen ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // 移动端竖屏：底部只留进度 + 全屏，传输按钮交给点按/滑动。
    final bool compactControls = !isWide && _isMobilePlatform;
    final double screenHeight = MediaQuery.sizeOf(context).height;

    return CallbackShortcuts(
      bindings: _shortcutBindings,
      child: Focus(
        autofocus: true,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarColor: AppTokens.playerBackground,
            systemNavigationBarIconBrightness: Brightness.light,
          ),
          child: Scaffold(
            backgroundColor: AppTokens.playerBackground,
            // 手势方案：
            // - 点击：桌面切播放状态（控制层由鼠标移动唤出，见
            //   [_onDesktopTap]）；移动端同样切播放状态，并保持控制层可见，
            //   与主流短剧「点一下暂停/继续」一致；
            // - 上下滑切集用底层 Listener 直接比对指针位移，绕开手势竞技场，
            //   避免被子级滚动/滑块等识别器抢走；
            // - 长按左/右半屏持续快退/快进，左右滑拖动进度（竞技场里按住不动
            //   → 长press 胜出，先滑动 → drag 胜出，与上/下滑切集天然互斥）。
            body: MouseRegion(
              onHover: _onMouseHover,
              cursor: Platform.isWindows
                  ? SystemMouseCursors.basic
                  : MouseCursor.defer,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _isMobilePlatform ? _onMobileTap : _onDesktopTap,
                // 长按画面：仅移动端临时 2x，松手恢复原倍速。
                // 桌面端不挂长按，保持原有鼠标/空格交互不变。
                // 移动端竖屏：长按中间 1/3 弹播放设置，左右两侧仍是临时 2x。
                // 全屏保持原行为（任意位置长按 2x）；桌面不挂长按。
                onLongPressStart: _isMobilePlatform
                    ? (LongPressStartDetails details) {
                        final double width =
                            MediaQuery.sizeOf(context).width;
                        if (!isWide &&
                            isPlayerSheetZone(
                              details.localPosition.dx,
                              width,
                            )) {
                          _showPlayerActions();
                        } else {
                          _startHoldSpeed();
                        }
                      }
                    : null,
                onLongPressEnd: _isMobilePlatform
                    ? (_) => _stopHoldSpeed()
                    : null,
                onLongPressCancel: _isMobilePlatform ? _stopHoldSpeed : null,
                onHorizontalDragStart: (_) => _startScrub(),
                onHorizontalDragUpdate: (DragUpdateDetails details) {
                  final Size size = MediaQuery.sizeOf(context);
                  _updateScrub(details.delta.dx, size.width);
                },
                onHorizontalDragEnd: (_) => _endScrub(),
                onHorizontalDragCancel: _endScrub,
                // 移动端竖屏：上下滑跟手切集；全屏/桌面仍走原有手势。
                // 不在这些平台注册竖向识别器，避免抢走长按 2x。
                onVerticalDragStart: compactControls
                    ? _onVerticalDragStart
                    : null,
                onVerticalDragUpdate: compactControls
                    ? _onVerticalDragUpdate
                    : null,
                onVerticalDragEnd: compactControls ? _onVerticalDragEnd : null,
                onVerticalDragCancel: !compactControls
                    ? null
                    : () {
                        _swipeToken++;
                        unawaited(_animateSwipe(0));
                      },
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  // 桌面滚轮上下切集（与触摸上/下滑同语义：下滚 = 下一集）。
                  onPointerSignal: _handleWheelSignal,
                  onPointerDown: (PointerDownEvent event) {
                    _pointerStart = event.position;
                    // 任意点击（含控制栏按钮）都刷新自动隐藏计时，
                    // 避免操作后控制层一直挂着不隐藏。
                    if (_controlsVisible) {
                      _scheduleControlsHide();
                    }
                  },
                  onPointerUp: (PointerUpEvent event) {
                    final Offset? start = _pointerStart;
                    _pointerStart = null;
                    if (_isMobilePlatform && !isWide) {
                      return; // 竖向切集交给跟手动画
                    }
                    if (start == null) {
                      return;
                    }
                    final Offset delta = event.position - start;
                    // 垂直滑动：上滑 = 下一集，下滑 = 上一集（与主流短剧一致）。
                    if (delta.dy.abs() >= 90 &&
                        delta.dy.abs() > delta.dx.abs() * 1.5) {
                      if (delta.dy < 0) {
                        _playNext();
                      } else {
                        _playPrevious();
                      }
                    }
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      // 当前集画面 + 弹幕：整体跟手上移/下移。
                      // 注意：vo=mediacodec_embed 下 Video 是原生 PlatformView，
                      // 会吞掉其覆盖范围内的全部触摸（导致点按切换控制层、上滑/下滑、
                      // 选集面板点击全部失效），因此必须包一层 IgnorePointer，
                      // 把所有手势交还给上层的 Flutter 手势层。
                      // 只要已经开过流就保留视频层：否则一次失败的启动会把
                      // 正在播放的画面换成封面，表现为"有声音、没画面还在报错"。
                      // 静止态完全保持改动前的树：Video/弹幕直接作为 Stack
                      // 子节点。Android mediacodec_embed 的 Video 是原生
                      // PlatformView，放进 Positioned/Transform/嵌套 Stack
                      // 都会导致整块黑屏。只有拖动位移非 0 时才切到嵌套层。
                      if (_swipeDy == 0) ...<Widget>[
                        if (_controller == null ||
                            (_currentStream == null &&
                                (_loading || _error != null)))
                          PosterArtwork(
                            drama: drama,
                            variant: PosterVariant.full,
                          )
                        else
                          IgnorePointer(
                            child: Center(
                              child: Video(
                                controller: _controller!,
                                controls: NoVideoControls,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        if (_danmakuOn && _danmakuCues.isNotEmpty)
                          Positioned.fromRect(
                            rect: danmakuVideoRect(
                              area: MediaQuery.sizeOf(context),
                              videoWidth: _videoWidth,
                              videoHeight: _videoHeight,
                            ),
                            child: ValueListenableBuilder<DanmakuSettings>(
                              valueListenable: danmakuSettingsNotifier,
                              builder:
                                  (
                                    BuildContext context,
                                    DanmakuSettings settings,
                                    _,
                                  ) {
                                    return DanmakuLayer(
                                      cues: _danmakuCues,
                                      position: _danmakuClock,
                                      playing: _danmakuPlaying,
                                      travel: settings.travel,
                                      fontSize: settings.fontSize,
                                      area: settings.area,
                                      // 长按临时倍速同样需要让弹幕跟上进度。
                                      rate: _holdSpeedActive
                                          ? _holdRate
                                          : _rate,
                                    );
                                  },
                            ),
                          ),
                      ] else
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(0, _swipeDy),
                            child: _buildCurrentVideoLayer(drama),
                          ),
                        ),
                      // 上滑（下一集）不再挂第二路 Video：Android 的
                      // mediacodec_embed 抢占视频输出会导致有声无画。
                      // 过渡期间用封面，松手后由 _boot 走缓存重开。
                      if (_swipeDirection > 0 && !isWide)
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(0, screenHeight + _swipeDy),
                            child: PosterArtwork(
                              drama: _activeDrama,
                              variant: PosterVariant.full,
                            ),
                          ),
                        ),
                      // 下滑（上一集）同样用封面从顶部进入。
                      if (_swipeDirection < 0 && !isWide)
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(0, -screenHeight + _swipeDy),
                            child: PosterArtwork(
                              drama: _activeDrama,
                              variant: PosterVariant.full,
                            ),
                          ),
                        ),
                      if (_loading) const _CenteredStatus(loading: true),
                      if (_error != null)
                        _CenteredStatus(message: _error!, onRetry: _boot),
                      AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: IgnorePointer(
                          ignoring: !_controlsVisible,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Color(0xB3000000),
                                  Color(0x1F000000),
                                  Color(0xE6000000),
                                ],
                                stops: <double>[0, 0.38, 1],
                              ),
                            ),
                            // 用 top/bottom 对齐而不是 Column+Spacer：
                            // Spacer 会铺满中间区域并吞掉点击，导致下层手势层收不到事件。
                            child: SafeArea(
                              child: Stack(
                                children: <Widget>[
                                  Align(
                                    alignment: Alignment.topCenter,
                                    child: _PlayerTopBar(
                                      drama: drama,
                                      episodeNumber: _episode,
                                      qualityLabel:
                                          _currentStream?.definition ?? '',
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        if (_player != null)
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              16,
                                              0,
                                              16,
                                              2,
                                            ),
                                            child: _PlaybackProgress(
                                              player: _player!,
                                              onTogglePlay: _togglePlay,
                                              onSeek: _seekToFraction,
                                              onPrevious: _playPrevious,
                                              onNext: _playNext,
                                              muted: _muted,
                                              volume: _volume,
                                              onToggleMute: _toggleMute,
                                              onVolumeChanged: (double value) {
                                                if (_muted) {
                                                  _toggleMute();
                                                }
                                                _setVolume(value);
                                              },
                                              speedLabel: _speedLabel,
                                              onSpeed: _showSpeedSheet,
                                              onShowQuality: _showQualitySheet,
                                              onOpenEpisodes: _showEpisodes,
                                              isFullscreen: isWide,
                                              onToggleFullscreen:
                                                  _toggleFullscreen,
                                              // 手机端才收进右侧操作栏；
                                              // Windows 始终保持原桌面布局。
                                              compact: compactControls,
                                            ),
                                          )
                                        else
                                          // Player 未就绪（纯 UI 环境）：右侧
                                          // 按钮组不依赖播放器实例，照常可用；
                                          // 只隐藏播放/切集/音量这些需要实例的。
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              12,
                                              0,
                                              8,
                                              0,
                                            ),
                                            child: Row(
                                              children: <Widget>[
                                                const Spacer(),
                                                if (!compactControls) ...<
                                                  Widget
                                                >[
                                                  _RailTextAction(
                                                    label: _speedLabel,
                                                    onTap: _showSpeedSheet,
                                                  ),
                                                  _GlassSquareButton(
                                                    icon: Icons
                                                        .high_quality_rounded,
                                                    tooltip: '清晰度',
                                                    onPressed:
                                                        _showQualitySheet,
                                                  ),
                                                  _GlassSquareButton(
                                                    icon: Icons.list_rounded,
                                                    tooltip: '选集',
                                                    onPressed: _showEpisodes,
                                                  ),
                                                ],
                                                _GlassSquareButton(
                                                  icon: isWide
                                                      ? Icons
                                                            .fullscreen_exit_rounded
                                                      : Icons
                                                            .fullscreen_rounded,
                                                  tooltip: isWide
                                                      ? '退出全屏'
                                                      : '全屏',
                                                  onPressed: _toggleFullscreen,
                                                ),
                                              ],
                                            ),
                                          ),
                                        // 桌面端保留原「下一集」面板；移动端
                                        // 竖屏已改成上下滑切集，不再展示。
                                        if (!isWide && !_isMobilePlatform) ...<
                                          Widget
                                        >[
                                          const SizedBox(height: 10),
                                          _NextEpisodePanel(
                                            drama: drama,
                                            nextEpisode: nextEpisode,
                                            episodeTitle: _titleForEpisode(
                                              nextEpisode,
                                            ),
                                            autoPlay: _autoPlay,
                                            enabled:
                                                _episodeCount == 0 ||
                                                _episode < _episodeCount,
                                            onToggleAutoPlay: () {
                                              final bool next = !_autoPlay;
                                              setState(() => _autoPlay = next);
                                              saveAutoPlay(next);
                                            },
                                            onOpenNext: _playNext,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 移动端暂停反馈：中心半透明灰白播放图标（抖音式）。
                      IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: shouldShowPausedIndicator(
                                mobile: _isMobilePlatform,
                                hasPlayer: _player != null,
                                playing: _playing,
                                loading: _loading,
                                hasError: _error != null,
                              )
                              ? 1
                              : 0,
                          duration: const Duration(milliseconds: 160),
                          child: const Center(
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 64,
                              color: Color(0x9EFFFFFF),
                              shadows: <Shadow>[
                                Shadow(
                                  color: Color(0x59000000),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 长按 2x 提示贴顶部居中（不挡画面）；
                      // 左右滑调进度仍用中央指示器。
                      if (_holdSpeedActive)
                        Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 104),
                            child: _SeekIndicator(data: _seekIndicatorData()),
                          ),
                        ),
                      if (_scrubbing)
                        Center(
                          child: _SeekIndicator(data: _seekIndicatorData()),
                        ),
                      // 操作栏：竖屏右侧垂直居中（手机端只放倍速 / 选集 /
                      // 收藏，不再贴着进度条，避免下方控制行拥挤）；
                      // 横屏（全屏 / 物理旋转）同样右侧垂直居中。
                      if (_controlsVisible)
                        isWide
                            ? Positioned(
                                right: 10,
                                top: 0,
                                bottom: 0,
                                child: Center(
                                  child: _buildActionRail(compact: false),
                                ),
                              )
                            : Positioned(
                                right: 12,
                                top: 0,
                                bottom: 0,
                                child: Center(
                                  // 桌面端即使窗口偏窄也保持原操作栏
                                  // （收藏 / 分享），不换成手机版布局。
                                  child: _buildActionRail(
                                    compact: compactControls,
                                  ),
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
    );
  }
}

/// 长按快进/快退、左右滑调进度时的中央指示胶囊。
class _SeekIndicator extends StatelessWidget {
  const _SeekIndicator({required this.data});

  final ({IconData icon, String label, String time}) data;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(data.icon, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            data.label,
            style: const TextStyle(
              fontSize: 14,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            data.time,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.2,
              color: Colors.white.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

class _CenteredStatus extends StatelessWidget {
  const _CenteredStatus({this.loading = false, this.message, this.onRetry});

  final bool loading;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: loading
          ? const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  message ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Colors.white.withValues(alpha: 0.86),
                  ),
                ),
                const SizedBox(height: 14),
                Material(
                  color: AppTokens.immersiveAccent,
                  borderRadius: BorderRadius.circular(9),
                  child: InkWell(
                    onTap: onRetry,
                    borderRadius: BorderRadius.circular(9),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 9,
                      ),
                      child: Text(
                        '重试',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _PlayerTopBar extends StatelessWidget {
  const _PlayerTopBar({
    required this.drama,
    required this.episodeNumber,
    required this.qualityLabel,
  });

  final Drama drama;
  final int episodeNumber;

  /// 当前流清晰度（如 1080P）；空串表示未就绪，副标题只显示集数。
  final String qualityLabel;

  @override
  Widget build(BuildContext context) {
    final String subtitle = qualityLabel.isEmpty
        ? '第$episodeNumber集'
        : '第$episodeNumber集 · $qualityLabel';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 6, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 20,
              color: Colors.white,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  drama.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.94),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: Colors.white.withValues(alpha: 0.60),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassSquareButton extends StatelessWidget {
  const _GlassSquareButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.86)),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    );
  }
}

/// 移动端暂停反馈：有播放器、未播放、未加载、无错误时显示中心播放图标。
@visibleForTesting
bool shouldShowPausedIndicator({
  required bool mobile,
  required bool hasPlayer,
  required bool playing,
  required bool loading,
  required bool hasError,
}) {
  return mobile && hasPlayer && !playing && !loading && !hasError;
}

/// 长按中间 1/3 打开播放设置；两侧仍走临时 2x。
@visibleForTesting
bool isPlayerSheetZone(double x, double width) {
  if (width <= 0) {
    return false;
  }
  return x >= width / 3 && x <= width * 2 / 3;
}

const double _swipeCommitFraction = 0.28;
const double _swipeCommitVelocity = 800;

/// 相邻集预解析开关（只缓存解析结果，不建第二个播放器）。
const bool _kEnablePrefetch = true;

/// 下一集预解析目标；最后一集或不合法输入返回 0。
@visibleForTesting
int nextPreloadEpisode(int current, int count) {
  if (count <= 0 || current < 1 || current >= count) {
    return 0;
  }
  return current + 1;
}

/// 上下滑松手方向：1 = 下一集，-1 = 上一集，0 = 回弹。
@visibleForTesting
int swipeCommitDirection({
  required double dy,
  required double velocity,
  required double height,
}) {
  if (height <= 0) {
    return 0;
  }
  final double threshold = height * _swipeCommitFraction;
  if (dy < 0 && (dy.abs() >= threshold || velocity <= -_swipeCommitVelocity)) {
    return 1;
  }
  if (dy > 0 && (dy.abs() >= threshold || velocity >= _swipeCommitVelocity)) {
    return -1;
  }
  return 0;
}

String _formatDuration(Duration value) {
  final int totalSeconds = value.inSeconds;
  final int minutes = (totalSeconds ~/ 60) % 60;
  final int seconds = totalSeconds % 60;
  final int hours = totalSeconds ~/ 3600;
  final String mm = minutes.toString().padLeft(2, '0');
  final String ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// 底部控制区（参考桌面播放器惯例）：
/// 上行——当前时间、全宽细进度条、总时长两端对齐；
/// 下行——上一集 / 播放暂停 / 下一集 / 静音 + 内联音量条靠左，
/// 倍速 / 清晰度 / 选集 / 全屏靠右。
class _PlaybackProgress extends StatelessWidget {
  const _PlaybackProgress({
    required this.player,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.muted,
    required this.volume,
    required this.onToggleMute,
    required this.onVolumeChanged,
    required this.speedLabel,
    required this.onSpeed,
    required this.onShowQuality,
    required this.onOpenEpisodes,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.compact = false,
  });

  final Player player;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeek;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool muted;
  final double volume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolumeChanged;
  final String speedLabel;
  final VoidCallback onSpeed;
  final VoidCallback onShowQuality;
  final VoidCallback onOpenEpisodes;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (BuildContext context, AsyncSnapshot<Duration> posSnap) {
            return StreamBuilder<Duration>(
              stream: player.stream.duration,
              initialData: player.state.duration,
              builder: (BuildContext context, AsyncSnapshot<Duration> durSnap) {
                final Duration position = posSnap.data ?? Duration.zero;
                final Duration total = durSnap.data ?? Duration.zero;
                final double fraction = total.inMilliseconds > 0
                    ? (position.inMilliseconds / total.inMilliseconds).clamp(
                        0.0,
                        1.0,
                      )
                    : 0.0;
                return Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          _formatDuration(position),
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            color: Colors.white.withValues(alpha: 0.72),
                          ),
                        ),
                        Expanded(
                          child: Semantics(
                            label: '播放进度 ${(fraction * 100).round()}%',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: _ProgressBar(
                                value: fraction,
                                onSeek: onSeek,
                              ),
                            ),
                          ),
                        ),
                        Text(
                          _formatDuration(total),
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            color: Colors.white.withValues(alpha: 0.72),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: <Widget>[
                        // 移动端竖屏：点画面暂停、上下滑切集，底部只留全屏。
                        if (compact) ...<Widget>[
                          const Spacer(),
                          _GlassSquareButton(
                            icon: isFullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                            tooltip: isFullscreen ? '退出全屏' : '全屏',
                            onPressed: onToggleFullscreen,
                          ),
                        ] else ...<Widget>[
                          _GlassSquareButton(
                            icon: Icons.skip_previous_rounded,
                            tooltip: '上一集',
                            onPressed: onPrevious,
                          ),
                          StreamBuilder<bool>(
                            stream: player.stream.playing,
                            initialData: player.state.playing,
                            builder:
                                (
                                  BuildContext context,
                                  AsyncSnapshot<bool> snapshot,
                                ) {
                                  final bool playing =
                                      snapshot.data ?? false;
                                  return Semantics(
                                    button: true,
                                    label: playing ? '暂停' : '播放',
                                    child: IconButton(
                                      tooltip: playing ? '暂停' : '播放',
                                      onPressed: onTogglePlay,
                                      icon: Icon(
                                        playing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        size: 26,
                                        color: Colors.white,
                                      ),
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 34,
                                            height: 34,
                                          ),
                                    ),
                                  );
                                },
                          ),
                          _GlassSquareButton(
                            icon: Icons.skip_next_rounded,
                            tooltip: '下一集',
                            onPressed: onNext,
                          ),
                          const SizedBox(width: 6),
                          _GlassSquareButton(
                            icon: muted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            tooltip: muted ? '取消静音' : '静音',
                            onPressed: onToggleMute,
                          ),
                          SizedBox(
                            width: 90,
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 3,
                                overlayShape: SliderComponentShape.noOverlay,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5,
                                ),
                                activeTrackColor: AppTokens.immersiveAccent,
                                inactiveTrackColor: Colors.white.withValues(
                                  alpha: 0.24,
                                ),
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: (muted ? 0.0 : volume).clamp(0.0, 1.0),
                                onChanged: onVolumeChanged,
                              ),
                            ),
                          ),
                          const Spacer(),
                          _RailTextAction(
                            label: speedLabel,
                            onTap: onSpeed,
                          ),
                          _GlassSquareButton(
                            icon: Icons.high_quality_rounded,
                            tooltip: '清晰度',
                            onPressed: onShowQuality,
                          ),
                          _GlassSquareButton(
                            icon: Icons.list_rounded,
                            tooltip: '选集',
                            onPressed: onOpenEpisodes,
                          ),
                          _GlassSquareButton(
                            icon: isFullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                            tooltip: isFullscreen ? '退出全屏' : '全屏',
                            onPressed: onToggleFullscreen,
                          ),
                        ],
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }
}

/// 底部控制行的文字按钮（倍速「1.5x」等）。
class _RailTextAction extends StatelessWidget {
  const _RailTextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.90),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, required this.onSeek});

  final double value;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final double playedWidth = width * value;

          void handle(Offset localPosition) {
            if (width <= 0) {
              return;
            }
            onSeek((localPosition.dx / width).clamp(0.0, 1.0));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails details) =>
                handle(details.localPosition),
            onHorizontalDragUpdate: (DragUpdateDetails details) =>
                handle(details.localPosition),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: <Widget>[
                Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                Container(
                  width: playedWidth,
                  height: 2,
                  decoration: BoxDecoration(
                    color: AppTokens.immersiveAccent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                Positioned(
                  left: (playedWidth - 4).clamp(0, width),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTokens.immersiveAccent,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.85),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.onFavorite,
    required this.onShare,
    required this.speedLabel,
    required this.onSpeed,
    required this.onOpenEpisodes,
    required this.danmakuOn,
    required this.onToggleDanmaku,
    required this.onDanmakuSettings,
    required this.onMore,
    this.favorited = false,
    this.compact = false,
  });

  final VoidCallback onFavorite;
  final VoidCallback onShare;
  final String speedLabel;
  final VoidCallback onSpeed;
  final VoidCallback onOpenEpisodes;
  final bool danmakuOn;
  final VoidCallback onToggleDanmaku;
  final VoidCallback onDanmakuSettings;

  /// 移动端右栏的「播放设置」入口：稳定打开清晰度/弹幕设置/自动播放/音量。
  final VoidCallback onMore;
  final bool favorited;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (compact) ...<Widget>[
          _RailTextAction(label: speedLabel, onTap: onSpeed),
          const SizedBox(height: 10),
          _RailAction(
            icon: Icons.list_rounded,
            label: '选集',
            onTap: onOpenEpisodes,
          ),
          const SizedBox(height: 18),
          _RailAction(
            icon: danmakuOn
                ? Icons.subtitles_rounded
                : Icons.subtitles_off_rounded,
            label: danmakuOn ? '弹幕开' : '弹幕关',
            onTap: onToggleDanmaku,
          ),
          const SizedBox(height: 10),
          _RailAction(
            icon: Icons.tune_rounded,
            label: '设置',
            tooltip: '播放设置',
            onTap: onMore,
          ),
          const SizedBox(height: 18),
          _RailAction(
            icon: favorited ? Icons.star_rounded : Icons.star_border_rounded,
            label: favorited ? '已收藏' : '收藏',
            onTap: onFavorite,
            iconColor: favorited ? const Color(0xFFFFC94D) : null,
          ),
        ] else ...<Widget>[
          _RailAction(
            icon: danmakuOn
                ? Icons.subtitles_rounded
                : Icons.subtitles_off_rounded,
            label: danmakuOn ? '弹幕开' : '弹幕关',
            onTap: onToggleDanmaku,
          ),
          const SizedBox(height: 10),
          // 开关旁边紧邻设置入口：桌面端开浮动面板。
          _RailAction(
            icon: Icons.tune_rounded,
            label: '弹幕设置',
            onTap: onDanmakuSettings,
          ),
          const SizedBox(height: 18),
          _RailAction(
            icon: favorited ? Icons.star_rounded : Icons.star_border_rounded,
            label: favorited ? '已收藏' : '收藏',
            onTap: onFavorite,
            iconColor: favorited ? const Color(0xFFFFC94D) : null,
          ),
          const SizedBox(height: 20),
          _RailAction(
            icon: Icons.forward_rounded,
            label: '分享',
            onTap: onShare,
          ),
        ],
      ],
    );
  }
}

class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 覆盖图标颜色（如收藏选中态的金色）；不传用默认白色。
  final Color? iconColor;

  /// 可选 tooltip；右栏「播放设置」用它给测试和辅助功能一个稳定入口。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget action = Semantics(
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
    );
    if (tooltip == null) {
      return action;
    }
    return Tooltip(message: tooltip!, child: action);
  }
}

class _NextEpisodePanel extends StatelessWidget {
  const _NextEpisodePanel({
    required this.drama,
    required this.nextEpisode,
    required this.episodeTitle,
    required this.autoPlay,
    required this.enabled,
    required this.onToggleAutoPlay,
    required this.onOpenNext,
  });

  final Drama drama;
  final int nextEpisode;

  /// 当前集标题；用于在「下一集」卡片里展示剧集名。
  final String episodeTitle;
  final bool autoPlay;

  /// 已是最后一集时禁用跳转。
  final bool enabled;
  final VoidCallback onToggleAutoPlay;
  final VoidCallback onOpenNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF101014),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: Color(0x14FFFFFF), width: 0.8)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text(
                  '下一集',
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                Text(
                  '自动播放',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    color: Colors.white.withValues(alpha: 0.52),
                  ),
                ),
                const SizedBox(width: 7),
                _AutoPlaySwitch(value: autoPlay, onToggle: onToggleAutoPlay),
              ],
            ),
            const SizedBox(height: 11),
            Opacity(
              opacity: enabled ? 1 : 0.45,
              child: InkWell(
                onTap: enabled ? onOpenNext : null,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: SizedBox(
                          width: 56,
                          height: 72,
                          child: PosterArtwork(
                            drama: drama,
                            variant: PosterVariant.thumb,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '第$nextEpisode集',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              episodeTitle.isNotEmpty
                                  ? episodeTitle
                                  : drama.episodeTitle(nextEpisode),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.3,
                                color: Colors.white.withValues(alpha: 0.58),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.play_circle_outline_rounded,
                        size: 26,
                        color: Colors.white.withValues(alpha: 0.74),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AutoPlaySwitch extends StatelessWidget {
  const _AutoPlaySwitch({required this.value, required this.onToggle});

  final bool value;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: '自动播放',
      child: GestureDetector(
        onTap: onToggle,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 36,
          height: 21,
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
              width: 17,
              height: 17,
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

/// 选集面板：季 chips + 分集网格。
///
/// 点季只切换"当前要选哪一季的分集列表"，不立即换播放画面；
/// 选中某一集后才把「季 + 集」一起交给播放页，避免误点季就跳走。
class _EpisodeSheet extends StatefulWidget {
  const _EpisodeSheet({
    required this.episodes,
    required this.current,
    required this.seasons,
    required this.currentSeriesId,
    required this.loadEpisodes,
  });

  /// 当前播放季的分集（首屏直接复用，不重复请求）。
  final List<EpisodeInfo> episodes;
  final int current;

  /// 多季剧的季列表；不足两季时不显示季行。
  final List<SeasonInfo> seasons;
  final String currentSeriesId;

  /// 按季拉分集；点其他季时按需调用。
  final Future<List<EpisodeInfo>> Function(String seriesId) loadEpisodes;

  @override
  State<_EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<_EpisodeSheet> {
  late String _seriesId = widget.currentSeriesId;
  late List<EpisodeInfo> _episodes = widget.episodes;
  bool _loading = false;
  String? _error;

  /// 季切换请求序号：连点多个季时只认最后一次的结果。
  int _seasonToken = 0;

  Future<void> _selectSeason(SeasonInfo season) async {
    if (season.seriesId == _seriesId) {
      return;
    }
    final int token = ++_seasonToken;
    final bool empty = season.episodeCount <= 0;
    setState(() {
      _seriesId = season.seriesId;
      _episodes = const <EpisodeInfo>[];
      _error = empty ? '该季暂未开播，敬请期待' : null;
      _loading = !empty;
    });
    if (empty) {
      return;
    }
    try {
      final List<EpisodeInfo> list = await widget.loadEpisodes(season.seriesId);
      if (!mounted || token != _seasonToken) {
        return;
      }
      setState(() {
        _episodes = list;
        _loading = false;
        _error = list.isEmpty ? '该季暂未开播，敬请期待' : null;
      });
    } on ApiException catch (error) {
      if (!mounted || token != _seasonToken) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.62;
    final bool sameSeason = _seriesId == widget.currentSeriesId;
    final String subtitle = _loading
        ? '加载中'
        : _episodes.isEmpty
        ? '暂无分集'
        : '共${_episodes.length}集';
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SheetHeader(title: '选集', subtitle: subtitle),
            if (widget.seasons.length > 1)
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  itemCount: widget.seasons.length,
                  separatorBuilder: (BuildContext _, int _) =>
                      const SizedBox(width: 8),
                  itemBuilder: (BuildContext context, int index) {
                    final SeasonInfo season = widget.seasons[index];
                    final bool selected = season.seriesId == _seriesId;
                    return Material(
                      color: selected
                          ? AppTokens.immersiveAccent
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        // 只切换列表，不换播放画面；选集后再一起切。
                        onTap: () => _selectSeason(season),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Center(
                            child: Text(
                              season.index > 0
                                  ? '第${season.index}季'
                                  : season.title,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.1,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: selected
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.78),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            Flexible(child: _buildBody(context, sameSeason)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, bool sameSeason) {
    if (_loading) {
      return _hint('正在加载分集…');
    }
    if (_error != null) {
      return _hint(_error!);
    }
    if (_episodes.isEmpty) {
      return _hint('分集还在加载，请稍候…');
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // 格子尺寸随弹层宽度收紧：桌面宽弹层 10 列、
        // 中等 7 列、手机 5 列，避免百集面板被巨格撑爆。
        final double width = box.maxWidth;
        final int columns = width >= 560 ? 10 : (width >= 380 ? 7 : 5);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 7,
            crossAxisSpacing: 7,
            childAspectRatio: 1.6,
          ),
          itemCount: _episodes.length,
          itemBuilder: (BuildContext context, int index) {
            final EpisodeInfo episode = _episodes[index];
            final bool selected =
                sameSeason && episode.number == widget.current;
            // 服务端禁止播放的分集不可选，避免点了才失败。
            final bool enabled = episode.playable;
            return Material(
              color: !enabled
                  ? Colors.white.withValues(alpha: 0.04)
                  : selected
                  ? AppTokens.immersiveAccent
                  : Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(7),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: enabled
                    ? () => Navigator.of(context).pop(
                        _EpisodePick(
                          seriesId: _seriesId,
                          number: episode.number,
                        ),
                      )
                    : null,
                child: Center(
                  child: Text(
                    '${episode.number}',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: !enabled
                          ? Colors.white.withValues(alpha: 0.30)
                          : selected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.78),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _hint(String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12.5,
          color: Colors.white.withValues(alpha: 0.52),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.white.withValues(alpha: 0.48),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(
              Icons.close_rounded,
              size: 20,
              color: Colors.white.withValues(alpha: 0.72),
            ),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          ),
        ],
      ),
    );
  }
}

/// 清晰度面板：列出当前分集的全部候选流，当前档高亮。
/// 点选后 pop 回 [StreamInfo]，由播放页执行切档。
class _QualitySheet extends StatelessWidget {
  const _QualitySheet({required this.streams, required this.currentDefinition});

  final List<StreamInfo> streams;
  final String currentDefinition;

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.62;
    // 高分辨率在前，便于从高往低选。
    final List<StreamInfo> ordered = <StreamInfo>[...streams]
      ..sort((StreamInfo a, StreamInfo b) => b.height.compareTo(a.height));
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SheetHeader(
              title: '清晰度',
              subtitle: ordered.isEmpty ? '解析中' : '共${ordered.length}档',
            ),
            Flexible(
              child: ordered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
                      child: Text(
                        '播放地址还在解析，请稍候…',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.white.withValues(alpha: 0.52),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                      itemCount: ordered.length,
                      itemBuilder: (BuildContext context, int index) {
                        final StreamInfo stream = ordered[index];
                        final bool selected =
                            stream.definition == currentDefinition;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Material(
                            color: selected
                                ? AppTokens.immersiveAccent
                                : Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => Navigator.of(context).pop(stream),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Text(
                                        stream.label,
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          height: 1.2,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: selected
                                              ? Colors.white
                                              : Colors.white.withValues(
                                                  alpha: 0.78,
                                                ),
                                        ),
                                      ),
                                    ),
                                    if (selected) ...<Widget>[
                                      const SizedBox(width: 8),
                                      const Icon(
                                        Icons.check_rounded,
                                        size: 18,
                                        color: Colors.white,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 倍速面板：点选后 pop 回速率值，播放页 setRate 即时生效。
class _SpeedSheet extends StatelessWidget {
  const _SpeedSheet({required this.current});

  final double current;

  static const List<double> _rates = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.62;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _SheetHeader(title: '倍速播放', subtitle: '立即生效'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.4,
                ),
                itemCount: _rates.length,
                itemBuilder: (BuildContext context, int index) {
                  final double rate = _rates[index];
                  final bool selected = rate == current;
                  return Material(
                    color: selected
                        ? AppTokens.immersiveAccent
                        : Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(rate),
                      child: Center(
                        child: Text(
                          '${rate}x',
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.1,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.78),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选集弹层的返回值：seriesId 与集号。换季时 seriesId 变化、集号回到 1。
class _EpisodePick {
  const _EpisodePick({required this.seriesId, required this.number});

  final String seriesId;
  final int number;
}
