# AGENTS.md

本文件是本仓库的协作与发版约定，任何自动化 Agent 动手前必须先读。

## 仓库定位（关键）

`Sxuan-Coder/open-apex-drama` 是**唯一主仓**：代码、文档、tag、CI 与 Release 全部在这里完成。

- 应用内更新读取 `api.github.com/repos/Sxuan-Coder/open-apex-drama/releases/latest`
  （见 `lib/services/update_service.dart`），**发版必须发在本仓 Release**。
- 历史私有仓已归档，不再接收代码，也不要再往它发 Release——发错仓库用户收不到更新。

## 版本号规则

```
pubspec.yaml: version: <major>.<minor>.<patch>+<buildNumber>
buildNumber = major*100 + minor*10 + patch      # 1.1.2 -> 112
```

- patch 固定一位数（0–9），满 9 自动进位到 minor：`1.1.9 -> 1.2.0`
- 用 `tool/bump_version.ps1` 自增，不要手改：
  ```
  powershell -ExecutionPolicy Bypass -File tool\bump_version.ps1        # patch+1
  powershell -ExecutionPolicy Bypass -File tool\bump_version.ps1 -Version 1.2.0
  ```
- 该脚本拒绝两位 patch（防止 `1.2.10` 与 `1.3.0` 撞号）

### 注意：分 ABI 打包会加偏移

`flutter build apk --split-per-abi` 会让 APK 的实际 versionCode 变成
`1000*ABI + 基础码`（arm64 → 2112）。这是历史约定，正常现象。

**不要**为了"码值正好等于版本数字"改发通用 APK：
通用包码值 112 低于已安装分 ABI 包的 2000+/4000+，会被判定降级装不上；
而且通用包 117MB（打进了全 ABI 的 libmpv）。

## 发布标题与更新说明

- Release 标题固定格式：`ApexDrama vx.y.z`（x.y.z 取自 tag，不带 `+构建号`）
- 更新说明统一维护在根目录 **`updates.json`**，按版本号索引，`notes` 字段是
  **Markdown 字符串**（含标题/列表/加粗等全部原样渲染到 Release 正文）

```json
{
  "1.1.2": {
    "date": "2026-11-10",
    "notes": "## 本次更新\n\n**手机端控制栏修复**\n\n- 倍速/选集/收藏移到右侧"
  }
}
```

发版前必须在 `updates.json` 补上该版本条目，否则自动发版会直接失败
（脚本检查到缺条目就 `sys.exit`）。

## 产物命名约定

| 平台 | 文件名 |
|---|---|
| Android arm64 | `ApexDrama-v<ver>-arm64-v8a.apk` |
| Android armv7 | `ApexDrama-v<ver>-armeabi-v7a.apk` |
| Windows 安装器 | `ApexDrama-<ver>-windows-x64-setup.exe` |
| Windows 便携版 | `ApexDrama-<ver>-windows-x64.zip` |
| iOS（未签名，未测试） | `ApexDrama-<ver>_ios_unsigned.ipa` |

APK 带 `v` 前缀，Windows 包不带。命名必须包含 `arm64-v8a` / `windows-x64`，
否则 `update_service.dart` 的资产筛选挑不到（会回退到 Release 页面）。

iOS 包以下划线连接版本号，且没有 `v` 前缀：`update_service.dart` 只认
`.apk` 与含 `windows-x64` 的 zip/msix/exe，`.ipa` 不会被误选。该包**未签名**
（只能 AltStore / SideStore / Sideloadly 自签安装）且**未经真机验证**，
发版说明由 `release.yml` 固定追加「iOS（未测试）」一节，不要删掉。

## 发版流程

推荐直接走 CI：推送 `v*.*.*` tag 即自动构建并发布到本仓 Release。

```bash
# 1. 自增版本号
powershell -ExecutionPolicy Bypass -File tool\bump_version.ps1

# 2. 提交并打 tag
git add -A && git commit -m "chore: 发版 v<ver>（<摘要>）"
git tag -a v<ver> -m "ApexDrama v<ver>"
git push origin HEAD:master && git push origin v<ver>
```

