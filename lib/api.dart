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
  final String url;
  final DateTime createdAt;

  Photo({required this.id, required this.url, required this.createdAt});

  factory Photo.fromJson(Map<String, dynamic> j) => Photo(
        id: j['id'] as int,
        url: j['url'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
      );
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class PhotoApi {
  final http.Client _client = http.Client();

  Uri _u(String path) => Uri.parse('$apiUrl$path');

  String _errorFrom(http.Response r) {
    try {
      final body = jsonDecode(r.body);
      if (body is Map && body['error'] != null) return body['error'].toString();
    } catch (_) {}
    return 'Sunucu hatası (${r.statusCode})';
  }

  Future<List<Photo>> list() async {
    final r = await _client.get(_u('/photos')).timeout(_timeout);
    if (r.statusCode != 200) throw ApiException(_errorFrom(r));
    final data = jsonDecode(r.body) as List;
    return data.map((e) => Photo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Photo> upload(XFile file) async {
    final req = http.MultipartRequest('POST', _u('/photos'));
    req.files.add(await http.MultipartFile.fromPath(
      'photo',
      file.path,
      filename: file.name,
      contentType: _mediaType(file),
    ));
    final streamed = await _client.send(req).timeout(_timeout);
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode != 201) throw ApiException(_errorFrom(r));
    return Photo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> delete(int id) async {
    final r = await _client.delete(_u('/photos/$id')).timeout(_timeout);
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
