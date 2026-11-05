import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

/// Sunucu adresi. Değiştirmek için derlerken:
///   flutter build apk --dart-define=API_URL=https://...
const String apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://hello-world-backend-uv4l.onrender.com',
);

/// Ücretsiz Render sunucusu uyuyorsa uyanması ~1 dk sürer.
const Duration _timeout = Duration(seconds: 90);

class Photo {
  final int id;
  final int? placeId;
  final String url;
  final DateTime createdAt;

  Photo({
    required this.id,
    required this.url,
    required this.createdAt,
    this.placeId,
  });

  factory Photo.fromJson(Map<String, dynamic> j) => Photo(
        id: j['id'] as int,
        placeId: j['placeId'] as int?,
        url: j['url'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
      );
}

enum PlaceStatus { planned, visited }

class Place {
  final int id;
  final String title;
  final PlaceStatus status;
  final DateTime? date;
  final String? locationName;
  final double? lat;
  final double? lng;
  final String? notes;
  final int? rating;
  final String? comment;
  final int photoCount;
  final String? coverUrl;
  final List<Photo> photos;

  Place({
    required this.id,
    required this.title,
    required this.status,
    this.date,
    this.locationName,
    this.lat,
    this.lng,
    this.notes,
    this.rating,
    this.comment,
    this.photoCount = 0,
    this.coverUrl,
    this.photos = const [],
  });

  bool get hasCoords => lat != null && lng != null;

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        id: j['id'] as int,
        title: j['title'] as String,
        status: j['status'] == 'visited' ? PlaceStatus.visited : PlaceStatus.planned,
        date: j['date'] == null ? null : DateTime.parse(j['date'] as String),
        locationName: j['locationName'] as String?,
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        notes: j['notes'] as String?,
        rating: j['rating'] as int?,
        comment: j['comment'] as String?,
        photoCount: (j['photoCount'] as num?)?.toInt() ?? 0,
        coverUrl: j['coverUrl'] as String?,
        photos: (j['photos'] as List?)
                ?.map((e) => Photo.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// Sunucuya gönderilecek yer bilgileri (ekleme ve düzenleme formu).
class PlaceInput {
  String title;
  PlaceStatus status;
  DateTime? date;
  String? locationName;
  double? lat;
  double? lng;
  String? notes;
  int? rating;
  String? comment;

  PlaceInput({
    this.title = '',
    this.status = PlaceStatus.planned,
    this.date,
    this.locationName,
    this.lat,
    this.lng,
    this.notes,
    this.rating,
    this.comment,
  });

  factory PlaceInput.from(Place p) => PlaceInput(
        title: p.title,
        status: p.status,
        date: p.date,
        locationName: p.locationName,
        lat: p.lat,
        lng: p.lng,
        notes: p.notes,
        rating: p.rating,
        comment: p.comment,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'status': status.name,
        'date': date == null ? null : _ymd(date!),
        'locationName': locationName,
        'lat': lat,
        'lng': lng,
        'notes': notes,
        'rating': rating,
        'comment': comment,
      };

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class PhotoApi {
  static final http.Client _client = http.Client();

  Uri _u(String path) => Uri.parse('$apiUrl$path');

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  String _errorFrom(http.Response r) {
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is Map && body['error'] != null) return body['error'].toString();
    } catch (_) {}
    return 'Sunucu hatası (${r.statusCode})';
  }

  dynamic _decode(http.Response r) => jsonDecode(utf8.decode(r.bodyBytes));

  // ---------- Fotoğraflar ----------

  Future<List<Photo>> list() async {
    final r = await _client.get(_u('/photos')).timeout(_timeout);
    if (r.statusCode != 200) throw ApiException(_errorFrom(r));
    final data = _decode(r) as List;
    return data.map((e) => Photo.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// [placeId] verilirse fotoğraf o yere eklenir.
  Future<Photo> upload(XFile file, {int? placeId}) async {
    final path = placeId == null ? '/photos' : '/places/$placeId/photos';
    final req = http.MultipartRequest('POST', _u(path));
    req.files.add(await http.MultipartFile.fromPath(
      'photo',
      file.path,
      filename: file.name,
      contentType: _mediaType(file),
    ));
    final streamed = await _client.send(req).timeout(_timeout);
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode != 201) throw ApiException(_errorFrom(r));
    return Photo.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<void> delete(int id) async {
    final r = await _client.delete(_u('/photos/$id')).timeout(_timeout);
    if (r.statusCode != 204 && r.statusCode != 404) {
      throw ApiException(_errorFrom(r));
    }
  }

  // ---------- Yerler ----------

  Future<List<Place>> places(PlaceStatus status) async {
    final r =
        await _client.get(_u('/places?status=${status.name}')).timeout(_timeout);
    if (r.statusCode != 200) throw ApiException(_errorFrom(r));
    final data = _decode(r) as List;
    return data.map((e) => Place.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Place> place(int id) async {
    final r = await _client.get(_u('/places/$id')).timeout(_timeout);
    if (r.statusCode != 200) throw ApiException(_errorFrom(r));
    return Place.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<Place> createPlace(PlaceInput input) async {
    final r = await _client
        .post(_u('/places'),
            headers: _jsonHeaders, body: jsonEncode(input.toJson()))
        .timeout(_timeout);
    if (r.statusCode != 201) throw ApiException(_errorFrom(r));
    return Place.fromJson(_decode(r) as Map<String, dynamic>);
  }

  /// Sadece [fields] içindeki alanları günceller.
  Future<Place> updatePlace(int id, Map<String, dynamic> fields) async {
    final r = await _client
        .put(_u('/places/$id'), headers: _jsonHeaders, body: jsonEncode(fields))
        .timeout(_timeout);
    if (r.statusCode != 200) throw ApiException(_errorFrom(r));
    return Place.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<void> deletePlace(int id) async {
    final r = await _client.delete(_u('/places/$id')).timeout(_timeout);
    if (r.statusCode != 204 && r.statusCode != 404) {
      throw ApiException(_errorFrom(r));
    }
  }

  /// Sunucu sadece image/* kabul ettiği için türü doğru göndermek şart.
  MediaType _mediaType(XFile f) {
    final m = f.mimeType;
    if (m != null && m.startsWith('image/')) return MediaType.parse(m);
    final ext = f.name.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return MediaType('image', 'png');
      case 'webp':
        return MediaType('image', 'webp');
      case 'gif':
        return MediaType('image', 'gif');
      case 'heic':
        return MediaType('image', 'heic');
      default:
        return MediaType('image', 'jpeg');
    }
  }
}
