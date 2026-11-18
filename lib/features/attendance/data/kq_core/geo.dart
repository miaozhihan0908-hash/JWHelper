/// 围栏判定：与前端 `xt(course, gps)` 同规则。
/// 优先多边形射线法，退化到中心点 100 米半径。
library;

import 'dart:math' as math;

const double kEarthR = 6371008.8;

/// 两点球面距离（米）。
double haversine(double lng1, double lat1, double lng2, double lat2) {
  final r1 = lat1 * math.pi / 180;
  final r2 = lat2 * math.pi / 180;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(r1) * math.cos(r2) * math.pow(math.sin(dLng / 2), 2);
  return 2 * kEarthR * math.asin(math.sqrt(a.toDouble()));
}

/// 射线法：点是否在多边形内。poly 为 [[lng,lat], ...]。
bool pointInPolygon(double lng, double lat, List<List<double>> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final x1 = poly[j][0], y1 = poly[j][1];
    final x2 = poly[i][0], y2 = poly[i][1];
    if ((y1 > lat) != (y2 > lat) &&
        lng < (x2 - x1) * (lat - y1) / (y2 - y1) + x1) {
      inside = !inside;
    }
  }
  return inside;
}

/// 围栏中心：有 title == "c" 的点就用它，否则取其余点的算术平均。
List<double>? fenceCenter(List<dynamic>? roomGpsList) {
  if (roomGpsList == null || roomGpsList.isEmpty) return null;
  for (final p in roomGpsList) {
    final m = p as Map;
    if ('${m['title']}' == 'c') {
      return [double.parse('${m['longitude']}'), double.parse('${m['latitude']}')];
    }
  }
  final pts = roomGpsList.where((p) => '${(p as Map)['title']}' != 'c').toList();
  if (pts.isEmpty) return null;
  var sl = 0.0, sa = 0.0;
  for (final p in pts) {
    final m = p as Map;
    sl += double.parse('${m['longitude']}');
    sa += double.parse('${m['latitude']}');
  }
  return [sl / pts.length, sa / pts.length];
}

class FenceResult {
  final double distance;
  final String status; // '3' 在范围内，'4' 需确认
  const FenceResult(this.distance, this.status);
  bool get inFence => status == '3';
  @override
  String toString() => 'distance=${distance.toStringAsFixed(1)}m status=$status';
}

/// 与前端一致的围栏判定。
FenceResult evaluateFence(List<dynamic>? roomGpsList, String gps) {
  if (roomGpsList == null || roomGpsList.isEmpty || gps.isEmpty) {
    return const FenceResult(400, '4');
  }
  final parts = gps.split(',');
  final lng = double.parse(parts[0].trim());
  final lat = double.parse(parts[1].trim());

  final pts = roomGpsList.where((p) => '${(p as Map)['title']}' != 'c').toList();
  if (pts.length >= 3) {
    final poly = pts
        .map((p) => [
              double.parse('${(p as Map)['longitude']}'),
              double.parse('${p['latitude']}'),
            ])
        .toList();
    if (pointInPolygon(lng, lat, poly)) return const FenceResult(0, '3');
  }
  final c = fenceCenter(roomGpsList);
  if (c == null) return const FenceResult(200, '4');
  final d = haversine(c[0], c[1], lng, lat);
  return FenceResult(d, d > 100 ? '4' : '3');
}

final math.Random _rnd = math.Random();

/// 高斯抖动（更接近真机 GPS 漂移）。
List<double> jitter(double lng, double lat, double sigmaMeters) {
  final s = sigmaMeters / 111320.0;
  double gauss() {
    final u = 1 - _rnd.nextDouble();
    final v = _rnd.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  return [lng + gauss() * s, lat + gauss() * s * 0.8];
}

String formatGps(double lng, double lat) =>
    '${lng.toStringAsFixed(6)},${lat.toStringAsFixed(6)}';
