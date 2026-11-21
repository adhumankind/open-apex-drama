# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

ApexDrama 是一个 Flutter 第三方短剧客户端（Android / Windows 为主，iOS 工程存在但从未构建验证）。
数据来自非官方 SDK `openhongguo`（git 依赖指向自维护 fork，`ref` 锁 commit），匿名设备、免登录。
仓库的协作与发版硬约定在 `AGENTS.md`，发版前必读；本文件只补充开发期需要的命令与架构。

## 常用命令

```bash
flutter pub get                                   # 依赖（含 git 依赖的 SDK 与预编译原生库）
flutter run                                       # 调试运行（默认设备）
flutter run -d windows                            # 桌面调试
flutter run --dart-define=USE_MOCK=true           # 用 Mock 数据启动（桌面开发常用）
flutter analyze                                   # 静态检查，必须零 issue
flutter test                                      # 全部单元 / widget 测试
flutter test test/watch_store_test.dart           # 单个测试文件
flutter test test/watch_store_test.dart --plain-name "子串"   # 单个用例
flutter build apk --release --split-per-abi       # Android 分包
flutter build windows --release                   # Windows 产物
powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1   # zip + Inno Setup 安装器（dist/）
powershell -ExecutionPolicy Bypass -File tool\bump_version.ps1      # 版本自增，勿手改 pubspec
```

CI（`.github/workflows/ci.yml`）用 Flutter 3.47.9 跑 `flutter analyze` + `flutter test`；PR 必须全绿。
`analysis_options.yaml` 只分析 `lib/` 与 `test/`（平台目录被排除），规则为 `flutter_lints` 默认集。

## 分支与 PR 门禁

- 单次改动（`git diff --stat` 的新增 + 删除行数合计）**超过 400 行必须提 PR**，禁止直接推 `master`；
  CI 全绿后合并。
- **合并方式用 merge commit，不用 squash**（初期保留分支历史），即 `gh pr merge <n> --merge --delete-branch`。
- **大功能必须新开单一分支**（`feat/` / `fix/` / `refactor/` 前缀）完成，再合并回来；合并后先把本地
  `master` 对齐 `origin/master`，再开下一个分支。

## 架构

### 启动与两套状态体系

`lib/main.dart` 在 `runApp` 前完成全部同步初始化：`loadAppearance/loadProfile/loadPlaybackPrefs/loadDanmakuPrefs`，
随后用 `ProviderScope` 包裹 `ApexApp`。平台差异必须在 `runApp` 之前 gate：
`windowManager.ensureInitialized()` 只在 Windows 调用（Android 上调用其 channel 会
`MissingPluginException`，导致启动黑屏，这是 v1.1.0 线上事故的根因）；`MediaKit.ensureInitialized()`
用 try/catch 降级（Windows 壳缺 libmpv-2.dll 时仍要能起 UI）。

项目刻意并存两套状态：

- `lib/app_state/`：全局 `ValueNotifier` 单例 + SharedPreferences，保存用户偏好（主题、播放偏好、
  弹幕偏好、同步设置）。这些在 `runApp` 前加载，UI 用 `ValueListenableBuilder` 直接监听。
- Riverpod：数据请求、观看记录、WebDAV 同步等异步状态，集中在 `lib/providers/`。

新增用户偏好默认沿用 `app_state` 的「文件内 load/save + 顶层 notifier」模式；新增业务数据用 Riverpod。

### 数据层：接口 → SDK / Mock 双实现

```
screens/widgets  ──依赖──▶  models/（App 域模型）
      │
      ▼
providers/data_providers.dart ──watch(dataModeProvider)──▶  data/repository/
                                                             ├─ sdk_repositories.dart
                                                             └─ mock_repositories.dart
```

- 契约在 `lib/data/repository/repositories.dart`（`CatalogRepository` / `RankRepository` /
  `PlaybackRepository`）。业务模型（`models/drama.dart`、`playback.dart`、`series_detail.dart` 等）
  与 SDK 类型解耦，转换集中在 `lib/data/mappers.dart`。
- **UI 不直接 import `package:openhongguo`**。SDK 只出现在 `data/remote/openhongguo_service.dart`
  与 `sdk_repositories.dart`。`OpenhongguoService` 是单例，首次访问注册匿名设备并复用。
- `dataModeProvider` 在运行时切换 SDK / Mock（SDK 调试页可手动切，`USE_MOCK` 只改初始值）。
- 错误统一翻译成 `ApiException`（带 `code` / `retryable` / `userMessage`），仓库层的 `_guard`
  负责包装。
- `homeFeedProvider` 有降级策略：SDK 频道失败或未接入时回退 Mock 数据并标记 `isFallback`。
- `SdkPlaybackRepository.resolve()` **按 episodeId 缓存解析结果**——匿名设备解析额度有限，
  绝不重复解析；服务端抖动有 1s/3s/6s 退避重试。改动播放链路时不要绕过该缓存。
