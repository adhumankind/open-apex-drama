# 红果-阿帝版（iOS）最终可执行优化任务清单（REVIEW_TODO）

> **当前分支**：`opt/review-fixes`（本地存档基线：`924e7f8`，本地代码基线：`95d93f5`）  
> **上游同步基准**：本地旧基线 `7478c6b` → 上游远程最新 HEAD `3470910`（`Sxuan-Coder/open-apex-drama`）  
> **状态**：已与项目负责人完成目标对齐，**剔除所有不符合目标的建议，可直接按序交由执行模型落地**。

---

## 0. 已对齐的核心目标与硬约束（执行前必读）

1. **执行顺序（1A）**：**先拉齐上游最新代码并完成 iOS 扩展低冲突解耦**，再在新基线上一次性落地双保险投屏、播放器交互打磨、新图标与更新源，最后云端构建出包验收，避免先改后合并导致二次返工。
2. **投屏策略（2A 双保险）**：彻底修通 **DLNA（支持手机端进度条拖拽）**，并同步集成 **iOS 原生 AirPlay 路由按钮（`AVRoutePickerView`）**（小米电视与爱奇艺电视果均原生支持 AirPlay）。
3. **升级减负策略（回应“免繁琐重签安装”诉求）**：
   - *技术边界说明*：Flutter iOS Release 为全量 AOT 机器码且受苹果沙盒签名校验限制，无法通过“内嵌 Web 页面”方式直接热更原生 Dart 页面及 Go 内核。
   - *最终落地路径*：
     - **P0 立刻落地（零额外账号门槛、连 Go SDK 原生协议更新也能一键升级）**：CI 构建完成后自动发个人 Fork Release 并生成标准 **AltSource / 轻松签 / Feather / 巨魔通用软件源 JSON（`apps.json`）**。手机端签名工具添加一次源地址，后续上游更新点一下即自动拉包+重签+覆盖安装，告别电脑打包传包；
     - **P2 可选进阶**：接入 **Shorebird Code Push**，实现纯 Dart 层 UI/逻辑静默热更（无需重签 IPA，但 Go 原生 SDK 协议变动仍需走软件源一键升级）。
4. **交互偏好（4B 抖音/红果原生手感）**：**单击画面直接播放/暂停**（暂停时常显控件，播放中 3 秒无操作自动收起控件）+ 左侧防误触锁屏键；**不要**改回“单击仅显隐控件 + 底部放暂停键”。
5. **新 App Icon 审美标准**：废弃旧版纯红方块，采用 **「红宝石 + 红樱桃 + 视频播放三角」组合的高定满版贴边图标**（严格 Full-Bleed，严禁出现摄影棚地面、桌子、阴影场景或白边）。
6. **不可触碰红线**：
   - **保留原 Bundle ID (`com.apex.apexduanju`)**：严禁随意更改，确保用户覆盖安装不丢失历史观看记录与收藏；
   - **保留软件名称「红果-阿帝版」**及 WebDAV 同步文件结构兼容；
   - **严禁删除工作区中无关的外部保留文件**（`worker_index.js`、`huangguo-frontend.zip`）；
   - 本地环境为 Windows，无 macOS/Xcode，iOS 构建统一通过推送 GitHub Actions `build_ios.yml` 完成。

---

## 1. P0 任务清单（立刻执行 / 阻塞级修复与核心架构解耦）

### [x] P0-1：拉齐上游最新代码（`3470910`）+ iOS 定制低冲突解耦改造
- **背景与痛点**：`git diff --stat upstream/master..HEAD` 显示自制改动直接侵入 `player_screen.dart` 达 635 行、`player_actions_sheet.dart` 222 行、`.github/workflows/release.yml` 50 行，而上游高频修改播放器与弹幕模块，导致无法跟随上游更新。
- **改动目标**：
  1. 将 iOS 专属扩展（DLNA 投屏调度、锁屏状态机、方向旋转、跳过片头片尾、边缘手势、剧终提示）抽离至独立目录 `lib/ios_ext/`（例如 `player_ios_ext.dart`、`ios_overlays.dart`）；
  2. 执行 `git fetch upstream` 并将上游最新 `master`（`3470910`）合并至 `opt/review-fixes`，确保上游原文件 `lib/screens/player_screen.dart` 与 `lib/widgets/player_actions_sheet.dart` 内的侵入点控制在 **≤25 行薄钩子**；
  3. 还原 `.github/workflows/release.yml` 与 `assets/images/logo.png` 与上游一致，iOS 专属 Logo 改用独立路径 `assets/images/ios_logo.png`；
  4. 新增 `.github/workflows/sync_upstream.yml`（支持定时/手动触发），自动拉取 `Sxuan-Coder/open-apex-drama:master` 创建同步 PR 并在合并后自动触发 iOS 构建。