需要本地兜底构建时：

```bash
# 干净构建（工作区有并行未提交改动时必须用 worktree 隔离）
git worktree add ../_release_v<ver> v<ver>
cd ../_release_v<ver> && flutter pub get
flutter build apk --release --split-per-abi
powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
```

手动发布（仅 CI 不可用时）：

```bash
gh release create v<ver> -R Sxuan-Coder/open-apex-drama \
  --title "ApexDrama v<ver>" --notes-file <说明.md> --target master \
  "dist/ApexDrama-v<ver>-arm64-v8a.apk" \
  "dist/ApexDrama-v<ver>-armeabi-v7a.apk" \
  "dist/ApexDrama-<ver>-windows-x64-setup.exe" \
  "dist/ApexDrama-<ver>-windows-x64.zip" \
  "dist/ApexDrama-<ver>_ios_unsigned.ipa"

# 校验
gh api repos/Sxuan-Coder/open-apex-drama/releases/latest --jq '.tag_name, .name'
```

## 分支与 PR 门禁

- **改动超过 400 行必须走 PR**：单次改动（`git diff --stat` 的新增 + 删除行数合计）超过
  400 行时，禁止直接推 `master`，必须新建分支 → 提 PR → CI 全绿 → 合并。
- **大功能必须单一分支开发**：跨模块、涉及多个文件或需要多次提交的功能改动，新建
  `feat/` / `fix/` / `refactor/` 开头的独立分支完成，全部改动收在该分支上，合并后先把
  本地 `master` 对齐 `origin/master` 再开下一个分支；不允许长期并行的多条功能分支
  同时改同一批文件。
- **合并方式用 merge commit，不用 squash**：项目初期保留分支历史，便于回溯每条改动
  的完整提交序列；`gh pr merge <n> --merge --delete-branch`。
- PR 标题沿用 `<type>(scope): <summary>`，描述写清改动内容、验证方式与风险点。

## 其他约束

- **签名（重要）**：正式包使用固定 release keystore，**绝不能再用 debug 签名**——
  GitHub Actions runner 每次生成的 debug.keystore 都不同，会导致 APK 之间无法覆盖升级
  （v1.2.0 之前的历史版本即因此失败）。
  - keystore 存放在**仓库外**的本地密钥目录，例如 `<本地密钥目录>/apex-release.jks`
    （alias `apex`，密码与证书指纹离线备份；丢失后所有已安装用户都无法再覆盖升级）
  - 本地：`android/key.properties`（已 gitignore）指向该文件
  - CI：Secrets `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` /
    `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`，release.yml 构建前还原；
    缺 secret 时 Android job 直接报错退出，**不允许**回退临时签名
  - `android/key.properties` 的 keystore 路径若含非 ASCII 字符：Gradle 必须用
    `InputStreamReader(FileInputStream(file), Charsets.UTF_8)` 读取。
    Java `Properties.load(InputStream)` 默认按 ISO-8859-1 解码，会读出乱码。
  - 校验签名（必须是 `CN=ApexDrama`，出现 `CN=Android Debug` 说明签名配置没生效）：
    ```bash
    apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
    ```
  - **切换签名的一次性代价**：v1.2.0 及更早版本用户升级到 v1.2.1+ 需卸载重装一次
    （旧 APK 的 debug 签名私钥随 CI runner 销毁，无法找回）；重装后通过 WebDAV
    同步可恢复收藏与观看记录。
- **Inno Setup**：`tool/package_windows.ps1` 在常见安装路径与可选的本机工具目录中
  查找 ISCC，缺失时只出 zip 不出 setup.exe；CI 用 `choco install innosetup`。
- **产物归档**：本地 `dist/` 已入 gitignore，构建产物另存一份留档。
- **SDK 原生库**：`openhongguo` 通过 git 依赖引用自维护 fork（含预编译
  `libgojni.so` / `core.jar` / `openhongguo.dll`）。上游发版不及时时，只要上游
  `main` 已含修复，就由我们在 fork 中从源码重建、升插件版本并更新 `pubspec.yaml`
  的 `ref`，不等上游 release；步骤见 fork 内 `windows/BUILD_DLL.md`。

