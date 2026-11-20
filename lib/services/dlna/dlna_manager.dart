import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dlna_device.dart';

/// DLNA 投屏管理器单例。
///
/// 专为大屏生态（小米电视、爱奇艺电视果、华为智慧屏及各类机顶盒）设计：
/// 1. 【双模探测引擎】：
///    - 组播引擎：SSDP（UDP 239.255.255.250:1900）多轮广播（含 upnp:rootdevice 与 AVTransport:1）；
///    - 单播主动扫描兜底引擎：自动获取本机局域网子网，并发扫描电视果(39620)、小米/乐播(9999/8080/49152-49154)等端口，
///      彻底解决 AP 隔离与路由器组播丢包导致搜不到设备的痛点；
/// 2. 【多网卡与 iOS 本地网络激活】：开搜前预热本地连接，确保 iOS 弹出本地网络授权窗口；
/// 3. 【精准控制与 Seek 调节】：基于标准 AVTransport:1 实现播放、暂停、进度跳转（REL_TIME）与实时进度回传。
class DlnaManager {
  DlnaManager._();

  static final DlnaManager instance = DlnaManager._();

  /// 局域网已发现的投屏设备列表
  final ValueNotifier<List<DlnaDevice>> devicesNotifier =
      ValueNotifier<List<DlnaDevice>>(<DlnaDevice>[]);

  /// 当前正在投屏的目标设备（为 null 表示未在投屏）
  final ValueNotifier<DlnaDevice?> activeDeviceNotifier =
      ValueNotifier<DlnaDevice?>(null);

  /// 投屏状态
  final ValueNotifier<bool> isCastingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier<bool>(false);

  /// 投屏播放进度与总时长（与电视端实时同步）
  final ValueNotifier<Duration> castPositionNotifier =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> castDurationNotifier =
      ValueNotifier<Duration>(Duration.zero);

  /// 搜索状态
  final ValueNotifier<bool> isSearchingNotifier = ValueNotifier<bool>(false);

