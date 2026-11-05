import 'dart:convert';

import 'package:http/http.dart' as http;

/// OpenStreetMap Nominatim ile yer arama ve koordinattan adres bulma.
/// Kullanım kuralı: saniyede en fazla 1 istek, uygulamayı tanıtan User-Agent.
/// Bu yüzden arama yazarken değil, sadece "ara" denince yapılır.
class Osm {
  static const userAgent =
      'GeziAjandam/1.0 (+https://github.com/IshakGeneli/hello_world_maybe)';
  static const _host = 'nominatim.openstreetmap.org';
  static const _timeout = Duration(seconds: 10);

  static Map<String, String> get _headers => {'User-Agent': userAgent};

  static Future<List<OsmPlace>> search(String query) async {
    final uri = Uri.https(_host, '/search', {
      'q': query,
      'format': 'jsonv2',
      'limit': '8',
      'accept-language': 'tr',
      'addressdetails': '0',
    });
    final r = await http.get(uri, headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) {
      throw Exception('Arama başarısız (${r.statusCode})');
    }
    final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
    return list
        .map((e) => OsmPlace.fromJson(e as Map<String, dynamic>))
        .whereType<OsmPlace>()
        .toList();
  }

  /// Koordinatın kısa adresi ("Göreme, Nevşehir Merkez, Nevşehir"); bulunamazsa null.
  static Future<String?> reverse(double lat, double lng) async {
    try {
      final uri = Uri.https(_host, '/reverse', {
        'lat': lat.toString(),
        'lon': lng.toString(),
        'format': 'jsonv2',
        'zoom': '16',
        'accept-language': 'tr',
      });
      final r = await http.get(uri, headers: _headers).timeout(_timeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final name = j['display_name'] as String?;
      return name == null ? null : shorten(name);
    } catch (_) {
      return null;
    }
  }

  /// Uzun adresin ilk 3 parçası.
  static String shorten(String displayName) =>
      displayName.split(',').map((s) => s.trim()).take(3).join(', ');
}

class OsmPlace {
  final String displayName;
  final double lat;
  final double lng;

  OsmPlace(this.displayName, this.lat, this.lng);

  String get shortName => Osm.shorten(displayName);

  static OsmPlace? fromJson(Map<String, dynamic> j) {
    final lat = double.tryParse('${j['lat']}');
    final lng = double.tryParse('${j['lon']}');
    final name = j['display_name'] as String?;
    if (lat == null || lng == null || name == null) return null;
    return OsmPlace(name, lat, lng);
  }
}
