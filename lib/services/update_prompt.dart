import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/simple_markdown.dart';
import 'apk_installer.dart';
import 'update_downloader.dart';
import 'update_service.dart';

/// 检查更新并按需弹窗。设置页 / 「我的」页共用（带反馈提示），启动时
/// 走 [silent]：失败、已是最新都静默，只有发现新版才弹窗。
///
/// 弹窗提供两种更新方式：
/// - 直连下载：应用内经国内中转链下载（启动后后台测速，按最快顺序；
///   默认 gh-proxy → xget → ghfast.top → 官方直链，见
///   [UpdateDownloader]），全部失败自动回退网页下载；
/// - 网页下载：打开浏览器到下载页（原行为）。
class UpdatePrompt {
  const UpdatePrompt._();

  static Future<void> check(
    BuildContext context, {
    required String currentVersion,
    bool silent = false,
  }) async {
    UpdateInfo? update;
    String? error;
    try {
      update = await UpdateService.check(currentVersion);
    } on UpdateException catch (e) {
      error = e.message;
    } catch (_) {
      error = '网络异常，请稍后重试';
    }
    if (!context.mounted) {
      return;
    }
    void snack(String message) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }

    if (error != null) {
      if (!silent) {
        snack('检查失败：$error');
      }
      return;
    }
    if (update == null) {
      if (!silent) {
        snack('当前已是最新版本');
      }
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('发现新版本 v${update!.version}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: SimpleMarkdown(
              update.notes.isEmpty ? '性能优化与问题修复。' : update.notes,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              launchUrl(
                Uri.parse(update!.downloadUrl),
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(Platform.isIOS ? '前往下载 IPA' : '网页下载'),
          ),
          if (!Platform.isIOS)
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _downloadInApp(context, update!, snack);
              },
              child: const Text('直连下载'),
            ),
        ],
      ),
    );
  }

  /// 应用内直连下载：进度对话框 → 落盘 → 拉起安装/打开；中转链全部
  /// 失败时回退网页下载。
  static Future<void> _downloadInApp(
    BuildContext context,
    UpdateInfo update,
    void Function(String message) snack,
  ) async {
    final ValueNotifier<double> progress = ValueNotifier<double>(0);
    final AlertDialog progressDialog = AlertDialog(
      title: Text('正在下载 v${update.version}'),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (BuildContext context, double value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            LinearProgressIndicator(value: value < 0 ? null : value),
            const SizedBox(height: 12),
            Text(
              value < 0 ? '连接中…（服务端未返回大小）' : '${(value * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => progressDialog,
      ),
    );

    final String? path = await UpdateDownloader.download(
      update.downloadUrl,
      onProgress: (double value) => progress.value = value,
    );
    if (!context.mounted) {
      return;
    }
    Navigator.of(context, rootNavigator: true).pop(); // 关进度框

    if (path == null) {
      snack('直连下载失败，已为你打开网页下载');
      launchUrl(
        Uri.parse(update.downloadUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    // Android 未授予「安装未知应用」时，系统会静默拦下安装器
    // （open_filex 仍返回 done），所以必须先查授权并引导去设置。
    if (Platform.isAndroid && !await ApkInstaller.canInstall()) {
      final bool opened = await ApkInstaller.openSettings();
      snack(
        opened
            ? '请先允许「安装未知应用」，返回后再次点击更新即可安装已下载的包'
            : '请到系统设置中允许本应用安装未知应用后重试',
      );
      return;
    }
    snack('下载完成，正在打开…');
    // Android：APK 拉起系统安装器；Windows：用系统默认方式打开
    // （zip 资源管理器可定位，后续发安装器 exe 后即为直接运行安装）。
    final OpenResult result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      snack('无法自动打开安装包：${result.message}');
    }
  }
}
