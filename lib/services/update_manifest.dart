/// `updates.json` 国内兜底清单。
///
/// GitHub API 在国内可能不可达或触发限流，此时改读仓库里的
/// `updates.json`（经 xget / jsDelivr 镜像），再按 Release 资产命名
/// 规则拼出下载地址。清单结构示例：
///
/// ```json
/// {
///   "1.5.0": {
///     "date": "2026-11-18",
///     "notes": "## ...",
///     "downloads": {
///       "android-arm64": "https://github.com/...",
///       "windows-x64": "https://github.com/..."
///     }
///   }
/// }
/// ```
///
/// `downloads` 可选：有则优先使用，便于发布后修正资产地址；没有则按
/// [assetUrl] 的固定命名规则拼接。
class UpdateManifest {
  const UpdateManifest._();

  /// 版本号只接受数字与点，避免把描述性 key 当成版本。
  static final RegExp _versionPattern = RegExp(r'^\d+(?:\.\d+)*$');

  /// 清单候选地址：xget 优先（国内直连最快），jsDelivr 双节点兜底，
  /// 最后才是 GitHub raw 官方地址。
  static List<String> urls({required String owner, required String repo}) {
    return <String>[
      'https://xget.xi-xu.me/gh/$owner/$repo/raw/master/updates.json',
      'https://cdn.jsdelivr.net/gh/$owner/$repo@master/updates.json',
      'https://fastly.jsdelivr.net/gh/$owner/$repo@master/updates.json',
      'https://raw.githubusercontent.com/$owner/$repo/master/updates.json',
    ];
  }

  /// 取清单中版本号最大的合法条目；没有合法条目返回 null。
  ///
  /// 条目必须带非空 `notes`，与发布脚本「updates.json 缺条目就失败」的
  /// 约束保持一致。
  static UpdateManifestEntry? latest(Map<String, dynamic> json) {
    UpdateManifestEntry? best;
    for (final MapEntry<String, dynamic> item in json.entries) {
      if (!_versionPattern.hasMatch(item.key)) {
        continue;
      }
      final Object? raw = item.value;
      if (raw is! Map) {
        continue;
      }
      final Object? notes = raw['notes'];
      if (notes is! String || notes.trim().isEmpty) {
        continue;
      }
      final Object? date = raw['date'];
      final UpdateManifestEntry entry = UpdateManifestEntry(
        version: item.key,
        notes: notes.trim(),
        publishedAt: date is String ? DateTime.tryParse(date) : null,
        downloads: _stringMap(raw['downloads']),
      );
      if (best == null || isNewerVersion(entry.version, best.version)) {
        best = entry;
      }
    }
    return best;
  }

  /// 按发布约定拼 Release 资产地址。
  ///
  /// Android 前缀带 `v`（`ApexDrama-v1.5.1-arm64-v8a.apk`），Windows
  /// 不带 `v`（`ApexDrama-1.5.1-windows-x64-setup.exe`），与 release.yml
  /// 的产物命名一致。
  static String assetUrl({
    required String owner,
    required String repo,
    required String version,
    required bool windows,
    bool ios = false,
  }) {
    if (ios) {
      return 'https://github.com/$owner/$repo/releases/download/v$version/HongGuo-AdiBan.ipa';
    }
    final String file = windows
        ? 'ApexDrama-$version-windows-x64-setup.exe'
        : 'ApexDrama-v$version-arm64-v8a.apk';
    return 'https://github.com/$owner/$repo/releases/download/v$version/$file';
  }

  /// 语义化版本比较：逐段数字比较，段数不足补 0。
  /// 1.10 > 1.9；1.0.1 > 1.0；非法字符按 0 处理。
  static bool isNewerVersion(String candidate, String current) {
    final List<int> a = _versionSegments(candidate);
    final List<int> b = _versionSegments(current);
    final int len = a.length > b.length ? a.length : b.length;
    for (int i = 0; i < len; i++) {
      final int x = i < a.length ? a[i] : 0;
      final int y = i < b.length ? b[i] : 0;
      if (x != y) {
        return x > y;
      }
    }
    return false;
  }

  static List<int> _versionSegments(String version) {
    return version
        .split('.')
        .map((String part) => int.tryParse(part.trim()) ?? 0)
        .toList();
  }

  static Map<String, String> _stringMap(Object? raw) {
    final Map<String, String> result = <String, String>{};
    if (raw is Map) {
      for (final MapEntry<dynamic, dynamic> item in raw.entries) {
        final Object? key = item.key;
        final Object? value = item.value;
        if (key is String && value is String && value.trim().isNotEmpty) {
          result[key] = value.trim();
        }
      }
    }
    return result;
  }
}

/// 清单里的单条版本信息。
class UpdateManifestEntry {
  const UpdateManifestEntry({
    required this.version,
    required this.notes,
    required this.publishedAt,
    required this.downloads,
  });

  final String version;
  final String notes;
  final DateTime? publishedAt;

  /// 可选的显式下载地址，key 为 `android-arm64` / `windows-x64`。
  final Map<String, String> downloads;

  /// 当前平台的显式下载地址；没有配置时返回 null，由调用方按命名规则拼接。
  String? downloadFor({required bool windows, bool ios = false}) {
    if (ios) {
      return downloads['ios'];
    }
    return downloads[windows ? 'windows-x64' : 'android-arm64'];
  }
}
