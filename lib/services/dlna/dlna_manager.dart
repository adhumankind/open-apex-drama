import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dlna_device.dart';

/// DLNA 投屏管理器单例。
///
/// 专为大屏生态（小米电视、爱奇艺电视果、各类机顶盒及 DLNA 接收端）设计：
/// 1. 基于 SSDP 协议（UDP 组播 239.255.255.250:1900）实现毫秒级设备发现；
/// 2. 基于 AVTransport:1 SOAP 协议实现投屏控制（播、停、暂停、断点起播）；
/// 3. 精准支持【调整播放进度】（Seek REL_TIME）与进度实时同步（GetPositionInfo）。
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
  Timer? _positionPollTimer;
  final Set<String> _discoveredLocations = <String>{};
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  /// 启动局域网设备搜索（搜索小米电视、电视果等 DLNA 接收端）
  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 8)}) async {
    stopDiscovery();
    isSearchingNotifier.value = true;
    _discoveredLocations.clear();

    try {
      _ssdpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: false,
      );
      _ssdpSocket?.broadcastEnabled = true;
      _ssdpSocket?.multicastLoopback = false;

      _ssdpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final Datagram? dg = _ssdpSocket?.receive();
          if (dg != null) {
            _handleSsdpResponse(utf8.decode(dg.data, allowMalformed: true));
          }
        }
      });

      // 发送搜索报文（针对 AVTransport 与 MediaRenderer）
      _sendMSearch('urn:schemas-upnp-org:service:AVTransport:1');
      _sendMSearch('urn:schemas-upnp-org:device:MediaRenderer:1');
      _sendMSearch('ssdp:all');

      _searchTimeoutTimer = Timer(timeout, stopDiscovery);
    } catch (e) {
      debugPrint('[DLNA] 启动搜索失败: $e');
      isSearchingNotifier.value = false;
    }
  }

  void _sendMSearch(String target) {
    final String msg = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 3\r\n'
        'ST: $target\r\n\r\n';
    try {
      final List<int> data = utf8.encode(msg);
      _ssdpSocket?.send(data, InternetAddress('239.255.255.250'), 1900);
    } catch (_) {}
  }

  void _handleSsdpResponse(String response) {
    final RegExp locRegExp = RegExp(r'LOCATION:\s*([^\r\n]+)', caseSensitive: false);
    final Match? match = locRegExp.firstMatch(response);
    if (match != null) {
      final String loc = match.group(1)?.trim() ?? '';
      if (loc.isNotEmpty && _discoveredLocations.add(loc)) {
        _fetchDeviceDescription(loc);
      }
    }
  }

  Future<void> _fetchDeviceDescription(String location) async {
    try {
      final Uri uri = Uri.parse(location);
      final HttpClientRequest request = await _httpClient.getUrl(uri);
      final HttpClientResponse response = await request.close();
      if (response.statusCode == 200) {
        final String xml = await response.transform(utf8.decoder).join();
        _parseDeviceXml(xml, location, uri);
      }
    } catch (_) {}
  }

  void _parseDeviceXml(String xml, String location, Uri baseUri) {
    // 匹配 friendlyName
    final RegExp nameRegExp = RegExp(r'<friendlyName>([^<]+)</friendlyName>');
    final String name = nameRegExp.firstMatch(xml)?.group(1)?.trim() ?? '未知设备';

    // 匹配 modelName / manufacturer
    final String model = RegExp(r'<modelName>([^<]+)</modelName>').firstMatch(xml)?.group(1)?.trim() ?? '';
    final String manufacturer = RegExp(r'<manufacturer>([^<]+)</manufacturer>').firstMatch(xml)?.group(1)?.trim() ?? '';
    final String udn = RegExp(r'<UDN>([^<]+)</UDN>').firstMatch(xml)?.group(1)?.trim() ?? location;

    // 查找 AVTransport 服务的 controlURL
    final RegExp avRegExp = RegExp(
      r'<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>[\s\S]*?<controlURL>([^<]+)</controlURL>',
      caseSensitive: false,
    );
    final Match? avMatch = avRegExp.firstMatch(xml);
    if (avMatch == null) {
      return; // 过滤非媒体渲染器设备
    }

    String controlPath = avMatch.group(1)?.trim() ?? '';
    final String controlUrl = _resolveUrl(baseUri, controlPath);

    // 查找 RenderingControl 服务的 controlURL (可选，用于音量调节)
    final RegExp rcRegExp = RegExp(
      r'<serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>[\s\S]*?<controlURL>([^<]+)</controlURL>',
      caseSensitive: false,
    );
    final String? rcPath = rcRegExp.firstMatch(xml)?.group(1)?.trim();
    final String? rcUrl = rcPath != null ? _resolveUrl(baseUri, rcPath) : null;

    final DlnaDevice device = DlnaDevice(
      id: udn,
      name: name,
      location: location,
      controlUrl: controlUrl,
      renderingControlUrl: rcUrl,
      modelName: model,
      manufacturer: manufacturer,
    );

    final List<DlnaDevice> current = List<DlnaDevice>.from(devicesNotifier.value);
    final int idx = current.indexWhere((DlnaDevice d) => d.id == device.id);
    if (idx >= 0) {
      current[idx] = device;
    } else {
      current.add(device);
    }
    devicesNotifier.value = current;
  }

  String _resolveUrl(Uri baseUri, String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    return '${baseUri.scheme}://${baseUri.host}:${baseUri.port}$path';
  }

  /// 停止搜索
  void stopDiscovery() {
    _searchTimeoutTimer?.cancel();
    _searchTimeoutTimer = null;
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

  /// 调整播放进度（Seek）
  Future<bool> seek(Duration target) async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return false;

    // 先行给用户界面即时反馈
    castPositionNotifier.value = target;

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

    return _sendSoapAction(
      controlUrl: device.controlUrl,
      action: 'Seek',
      body: seekXml,
    );
  }

  /// 播放 / 继续
  Future<bool> play() async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return false;

    final String playXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>''';

    final bool ok = await _sendSoapAction(
      controlUrl: device.controlUrl,
      action: 'Play',
      body: playXml,
    );
    if (ok) isPlayingNotifier.value = true;
    return ok;
  }

  /// 暂停
  Future<bool> pause() async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return false;

    final String pauseXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Pause>
  </s:Body>
</s:Envelope>''';

    final bool ok = await _sendSoapAction(
      controlUrl: device.controlUrl,
      action: 'Pause',
      body: pauseXml,
    );
    if (ok) isPlayingNotifier.value = false;
    return ok;
  }

  /// 停止投屏
  Future<void> stop() async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    _stopPolling();

    if (device != null) {
      final String stopXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Stop>
  </s:Body>
</s:Envelope>''';

      try {
        await _sendSoapAction(
          controlUrl: device.controlUrl,
          action: 'Stop',
          body: stopXml,
        );
      } catch (_) {}
    }

    activeDeviceNotifier.value = null;
    isCastingNotifier.value = false;
    isPlayingNotifier.value = false;
  }

  void _startPolling() {
    _stopPolling();
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      _pollPositionInfo();
    });
  }

  void _stopPolling() {
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
  }

  /// 获取电视当前播放进度 (GetPositionInfo)
  Future<void> _pollPositionInfo() async {
    final DlnaDevice? device = activeDeviceNotifier.value;
    if (device == null) return;

    final String getPosXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:GetPositionInfo>
  </s:Body>
</s:Envelope>''';

    try {
      final String? response = await _sendSoapActionWithResponse(
        controlUrl: device.controlUrl,
        action: 'GetPositionInfo',
        body: getPosXml,
      );

      if (response != null && response.isNotEmpty) {
        // 解析 RelTime
        final String relTime = RegExp(r'<RelTime>([^<]+)</RelTime>').firstMatch(response)?.group(1)?.trim() ?? '';
        final Duration current = _parseDuration(relTime);
        if (current > Duration.zero) {
          castPositionNotifier.value = current;
        }

        // 解析 TrackDuration
        final String trackDur = RegExp(r'<TrackDuration>([^<]+)</TrackDuration>').firstMatch(response)?.group(1)?.trim() ?? '';
        final Duration total = _parseDuration(trackDur);
        if (total > Duration.zero) {
          castDurationNotifier.value = total;
        }
      }
    } catch (_) {}
  }

  Future<bool> _sendSoapAction({
    required String controlUrl,
    required String action,
    required String body,
  }) async {
    final String? res = await _sendSoapActionWithResponse(
      controlUrl: controlUrl,
      action: action,
      body: body,
    );
    return res != null;
  }

  Future<String?> _sendSoapActionWithResponse({
    required String controlUrl,
    required String action,
    required String body,
  }) async {
    try {
      final Uri uri = Uri.parse(controlUrl);
      final HttpClientRequest req = await _httpClient.postUrl(uri);
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPAction', '"urn:schemas-upnp-org:service:AVTransport:1#$action"');

      final List<int> bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);

      final HttpClientResponse resp = await req.close();
      if (resp.statusCode == 200) {
        return await resp.transform(utf8.decoder).join();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _buildDidl({required String title, required String url, required String posterUrl}) {
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>$title</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '${posterUrl.isNotEmpty ? '<upnp:albumArtURI>$posterUrl</upnp:albumArtURI>' : ''}'
        '<res protocolInfo="http-get:*:video/mp4:*">$url</res>'
        '</item>'
        '</DIDL-Lite>';
  }

  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  String _formatDuration(Duration d) {
    final int hours = d.inHours;
    final int minutes = d.inMinutes.remainder(60);
    final int seconds = d.inSeconds.remainder(60);
    final String hStr = hours.toString().padLeft(2, '0');
    final String mStr = minutes.toString().padLeft(2, '0');
    final String sStr = seconds.toString().padLeft(2, '0');
    return '$hStr:$mStr:$sStr';
  }

  Duration _parseDuration(String text) {
    if (text.isEmpty || text == 'NOT_IMPLEMENTED') return Duration.zero;
    final List<String> parts = text.split(':');
    if (parts.length == 3) {
      final int h = int.tryParse(parts[0]) ?? 0;
      final int m = int.tryParse(parts[1]) ?? 0;
      final double s = double.tryParse(parts[2]) ?? 0;
      return Duration(hours: h, minutes: m, seconds: s.toInt());
    }
    return Duration.zero;
  }
}