- **涉及文件**：
  - 新建：`lib/ios_ext/`、`.github/workflows/sync_upstream.yml`
  - 修改/瘦身：`lib/screens/player_screen.dart`、`lib/widgets/player_actions_sheet.dart`、`.github/workflows/release.yml`、`pubspec.yaml`
- **验收标准**：成功合入上游最新提交并保持 `flutter analyze` 0 error；`git diff upstream/master -- lib/screens/player_screen.dart` 净改动行数大幅收敛至极薄钩子。

### [ ] P0-2：彻底修通双保险投屏（重构 DLNA 引擎五连杀 Bug + 集成 iOS 原生 AirPlay）
- **实测根因定位**：
  1. `dlna_manager.dart:204-215` 一次性并发 `254×5=1,270` 个 Socket，瞬间打爆 iOS 256 FD 软上限（`EMFILE`）；
  2. `dlna_manager.dart:160-176` 假预热未发包无法弹 iOS 本地网络授权；`187-196` 网卡选择未优先 `en0` 易误扫 VPN/蜂窝网段；`220` 写死 `/description.xml` 漏掉小米电视常见路径；
  3. `dlna_manager.dart:386` 与 `606-618` 对 DIDL-Lite 做了**双重 XML 转义**（`&amp;lt;DIDL-Lite`）；
  4. `dlna_manager.dart:583-599` `_sendSoapAction()` 未检查 HTTP 200 和 `<s:Fault>` 假装成功；
  5. `video_output.dart:9-11` 显示视频 CDN 严格校验 `kCdnUserAgent`（否则拒连或 3 秒断流），且 `player_screen.dart:771-776` 存在 CENC 加密流（`bundle.hasKey`），直接把原始 URL 投给电视必然拉流失败。
- **改动目标**：
  1. **修复协议与校验**：`_buildDidl()` 返回原生 XML 仅在 `<CurrentURIMetaData>` 外层转义一次；`_sendSoapAction()` 严检 `statusCode == 200` 且无 `<s:Fault>`，失败时抛出具体错误码并回滚状态；
  2. **重写安全扫描引擎**：优先绑定 Wi-Fi 网卡 `en0`；主动扫描改为**最大并发 24 的队列池**杜绝 FD 耗尽；开搜前向网关 `.1` 发送真实探针触发 iOS 本地网络权限弹窗；支持多组描述路径探测（`/description.xml`、`/dlna/Render/dmr.xml`、`/dmr.xml`、`/description/fetch`、`/rootDesc.xml`）；
  3. **新增本机 HTTP 反向代理（解决 CDN 防盗链）+ 加密流处理**：新建 `lib/services/dlna/dlna_stream_proxy.dart`，在手机 Wi-Fi IP 启动本地 `HttpServer`，把 `http://<iphone_ip>:<port>/stream.mp4` 投给电视，代理收到电视 `GET`/`Range` 请求时注入 `kCdnUserAgent` 透传拉流；遇到 `bundle.hasKey == true` 时自动降级选用 `bundle.streams` 中未加密档位，全加密时明确 Toast 提示而非假播；
  4. **集成 iOS 原生 AirPlay（双保险）**：在 `ios/Runner/` 通过 `FlutterPlatformView` 桥接原生 `AVRoutePickerView`，在 `dlna_sheet.dart` 顶部显著位置提供「AirPlay 投屏」按钮；同时修复 `dlna_sheet.dart` 关闭时不 `stopDiscovery()`、搜索结束仍显示“正在搜索...”的 Bug，增加**手动输入电视 IP:端口**与**本地网络权限引导**；
  5. 在 `ios/Runner/Info.plist` 中补齐 `NSBonjourServices` 声明。
- **涉及文件**：
  - `lib/services/dlna/dlna_manager.dart`
  - 新建：`lib/services/dlna/dlna_stream_proxy.dart`
  - `lib/widgets/dlna_sheet.dart`
  - `ios/Runner/AppDelegate.swift` + 新建 `ios/Runner/AirPlayPickerView.swift`
  - `ios/Runner/Info.plist`
  - `lib/ios_ext/`（投屏调度处）
- **验收标准**：真机无 FD 耗尽报错，稳定发现爱奇艺电视果与小米电视，投屏后画面持续播放不断流且拖动进度条（Seek）正常响应，AirPlay 路由面板可正常唤起系统设备列表。

