# ApexDrama

第三方短剧客户端，非官方、免登录、免费使用。

[![Android](https://img.shields.io/badge/Android-下载_APK-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Sxuan-Coder/open-apex-drama/releases/latest)
[![Windows](https://img.shields.io/badge/Windows-下载-0078D4?style=for-the-badge&logo=windows11&logoColor=white)](https://github.com/Sxuan-Coder/open-apex-drama/releases/latest)
[![License](https://img.shields.io/badge/License-AGPL_v3-blue?style=for-the-badge)](https://www.gnu.org/licenses/agpl-3.0)
[![官网](https://img.shields.io/badge/官网-apexdrama.sxapex.com-FF6B9D?style=for-the-badge&logo=googlechrome&logoColor=white)](https://apexdrama.sxapex.com)

*前两个徽标跳转最新版本下载*

## 截图

### 移动端

<table>
  <tr><th>首页</th><th>看剧</th><th>详情</th><th>播放页</th><th>榜单</th></tr>
  <tr>
    <td><img src="docs/screenshots/mobile-home.jpg" width="140"></td>
    <td><img src="docs/screenshots/mobile-watch.jpg" width="140"></td>
    <td><img src="docs/screenshots/mobile-detail.jpg" width="140"></td>
    <td><img src="docs/screenshots/mobile-player.jpg" width="140"></td>
    <td><img src="docs/screenshots/mobile-rank.jpg" width="140"></td>
  </tr>
</table>

### 桌面端（Windows）

<table>
  <tr><th>首页</th><th>播放页</th></tr>
  <tr>
    <td><img src="docs/screenshots/desktop-home.jpg" width="400"></td>
    <td><img src="docs/screenshots/desktop-player.jpg" width="400"></td>
  </tr>
  <tr><th>详情</th><th>榜单</th></tr>
  <tr>
    <td><img src="docs/screenshots/desktop-detail.jpg" width="400"></td>
    <td><img src="docs/screenshots/desktop-rank.jpg" width="400"></td>
  </tr>
</table>

## 功能

- 首页 / 搜索 / 分类 / 榜单，真实数据
- 加密流解密播放：清晰度切换、倍速、选集、自动连播、进度续播
- 追剧 / 收藏 / 历史本地保存，支持 WebDAV 多设备同步
- 弹幕播放层与开关
- 深浅双主题
- Android 手机竖屏沉浸式体验；Windows 桌面版支持键鼠操作与窗口全屏

## 系统要求

- Android 7.0+
- Windows 10 / 11（x64）

## 从源码构建

```bash
flutter pub get
flutter run                            # 调试运行
flutter build apk --release --split-per-abi   # Android 安装包
flutter build windows                  # Windows 产物
powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1  # Windows 打包（zip + 安装器）
```

环境要求与签名配置见 [docs/build.md](docs/build.md)。

### SDK 说明

SDK 为水果平台短剧的非官方第三方库（Apache-2.0），通过 git 依赖引用自维护 fork
（含预编译原生库与最新播放协议修复），Android / iOS / Windows 源码构建均完整可用。

## 开源协议

本项目以 [GNU AGPL-3.0](LICENSE) 协议开源：可自由使用、修改、再分发；
闭源套壳或基于本项目的网络服务同样须开源修改后的源码。
第三方依赖中 `openhongguo` 为 Apache-2.0，其授权声明独立生效。

## 免责声明

本项目仅供学习研究，禁止商业用途与大规模采集。接口与内容版权归原平台所有，
使用风险自负，如触及版权方利益请联系删除。使用本项目同时表示你同意上游
[openhongguo 的使用声明](https://github.com/beilunyang/openhongguo#免责声明)。

## 致谢

- [openhongguo](https://github.com/beilunyang/openhongguo) — 水果平台短剧非官方 SDK（Apache-2.0）；
  通过 git 依赖引用自维护 fork [Sxuan-Coder/openhongguo](https://github.com/Sxuan-Coder/openhongguo)
  （含预编译原生库与 Windows 桥接）
- [media_kit](https://github.com/media-kit/media-kit) — mpv 内核播放器
- [Flutter](https://flutter.dev) / [Riverpod](https://riverpod.dev)
- [linux.do](https://linux.do/) — 开发者交流社区

---

如果这个项目对你有帮助，欢迎点个 Star ⭐
