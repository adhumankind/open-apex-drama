import 'dart:ui';
import 'package:flutter/material.dart';

import '../services/dlna/dlna_device.dart';
import '../services/dlna/dlna_manager.dart';

/// 弹出 DLNA 投屏设备选择面板（iOS 磨砂毛玻璃风格）。
Future<DlnaDevice?> showCastDeviceSheet(BuildContext context) async {
  DlnaManager.instance.startDiscovery();
  return showModalBottomSheet<DlnaDevice>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (BuildContext ctx) => const _CastDeviceSheet(),
  );
}

class _CastDeviceSheet extends StatefulWidget {
  const _CastDeviceSheet();

  @override
  State<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<_CastDeviceSheet> {
  @override
  Widget build(BuildContext context) {
    final DlnaManager manager = DlnaManager.instance;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF16181F).withValues(alpha: 0.88),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 0.5,
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 顶部抓手条
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 标题与刷新按钮
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.cast_rounded,
                            color: Color(0xFFFF4D4F),
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '投屏到电视 / 设备',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: manager.isSearchingNotifier,
                        builder: (BuildContext context, bool searching, _) {
                          return searching
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white70,
                                    ),
                                  ),
                                )
                              : IconButton(
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    color: Colors.white70,
                                    size: 20,
                                  ),
                                  onPressed: () => manager.startDiscovery(),
                                  tooltip: '重新搜索',
                                );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 设备列表
                  ValueListenableBuilder<List<DlnaDevice>>(
                    valueListenable: manager.devicesNotifier,
                    builder: (BuildContext context, List<DlnaDevice> devices, _) {
                      if (devices.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Column(
                              children: <Widget>[
                                Icon(
                                  Icons.tv_off_rounded,
                                  size: 44,
                                  color: Colors.white.withValues(alpha: 0.3),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  '正在搜索局域网内的小米电视、爱奇艺电视果...',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.white.withValues(alpha: 0.6),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '请确保手机与电视连接在同一 Wi-Fi 下',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: Colors.white.withValues(alpha: 0.38),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: devices.length,
                          separatorBuilder: (_, _) => Divider(
                            color: Colors.white.withValues(alpha: 0.08),
                            height: 1,
                          ),
                          itemBuilder: (BuildContext context, int index) {
                            final DlnaDevice dev = devices[index];
                            final bool isXiaomi = dev.isXiaomi;
                            final bool isDianshiguo = dev.isDianshiguo;

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              leading: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isXiaomi
                                      ? Colors.orange.withValues(alpha: 0.16)
                                      : isDianshiguo
                                          ? Colors.green.withValues(alpha: 0.16)
                                          : Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.tv_rounded,
                                  color: isXiaomi
                                      ? const Color(0xFFFF6900)
                                      : isDianshiguo
                                          ? const Color(0xFF00C853)
                                          : Colors.white70,
                                  size: 22,
                                ),
                              ),
                              title: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      dev.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  if (isXiaomi || isDianshiguo)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isXiaomi
                                            ? Colors.orange.withValues(alpha: 0.22)
                                            : Colors.green.withValues(alpha: 0.22),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isXiaomi ? '小米' : '电视果',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: isXiaomi
                                              ? const Color(0xFFFF9800)
                                              : const Color(0xFF69F0AE),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Text(
                                dev.subtitle,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white38,
                              ),
                              onTap: () {
                                Navigator.of(context).pop(dev);
                              },
                            );
                          },
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 12),
                  // 底部温馨提示
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '• 小米电视：请确保电视设置中已开启「米联/DLNA」\n• 爱奇艺电视果：支持全系电视果即开即投',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
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