### [ ] P0-3：修复播放器布局崩坏 + 落实 4B 单击播/停手感 + 消灭手势穿透与流泄漏
- **实测根因定位**：
  - `player_screen.dart:1871-1875` `isWide = _isFullscreen || orientation == landscape` 导致竖屏短剧点全屏后被误判为桌面宽屏，底部塞进 9 控件溢出、右侧栏变成桌面分支（冒出空壳分享按钮）、竖向滑动手势全部失效；
  - `player_screen.dart:3097-3190` `_ActionRail` 未包滚动容器，iPhone 横屏（390px 高度）必然纵向溢出；
  - `player_screen.dart:2454` `CastRemoteOverlay` 位于最外层 `GestureDetector`/`Listener` 内部，操作遥控器会穿透触发本地播放器导致手机与电视双声道回声；
  - `player_screen.dart:2431-2435` 提示胶囊所有状态全都硬编码显示 `Icons.forward_5_rounded`；
  - `player_screen.dart:518-522` `player.stream.log.listen` 订阅未保存与释放导致切清晰度内存泄漏。
- **改动目标**：
  1. **解耦全屏与宽屏布局**：`isWideLayout` 仅由 `orientation == Orientation.landscape || Platform.isWindows` 决定；竖屏全屏保持 `compactControls = true` 紧凑布局（仅隐藏系统状态栏与手势条）；
  2. **落实 4B 手感**：移动端单击画面直接切换播放/暂停（暂停时常显控件，播放中 3 秒自动隐藏）；去除因 `onDoubleTap` 引发的单击延迟卡顿感或合理划分区域；暂停时中央半透明播放图标响应点击续播；
  3. **防溢出与防穿透**：`_ActionRail` 外包 `ConstrainedBox` + `SingleChildScrollView`；将 `CastRemoteOverlay` 移到最外层手势拦截之外作为顶层 `Stack` 子节点；
  4. **修细节与泄漏**：中央提示胶囊改用 `(IconData, String)` 按场景正确展示图标（锁屏/旋转/音量/亮度/跳过片头）；保存并在 `dispose()`/重建时取消 `player.stream.log` 订阅；删除 `_handleCastTap()`（行 274-288）的重复分支。
- **涉及文件**：
  - `lib/screens/player_screen.dart`、`lib/ios_ext/player_ios_ext.dart`
- **验收标准**：竖屏全屏与横屏播放均零 `RenderFlex overflow`；单击即时播/停；播放 3 秒控件自动隐藏；投屏时操作遥控器绝不唤醒手机本地声音。

### [ ] P0-4：重做「红宝石 + 红樱桃 + 视频播放」满版高定 App Icon
- **改动目标**：
  1. 生成 1024×1024 纯净满版（Full-Bleed，无任何摄影棚地面、白边或外部背景环境）的「红宝石 + 红樱桃 + 视频播放三角」组合图标母版（RGB 无 Alpha 通道）；
  2. 通过 `tool/generate_ios_icons.py` 全套切片覆盖 `ios/Runner/Assets.xcassets/AppIcon.appiconset/` 全部 16 档分辨率，并同步输出至 `assets/images/ios_logo.png`。
- **涉及文件**：
  - `ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png`
  - `assets/images/ios_logo.png`、`tool/generate_ios_icons.py`
- **验收标准**：iPhone 桌面图标辨识度高、满版无黑边/白边、视觉融合红宝石质感 + 樱桃造型 + 播放符号。

### [ ] P0-5：修复 iOS 更新器误下 APK + 锁定 CI 内核版本 + 自动生成自签一键更新源（`apps.json`）
- **实测根因定位**：
  - `update_service.dart:337-344` 未区分 iOS，上游发版后 iOS 启动强制弹窗下载 Android `.apk`；
  - `.github/workflows/build_ios.yml:38-40` 直接 clone `openhongguo` 最新 `main` 覆盖 `pubspec.yaml:23` 锁定的 `ecbd85e`，存在 ABI 漂移崩溃隐患；
  - 每次发版需手动去 Actions 下载 Artifact 再传手机重签，流程繁琐。
