import 'package:flutter/foundation.dart';

/// DLNA 投屏设备模型（支持小米电视、爱奇艺电视果、标准 DLNA/UPnP DMR 设备）。
@immutable
class DlnaDevice {
  const DlnaDevice({
    required this.id,
    required this.name,
    required this.location,
    required this.controlUrl,
    this.renderingControlUrl,
    this.modelName = '',
    this.manufacturer = '',
  });

  final String id;
  final String name;
  final String location;
  final String controlUrl;
  final String? renderingControlUrl;
  final String modelName;
  final String manufacturer;

  /// 判断是否是小米电视 / 小米盒子
  bool get isXiaomi {
    final String lower = '$name $modelName $manufacturer'.toLowerCase();
    return lower.contains('xiaomi') ||
        lower.contains('mi tv') ||
        lower.contains('mitv') ||
        lower.contains('小米');
  }

  /// 判断是否是爱奇艺电视果
  bool get isDianshiguo {
    final String lower = '$name $modelName $manufacturer'.toLowerCase();
    return lower.contains('dianshiguo') ||
        lower.contains('tvguo') ||
        lower.contains('电视果') ||
        lower.contains('iqiyi') ||
        lower.contains('爱奇艺');
  }

  /// 友好副标题
  String get subtitle {
    if (isXiaomi) return '小米电视 / 盒子';
    if (isDianshiguo) return '爱奇艺电视果';
    if (modelName.isNotEmpty) return modelName;
    return 'DLNA 接收端';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DlnaDevice && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DlnaDevice($name, $location)';
}