- 多页接口（分集、弹幕、搜索）都按 cursor 翻页并有页数上限，别假设一次返回全量。

### 观看数据与 WebDAV 同步

- `data/local/watch_store.dart`：历史 / 收藏共用的一份 SharedPreferences JSON。`WatchSnapshot`
  **刻意不持久化完整 `Drama`**：真实封面 URL 带签名会过期，只存 `coverColorsSeed`，展示时用
  `mappers.paletteFor` 重建三色渐变；rating / viewers 等易变字段不存。SharedPreferences 不可用时
  自动降级为内存实现（测试环境），此时 `watch_providers.dart` 会播种 demo 数据。
- `providers/watch_providers.dart`：`historyProvider` / `favoritesProvider` /
  `continueWatchingProvider`，三者由同一 store 派生，收藏态天然联动。
- `services/watch_sync_service.dart` + `providers/sync_providers.dart`：WebDAV 同步。
  `WebDavSyncController` 由 `AppShell` 常驻 `watch`（启动即挂监听与每日检查），
  自动同步有 15s debounce、最小间隔、失败 15 分钟冷却——播放中每 5 秒写进度，
  去掉这些限流会打满 WebDAV 请求额度。

### 播放器

`lib/screens/player_screen.dart`（约 2.7k 行）承载 UI；平台相关的渲染决断集中在
`lib/player/video_output.dart`，改动前务必读该文件的注释：

- Android 用 `vo=mediacodec_embed` + `hwdec=mediacodec`（模拟器上 gpu 无法创建 GL 上下文会全黑）；
- 桌面必须用 `texture`（media_kit 默认 `vo=libmpv` 纹理管线）——桌面上显式 `vo=gpu` 会弹出
  mpv 独立原生窗口，视频不进 Flutter widget；
- 拉流必须带 `kCdnUserAgent`（官方客户端 UA），否则 CDN 会拒绝 / 掐断。

### UI 与主题

- 颜色一律走 `lib/theme/app_colors.dart` 的语义令牌（`ThemeExtension`），用
  `context.colors` / `context.isDark` 取值，**不要写死颜色**。
- `screens/app_shell.dart` 是壳：宽 ≥ 720 用左侧导航栏，否则底部导航；`IndexedStack` 保活五个主 Tab。
- 文案中文，标识符英文；平台在文字与注释中统称「水果」，不直接点名。
- 下载页、会员页目前是 UI 壳 / Mock 展示，不代表已接入真实能力。

## 更新与发版（摘要，详见 AGENTS.md）

- 应用内更新先读 `api.github.com/repos/Sxuan-Coder/open-apex-drama/releases/latest`；失败
  （403/网络）时读 `updates.json` 的国内镜像（xget → jsDelivr → raw），再按发布命名
  拼资产地址（`services/update_manifest.dart`）。启动后后台测速三个下载镜像
  （512KB 探针，结果缓存 6 小时），下载按实测顺序从快到慢尝试；默认 gh-proxy →
  xget → ghfast.top → 官方直链。仓库标识同时硬编码在
  `app_state/project_info.dart`，改仓库需两处同步。
- `update_service` 按文件名筛选 Release 资产：`ApexDrama-v<ver>-arm64-v8a.apk`、
  `-armeabi-v7a.apk`、`ApexDrama-<ver>-windows-x64-setup.exe`、`-windows-x64.zip`。命名不符会回退到 Release 页面。
- 版本号只认 tag：`buildNumber = major*100 + minor*10 + patch`，patch 为单数字；
  发版用 `tool/bump_version.ps1`，不要手改。
- 发版前必须在 `updates.json` 补该版本条目（`notes` 是 Markdown），缺失会让发布脚本直接失败。
- `--split-per-abi` 会让 versionCode 加 ABI 偏移（arm64 → +2000），属正常现象，不要为对齐码值改发通用包。
- 正式包必须用固定 release keystore（`android/key.properties`，仓库外保存）；绝不能用 debug 签名发版。
  升级失败先查签名一致性，再看 versionCode。
- 不要把 `USE_MOCK=true` 的包给用户验收。

## 测试

测试全在 `test/`，无 mock 框架，靠自建 stub / 内存实现：

- Widget 测试用 `ProviderScope(overrides: [...])` 注入 Mock 仓库（`mock_repositories.dart`），
  并 `SharedPreferences.setMockInitialValues({})`。
- `test/ui_layout_check_test.dart` 是大范围布局回归测试，会逐个 pump 所有主界面；
  改共享 widget 或主题后应跑它。
- 涉及播放 / 平台的测试需要注意 `defaultTargetPlatform` 在 widget 测试中默认是 Android。