  RawDatagramSocket? _ssdpSocket;
  Timer? _searchTimeoutTimer;
  Timer? _searchIntervalTimer;
  Timer? _positionPollTimer;
  final Set<String> _discoveredLocations = <String>{};
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 2500);

  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;

  static const List<String> _searchTargets = <String>[
    'urn:schemas-upnp-org:service:AVTransport:1',
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'upnp:rootdevice',
    'ssdp:all',
  ];

  /// 启动局域网设备搜索（搜索小米电视、电视果等 DLNA 接收端）
  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 8)}) async {
    stopDiscovery();
    isSearchingNotifier.value = true;
    _discoveredLocations.clear();

    // 1. 本地网络权限预热（特别是 iOS 端，触发本地网络权限对话框）
    _warmupLocalNetwork();

    try {
      // 2. 绑定 SSDP UDP Socket
      _ssdpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: false,
      );
      _ssdpSocket?.broadcastEnabled = true;
      _ssdpSocket?.multicastHops = 4;
      try {
        _ssdpSocket?.joinMulticast(InternetAddress(_ssdpAddress));
      } catch (_) {}

      _ssdpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final Datagram? dg = _ssdpSocket?.receive();
          if (dg != null) {
            _handleSsdpPacket(dg);
          }
        }
      });

      // 立即发送第 1 轮 M-SEARCH 报文
      _sendAllMSearch();

      // 第 1.2 秒、第 2.5 秒重发，避免 Wi-Fi UDP 偶发丢包
      int round = 0;
      _searchIntervalTimer = Timer.periodic(const Duration(milliseconds: 1300), (Timer t) {
        round++;
        if (round >= 2) {
          t.cancel();
        } else {
          _sendAllMSearch();
        }
      });

      // 3. 局域网子网并发主动探测兜底（防路由器屏蔽 UDP 组播）
      unawaited(_probeSubnetActive());

      // 4. 超时自动结束
      _searchTimeoutTimer = Timer(timeout, stopDiscovery);
    } catch (e) {
      debugPrint('[DLNA] 启动搜索失败: $e');
      isSearchingNotifier.value = false;
    }
  }

  void _sendAllMSearch() {
    for (final String target in _searchTargets) {
      final String msg = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $target\r\n\r\n';
      try {
        final List<int> data = utf8.encode(msg);
        _ssdpSocket?.send(data, InternetAddress(_ssdpAddress), _ssdpPort);
      } catch (_) {}
    }
  }

  void _handleSsdpPacket(Datagram dg) {
    try {
      final String response = utf8.decode(dg.data, allowMalformed: true);
      String location = '';
      String myName = '';

      for (final String line in response.split(RegExp(r'\r?\n'))) {
        final int colon = line.indexOf(':');
        if (colon <= 0) continue;
        final String key = line.substring(0, colon).trim().toUpperCase();
        final String val = line.substring(colon + 1).trim();

        if (key == 'LOCATION') {
          location = val;
        } else if (key == 'MYNAME') {
          // 电视果专属头部字段：如 "电视果3(687)"
          myName = val;
        }
      }

      if (location.isNotEmpty && _discoveredLocations.add(location)) {
        _fetchDeviceDescription(location, hintName: myName);
      }
    } catch (_) {}
  }

  /// 预热本地网络（激发 iOS Local Network 权限）
  void _warmupLocalNetwork() {
    try {
      // 触发一次快速本地网络扫描动作促使系统授权
      NetworkInterface.list(type: InternetAddressType.IPv4).then((List<NetworkInterface> ifaces) {
        for (final NetworkInterface iface in ifaces) {
          for (final InternetAddress addr in iface.addresses) {
            if (!addr.isLoopback) {
              // 激活本地网络协议栈
              RawDatagramSocket.bind(addr, 0).then((RawDatagramSocket s) {
                s.close();
              }).catchError((_) {});
            }
          }
        }
      }).catchError((_) {});
    } catch (_) {}
  }

  /// 局域网主动单播探测兜底（针对电视果 39620、小米/小爱 9999/8080/49152）
  Future<void> _probeSubnetActive() async {
    try {
      final List<NetworkInterface> ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      String? localIp;
      for (final NetworkInterface iface in ifaces) {
        for (final InternetAddress addr in iface.addresses) {
          final String ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
            localIp = ip;
            break;
          }
        }
        if (localIp != null) break;
      }

      if (localIp == null) return;
      final int lastDot = localIp.lastIndexOf('.');
      if (lastDot <= 0) return;
      final String prefix = localIp.substring(0, lastDot + 1);

      // 常见大屏 DLNA 端口与描述路径
      const List<int> probePorts = <int>[39620, 9999, 8080, 49152, 49153];

      // 对常见候选设备 IP 发起并发快速探测
      final List<Future<void>> futures = <Future<void>>[];
      for (int i = 1; i <= 254; i++) {
        final String targetIp = '$prefix$i';
        for (final int port in probePorts) {
          futures.add(_probeCandidate(targetIp, port));
        }
      }

      await Future.wait(futures);
    } catch (_) {}
  }

  Future<void> _probeCandidate(String ip, int port) async {
    final String loc = 'http://$ip:$port/description.xml';
    if (_discoveredLocations.contains(loc)) return;

    try {
      final Socket socket = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 350));
      socket.destroy();
      // 端口开放！尝试拉取描述文件
      if (_discoveredLocations.add(loc)) {
        _fetchDeviceDescription(loc);
      }
    } catch (_) {}
  }

  Future<void> _fetchDeviceDescription(String location, {String hintName = ''}) async {
    try {
      final Uri uri = Uri.parse(location);
      final HttpClientRequest request = await _httpClient.getUrl(uri);
      request.headers.set('User-Agent', 'DLNADOC/1.50');
      final HttpClientResponse response = await request.close().timeout(
            const Duration(seconds: 3),
          );

      if (response.statusCode == 200) {
        final String xml = await response.transform(utf8.decoder).join();
        _parseDeviceXml(xml, location, uri, hintName: hintName);
      }
    } catch (_) {
      // 若获取失败但有友好名称（如电视果），以 location 构建基础设备
      if (hintName.isNotEmpty) {
        final Uri uri = Uri.parse(location);
        final String controlUrl = '${uri.scheme}://${uri.host}:${uri.port}/_urn:schemas-upnp-org:service:AVTransport_control';
        final DlnaDevice dev = DlnaDevice(
          id: location,
          name: hintName,
          location: location,
          controlUrl: controlUrl,
        );
        _addDevice(dev);
      }
    }
  }

  void _parseDeviceXml(String xml, String location, Uri baseUri, {String hintName = ''}) {
    // 1. 检查是否存在 URLBase
    String effectiveBase = '${baseUri.scheme}://${baseUri.host}:${baseUri.port}';
    final Match? urlBaseMatch = RegExp(r'<URLBase>([^<]+)</URLBase>', caseSensitive: false).firstMatch(xml);
    if (urlBaseMatch != null) {
      final String ub = urlBaseMatch.group(1)?.trim() ?? '';
      if (ub.isNotEmpty) {
        effectiveBase = ub.endsWith('/') ? ub.substring(0, ub.length - 1) : ub;
      }
    }

    // 2. 匹配 friendlyName
    String name = hintName;
    if (name.isEmpty) {
      final RegExp nameRegExp = RegExp(r'<friendlyName>([^<]+)</friendlyName>', caseSensitive: false);
      name = nameRegExp.firstMatch(xml)?.group(1)?.trim() ?? '';
    }
    if (name.isEmpty) name = '未知电视设备';

    // 3. 匹配 modelName / manufacturer / UDN
    final String model = RegExp(r'<modelName>([^<]+)</modelName>', caseSensitive: false).firstMatch(xml)?.group(1)?.trim() ?? '';
    final String manufacturer = RegExp(r'<manufacturer>([^<]+)</manufacturer>', caseSensitive: false).firstMatch(xml)?.group(1)?.trim() ?? '';
    final String udn = RegExp(r'<UDN>([^<]+)</UDN>', caseSensitive: false).firstMatch(xml)?.group(1)?.trim() ?? location;

    // 4. 解析 AVTransport 服务的 controlURL（遍历 service 标签）
    String? avControlPath;
    String? rcControlPath;

    final Iterable<Match> serviceMatches = RegExp(r'<service>([\s\S]*?)</service>', caseSensitive: false).allMatches(xml);
    for (final Match sm in serviceMatches) {
      final String sContent = sm.group(1) ?? '';
      final String sType = RegExp(r'<serviceType>([^<]+)</serviceType>', caseSensitive: false).firstMatch(sContent)?.group(1)?.trim() ?? '';
      final String cUrl = RegExp(r'<controlURL>([^<]+)</controlURL>', caseSensitive: false).firstMatch(sContent)?.group(1)?.trim() ?? '';

      if (sType.toLowerCase().contains('service:avtransport')) {
        avControlPath = cUrl;
      } else if (sType.toLowerCase().contains('service:renderingcontrol')) {
        rcControlPath = cUrl;
      }
    }

    // 兜底正则
    if (avControlPath == null) {
      final RegExp avRegExp = RegExp(
        r'<serviceType>[^<]*AVTransport[^<]*</serviceType>[\s\S]*?<controlURL>([^<]+)</controlURL>',
        caseSensitive: false,
      );
      avControlPath = avRegExp.firstMatch(xml)?.group(1)?.trim();
    }

    if (avControlPath == null) {
      // 过滤非可投屏媒体渲染设备（如单纯路由器/音箱未开启视频投屏）
      return;
    }

    final String controlUrl = _buildFullUrl(effectiveBase, avControlPath);
    final String? rcUrl = rcControlPath != null ? _buildFullUrl(effectiveBase, rcControlPath) : null;

    final DlnaDevice device = DlnaDevice(
      id: udn,
      name: name,
      location: location,
      controlUrl: controlUrl,
      renderingControlUrl: rcUrl,
      modelName: model,
      manufacturer: manufacturer,
    );

    _addDevice(device);
  }

  String _buildFullUrl(String base, String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    return '$base$path';
  }

  void _addDevice(DlnaDevice device) {
    final List<DlnaDevice> current = List<DlnaDevice>.from(devicesNotifier.value);
    final int idx = current.indexWhere((DlnaDevice d) => d.id == device.id || d.controlUrl == device.controlUrl);
    if (idx >= 0) {
      current[idx] = device;
    } else {
      current.add(device);
    }
    devicesNotifier.value = current;
  }

  /// 停止搜索
  void stopDiscovery() {
    _searchTimeoutTimer?.cancel();
    _searchTimeoutTimer = null;
    _searchIntervalTimer?.cancel();
    _searchIntervalTimer = null;
    _ssdpSocket?.close();
    _ssdpSocket = null;
    isSearchingNotifier.value = false;
  }

  /// 发起投屏
  Future<bool> cast({
    required DlnaDevice device,
    required String mediaUrl,
    required String title,
    String posterUrl = '',
    Duration startPosition = Duration.zero,
  }) async {
    try {
      activeDeviceNotifier.value = device;
      isCastingNotifier.value = true;
      castPositionNotifier.value = startPosition;

      // 1. 设置视频地址 (SetAVTransportURI)
      final String didl = _buildDidl(title: title, url: mediaUrl, posterUrl: posterUrl);
      final String setUriXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>${_escapeXml(mediaUrl)}</CurrentURI>
      <CurrentURIMetaData>${_escapeXml(didl)}</CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>''';

      await _sendSoapAction(
        controlUrl: device.controlUrl,
        action: 'SetAVTransportURI',
        body: setUriXml,
      );

      // 2. 发送播放指令 (Play)
      final String playXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>''';

      await _sendSoapAction(
        controlUrl: device.controlUrl,
        action: 'Play',
        body: playXml,
      );

      isPlayingNotifier.value = true;

      // 3. 若有初始进度，跳转至初始进度 (Seek)
      if (startPosition > const Duration(seconds: 1)) {
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          seek(startPosition);
        });
      }

      // 4. 开启进度轮询
      _startPolling();
      return true;
    } catch (e) {
      debugPrint('[DLNA] 投屏失败: $e');
      stop();
      return false;
    }
  }

  /// 调整播放进度（Seek REL_TIME）
  Future<bool> seek(Duration target) async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return false;

    final String targetStr = _formatDuration(target);
    final String seekXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Unit>REL_TIME</Unit>
      <Target>$targetStr</Target>
    </u:Seek>
  </s:Body>
