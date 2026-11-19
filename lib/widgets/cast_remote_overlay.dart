import 'dart:ui';
import 'package:flutter/material.dart';

import '../models/drama.dart';
import '../services/dlna/dlna_device.dart';
import '../services/dlna/dlna_manager.dart';
import 'poster_artwork.dart';

/// 投屏状态下的电视遥控器浮层。
///
/// 具备：
/// 1. 当前电视设备名与剧集信息展示；
/// 2. 实时电视进度同步与【拖动调整进度】（Seek）；
/// 3. 播放 / 暂停 / 快进 10 秒 / 快退 10 秒；
/// 4. 上下集切换与退出投屏。
class CastRemoteOverlay extends StatefulWidget {
  const CastRemoteOverlay({
    super.key,
    required this.drama,
    required this.episodeNumber,
    required this.episodeTitle,
    required this.onPlayPrevious,
    required this.onPlayNext,
    required this.onExitCast,
  });

  final Drama drama;
  final int episodeNumber;
  final String episodeTitle;
  final VoidCallback onPlayPrevious;
  final VoidCallback onPlayNext;
  final VoidCallback onExitCast;

  @override
  State<CastRemoteOverlay> createState() => _CastRemoteOverlayState();
}

class _CastRemoteOverlayState extends State<CastRemoteOverlay> {
  bool _isScrubbing = false;
  double _scrubValueSeconds = 0;

  @override
  Widget build(BuildContext context) {
    final DlnaManager manager = DlnaManager.instance;

    return Stack(
      children: <Widget>[
        // 背景微弱模糊与深色蒙层
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              color: const Color(0xFF0D0F14).withValues(alpha: 0.94),
            ),
          ),
        ),

        // 遥控器主内容
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              children: <Widget>[
                // 顶部：正在投屏设备状态与退出按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    ValueListenableBuilder<DlnaDevice?>(
                      valueListenable: manager.activeDeviceNotifier,
                      builder: (BuildContext context, DlnaDevice? dev, _) {
                        return Row(
                          children: <Widget>[
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF4D4F).withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.cast_connected_rounded,
                                color: Color(0xFFFF4D4F),
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Text(
                                  '正在投屏到',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white54,
                                  ),
                                ),
                                Text(
                                  dev?.name ?? '电视设备',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: widget.onExitCast,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('退出投屏', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),

                const Spacer(flex: 1),

                // 中间：短剧封面与剧集信息
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 140,
                    height: 190,
                    child: PosterArtwork(
                      drama: widget.drama,
                      variant: PosterVariant.full,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.drama.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '第${widget.episodeNumber}集 ${widget.episodeTitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.65),
                  ),
                ),

                const Spacer(flex: 2),

                // 进度条控制（支持拖动调整播放进度）
                AnimatedBuilder(
                  animation: Listenable.merge(<Listenable>[
                    manager.castPositionNotifier,
                    manager.castDurationNotifier,
                  ]),
                  builder: (BuildContext context, _) {
                    final Duration pos = manager.castPositionNotifier.value;
                    final Duration dur = manager.castDurationNotifier.value;
                    final double totalSeconds = dur.inSeconds > 0
                        ? dur.inSeconds.toDouble()
                        : 120.0; // 兜底 2 分钟短剧
                    final double currentSeconds = _isScrubbing
                        ? _scrubValueSeconds
                        : pos.inSeconds.toDouble().clamp(0.0, totalSeconds);

                    return Column(
                      children: <Widget>[
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: const Color(0xFFFF4D4F),
                            inactiveTrackColor:
                                Colors.white.withValues(alpha: 0.15),
                            thumbColor: const Color(0xFFFF4D4F),
                            overlayColor:
                                const Color(0xFFFF4D4F).withValues(alpha: 0.2),
                            trackHeight: 3.5,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                          ),
                          child: Slider(
                            value: currentSeconds.clamp(0.0, totalSeconds),
                            max: totalSeconds,
                            onChangeStart: (double v) {
                              setState(() {
                                _isScrubbing = true;
                                _scrubValueSeconds = v;
                              });
                            },
                            onChanged: (double v) {
                              setState(() => _scrubValueSeconds = v);
                            },
                            onChangeEnd: (double v) {
                              _isScrubbing = false;
                              manager.seek(Duration(seconds: v.toInt()));
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[
                              Text(
                                _formatDuration(
                                  Duration(seconds: currentSeconds.toInt()),
                                ),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white54,
                                ),
                              ),
                              Text(
                                _formatDuration(dur),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 14),

                // 遥控器核心控制按钮组
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: <Widget>[
                    // 上一集
                    IconButton(
                      icon: const Icon(
                        Icons.skip_previous_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                      tooltip: '上一集',
                      onPressed: widget.onPlayPrevious,
                    ),

                    // 快退 10 秒
                    IconButton(
                      icon: const Icon(
                        Icons.replay_10_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                      tooltip: '快退 10 秒',
                      onPressed: () {
                        final Duration cur = manager.castPositionNotifier.value;
                        final Duration next = cur - const Duration(seconds: 10);
                        manager.seek(next < Duration.zero ? Duration.zero : next);
                      },
                    ),

                    // 播放 / 暂停大按钮
                    ValueListenableBuilder<bool>(
                      valueListenable: manager.isPlayingNotifier,
                      builder: (BuildContext context, bool playing, _) {
                        return Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: <Color>[
                                Color(0xFFFF5252),
                                Color(0xFFFF1744),
                              ],
                            ),
                            shape: BoxShape.circle,
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: Color(0x66FF1744),
                                blurRadius: 16,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: IconButton(
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 36,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              if (playing) {
                                manager.pause();
                              } else {
                                manager.play();
                              }
                            },
                          ),
                        );
                      },
                    ),

                    // 快进 10 秒
                    IconButton(
                      icon: const Icon(
                        Icons.forward_10_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                      tooltip: '快进 10 秒',
                      onPressed: () {
                        final Duration cur = manager.castPositionNotifier.value;
                        final Duration dur = manager.castDurationNotifier.value;
                        final Duration next = cur + const Duration(seconds: 10);
                        if (dur > Duration.zero && next > dur) {
                          manager.seek(dur);
                        } else {
                          manager.seek(next);
                        }
                      },
                    ),

                    // 下一集
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                      tooltip: '下一集',
                      onPressed: widget.onPlayNext,
                    ),
                  ],
                ),

                const Spacer(flex: 1),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