- **改动目标**：
  1. **CI 锁定内核 ref**：`build_ios.yml` 自动解析 `pubspec.yaml` 中 `openhongguo` 的 `ref` 并 `git checkout $REF` 后编译 `OpenhongguoCore.xcframework`；
  2. **CI 自动发 Fork Release + 自动更新软件源 `apps.json`**：构建成功后自动将 `HongGuo-AdiBan.ipa` 发布到 `adhumankind/open-apex-drama` 的 GitHub Release，并自动生成/更新兼容 AltStore / SideStore / Feather / 轻松签 / 巨魔的软件源清单 `apps.json`（保留 Bundle ID `com.apex.apexduanju`），方便用户手机签名工具一键拉取更新；
  3. **修复 iOS 应用内更新逻辑**：`UpdateService` 增加 `Platform.isIOS` 分支，改为检测 `adhumankind/open-apex-drama` 最新 Release 匹配 `.ipa` 资产，点击后跳转下载页或复制软件源地址/唤起安装器，彻底禁止 iOS 下载 `.apk`。
- **涉及文件**：
  - `.github/workflows/build_ios.yml`
  - `lib/services/update_service.dart`、`lib/services/update_prompt.dart`
- **验收标准**：CI 自动产出 Fork Release 与 `apps.json` 源；iOS 应用内检查更新准确识别 IPA 版本且不再尝试打开 APK。

---

## 2. P1 任务清单（短期体验打磨与稳定性加固）

### [ ] P1-1：iOS 真机系统亮度/音量调节 + 横屏边缘手势优化 + 锁屏零遮挡
- **改动目标**：
  1. 在 `ios/Runner/` 添加轻量 Swift MethodChannel 调用 `UIScreen.main.brightness` 替换当前“半透明黑色遮罩”假亮度（支持双向调亮/调暗，退出播放页自动恢复系统原亮度）；
  2. 放开横屏模式下的边缘滑动调节亮度/音量，左边缘触发区调整为屏幕宽 `8%~28%` 避开 iOS `CupertinoPageTransitionsBuilder` 最左缘侧滑返回冲突；
  3. 锁屏 2.5 秒后锁图标 `opacity` 彻底降为 `0`（完全透明零遮挡），轻点屏幕任意位置短暂浮现 2.5 秒供点击解锁。
- **涉及文件**：
  - `ios/Runner/AppDelegate.swift`（或新建 `ios/Runner/ScreenControlPlugin.swift`）
  - `lib/ios_ext/player_ios_ext.dart`
- **验收标准**：横竖屏均可平滑调节真机物理亮度与音量，不与系统侧滑返回打架，锁屏无残留图标遮挡画面。

### [ ] P1-2：播放解析缓存 TTL 失效 + 解析日志异步轮转
- **改动目标**：
  1. `SdkPlaybackRepository._cache`（`sdk_repositories.dart:322,387-402`）改为带时间戳的缓存项（15 分钟 TTL，上限 100 条），新增 `invalidate(episodeId)` 方法并在开流报 403/过期错误时清缓存重解；
  2. `_logResolve`（`sdk_repositories.dart:462-474`）改为异步写入并在文件超 512KB 时自动轮转截断，消除主线程同步磁盘 I/O 阻塞。
- **涉及文件**：
  - `lib/data/repository/sdk_repositories.dart`、`lib/screens/player_screen.dart`
- **验收标准**：长时间暂停后恢复播放或回看旧集自动刷新过期链接，不出现必须杀后台才能播放的死链现象。

---

## 3. P2 任务清单（长期演进 / 进阶能力）

### [ ] P2-1：补齐 iOS 锁屏媒体控制中心（`MPNowPlayingInfoCenter`）
- **改动目标**：利用 `Info.plist` 已开启的 `UIBackgroundModes: audio`，接入 iOS 锁屏/灵动岛媒体信息展示（剧名、集数、封面）与上一集/下一集/播放暂停线控指令。
- **涉及文件**：`ios/Runner/` 原生音频会话桥接、`lib/ios_ext/`。

### [ ] P2-2：接入 Shorebird Code Push（纯 Dart 改动免签静默热更）
- **改动目标**：待用户确认注册 Shorebird 账号并配置 `SHOREBIRD_TOKEN` Secret 后，在 `build_ios.yml` 集成 `shorebird release ios` 与 `shorebird patch ios`，使后续纯 Dart UI/交互微调无需重签 IPA 即可静默生效（原生 Go SDK 升级仍自动走 P0-5 软件源一键覆盖）。
- **涉及文件**：`.github/workflows/build_ios.yml`、`shorebird.yaml`（新建）。

### [ ] P2-3：WebDAV 同步凭据迁移至 iOS Keychain
- **改动目标**：将 `webdav.password.v1` 从明文 `SharedPreferences`（`lib/services/webdav_sync_settings.dart:61`）迁移至 iOS Keychain（支持无感迁移老配置），消除明文凭据落盘风险。
- **涉及文件**：`lib/services/webdav_sync_settings.dart`、`pubspec.yaml`。