</s:Envelope>''';

    try {
      await _sendSoapAction(
        controlUrl: device.controlUrl,
        action: 'Seek',
        body: seekXml,
      );
      castPositionNotifier.value = target;
      return true;
    } catch (e) {
      debugPrint('[DLNA] Seek 失败: $e');
      return false;
    }
  }

  /// 暂停
  Future<void> pause() async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return;

    final String xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Pause>
  </s:Body>
</s:Envelope>''';

    try {
      await _sendSoapAction(controlUrl: device.controlUrl, action: 'Pause', body: xml);
      isPlayingNotifier.value = false;
    } catch (_) {}
  }

  /// 继续播放
  Future<void> play() async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return;

    final String xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>''';

    try {
      await _sendSoapAction(controlUrl: device.controlUrl, action: 'Play', body: xml);
      isPlayingNotifier.value = true;
    } catch (_) {}
  }

  /// 停止投屏
  Future<void> stop() async {
    _positionPollTimer?.cancel();
    _positionPollTimer = null;

    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device != null) {
      final String xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Stop>
  </s:Body>
</s:Envelope>''';
      try {
        await _sendSoapAction(controlUrl: device.controlUrl, action: 'Stop', body: xml);
      } catch (_) {}
    }

    activeDeviceNotifier.value = null;
    isCastingNotifier.value = false;
    isPlayingNotifier.value = false;
    castPositionNotifier.value = Duration.zero;
    castDurationNotifier.value = Duration.zero;
  }

  void _startPolling() {
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollPositionInfo();
    });
  }

  Future<void> _pollPositionInfo() async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return;

    final String xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:GetPositionInfo>
  </s:Body>