## 自动发版（GitHub Actions）

`.github/workflows/release.yml`：推送 `v*.*.*` tag 即触发，全自动构建并发布到
**本仓库** Release，无需本地打包。

流程：

1. `android`（ubuntu）：从 tag 解析 `x.y.z`，按 `major*100+minor*10+patch` 回填
   `pubspec.yaml` 版本 → `flutter build apk --release --split-per-abi`
2. `windows`（windows-latest）：同样回填版本 → `choco install innosetup` →
   `tool/package_windows.ps1` 出 zip + setup.exe
3. `publish`（ubuntu）：下载两个 job 的产物 → 从 `updates.json` 取该版本 `notes`
   写成 NOTES.md → `gh release create` 到本仓库，标题 `ApexDrama vx.y.z`

**权限要求**：`publish` job 使用仓库默认 `GITHUB_TOKEN`，需 `contents: write`
（已在 workflow 中声明）。不再需要跨仓 PAT。

常见失败：

| 现象 | 原因 | 处理 |
|---|---|---|
| 403 `Resource not accessible by integration` | job 缺少 `contents: write` | 检查 `publish.permissions` |
| Android job 报缺少签名 Secrets | 4 个 `ANDROID_*` 未配置 | 在仓库 Settings → Secrets 补齐 4 项 |

`publish` 失败不影响已构建产物，可本地兜底发布：

```bash
RUN=<run-id>
gh run download $RUN -n android -D /tmp/rel
gh run download $RUN -n windows -D /tmp/rel
# 用 updates.json 的 notes 生成 NOTES.md 后：
gh release create v<ver> -R Sxuan-Coder/open-apex-drama \
  --title "ApexDrama v<ver>" --notes-file NOTES.md --target master \
  /tmp/rel/ApexDrama-v<ver>-arm64-v8a.apk \
  /tmp/rel/ApexDrama-v<ver>-armeabi-v7a.apk \
  /tmp/rel/ApexDrama-<ver>-windows-x64-setup.exe \
  /tmp/rel/ApexDrama-<ver>-windows-x64.zip
```

## 发版踩坑（跨会话必看）

1. **版本号只认 tag**：CI 会用 tag 覆写 `pubspec.yaml` 的 version，本地手改不会改变
   Release 版本；tag 必须 `vx.y.z`（单数字 patch）。tag 推送后**不要移动/重打**，
   需要修正就发新版本。
2. **升级失败先看签名再看版本号**：`INSTALL_FAILED_UPDATE_INCOMPATIBLE` 几乎都是
   签名证书不一致（用上面的 `apksigner` 对比两个 APK 的 SHA-256）。versionCode
   在分 ABI 后会加 2000/1000 偏移，单纯比大小容易误判。
3. **v1.2.0 及更早的 Release 全部是临时 debug 签名**（每次 CI runner 重新生成），
   彼此不能覆盖安装；v1.2.1 起才统一为固定 keystore。不要把旧版的"能升级"当作先例。
4. **不要给用户装 `--dart-define=USE_MOCK=true` 的包验收**：全站内容都会是 mock
   短剧，会被误认为数据/同步出问题；发版构建不带该 define。
5. **发版前必须写 `updates.json`**：缺条目 CI 会直接失败；publish 用它的 `notes`
   作为 Release 正文。
6. **本地 release 构建**：`android/key.properties` 存在即用正式签名；不存在会回退
   debug，仅限开发，不要拿来发版。

注意：

- 用自动发版时**不要**再手工执行 `gh release create`，否则重复发布
- `gh release create` 不会覆盖已存在的 tag 发布；重跑前需先删掉该版本 Release
- 本地 `tool/bump_version.ps1` 仍可用于开发期改动版本号；CI 会以 tag 为准覆盖
- Android 构建需要联网下载 media_kit 的 4 个 libmpv jar，GitHub runner 可直连；
  若日后网络受限，需改用 Actions cache 预置