</s:Envelope>''';

    try {
      final String res = await _sendSoapAction(
        controlUrl: device.controlUrl,
        action: 'GetPositionInfo',
        body: xml,
      );

      final String relTime = RegExp(r'<RelTime>([^<]+)</RelTime>', caseSensitive: false)
              .firstMatch(res)
              ?.group(1) ??
          '';
      final String trackDur = RegExp(r'<TrackDuration>([^<]+)</TrackDuration>', caseSensitive: false)
              .firstMatch(res)
              ?.group(1) ??
          '';

      if (relTime.isNotEmpty) {
        final Duration pos = _parseDuration(relTime);
        if (pos >= Duration.zero) {
          castPositionNotifier.value = pos;
        }
      }
      if (trackDur.isNotEmpty) {
        final Duration dur = _parseDuration(trackDur);
        if (dur > Duration.zero) {
          castDurationNotifier.value = dur;
        }
      }
    } catch (_) {}
  }

  Future<String> _sendSoapAction({
    required String controlUrl,
    required String action,
    required String body,
  }) async {
    final Uri uri = Uri.parse(controlUrl);
    final HttpClientRequest request = await _httpClient.postUrl(uri);
    request.headers.set('Content-Type', 'text/xml; charset="utf-8"');
    request.headers.set('SOAPAction', '"urn:schemas-upnp-org:service:AVTransport:1#$action"');
    request.headers.set('User-Agent', 'DLNADOC/1.50');
    request.add(utf8.encode(body));

    final HttpClientResponse response = await request.close().timeout(
          const Duration(seconds: 4),
        );
    return await response.transform(utf8.decoder).join();
  }

  String _buildDidl({
    required String title,
    required String url,
    String posterUrl = '',
  }) {
    return '&lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;'
        '&lt;item id="0" parentID="-1" restricted="1"&gt;'
        '&lt;dc:title&gt;${_escapeXml(title)}&lt;/dc:title&gt;'
        '&lt;upnp:class&gt;object.item.videoItem&lt;/upnp:class&gt;'
        if (posterUrl.isNotEmpty) '&lt;upnp:albumArtURI&gt;${_escapeXml(posterUrl)}&lt;/upnp:albumArtURI&gt;'
        '&lt;res protocolInfo="http-get:*:video/mp4:*"&gt;${_escapeXml(url)}&lt;/res&gt;'
        '&lt;/item&gt;&lt;/DIDL-Lite&gt;';
  }

  String _formatDuration(Duration d) {
    final String twoHours = d.inHours.toString().padLeft(2, '0');
    final String twoMinutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final String twoSeconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$twoHours:$twoMinutes:$twoSeconds';
  }

  Duration _parseDuration(String timeStr) {
    try {
      final List<String> parts = timeStr.split(':');
      if (parts.length == 3) {
        final int h = int.parse(parts[0]);
        final int m = int.parse(parts[1]);
        final double s = double.parse(parts[2]);
        return Duration(hours: h, minutes: m, seconds: s.toInt());
      }
    } catch (_) {}
    return Duration.zero;
  }

  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
