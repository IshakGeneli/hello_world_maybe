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
  final int? agendaId;
  final String? createdBy; // yeri ekleyen kişinin adı
  final Access? access; // sadece detayda gelir

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
    this.agendaId,
    this.createdBy,
    this.access,
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
        agendaId: j['agendaId'] as int?,
        createdBy: j['createdBy'] as String?,
        access: j['access'] == null
            ? null
            : Access.fromJson(j['access'] as Map<String, dynamic>),
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
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);
  @override
  String toString() => message;
}

// ---------- Hesap ve paylaşım modelleri ----------

class AppUser {
  final int id;
  final String email;
  final String name;

  AppUser({required this.id, required this.email, required this.name});

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as int,
        email: j['email'] as String,
        name: j['name'] as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name};
}

/// Bir ajandadaki yetkiler.
class Access {
  final bool isOwner;
  final bool canAdd;
  final bool canEdit;
  final bool canDelete;

  const Access({
    this.isOwner = false,
    this.canAdd = false,
    this.canEdit = false,
    this.canDelete = false,
  });

  static const owner =
      Access(isOwner: true, canAdd: true, canEdit: true, canDelete: true);

  factory Access.fromJson(Map<String, dynamic> j) => Access(
        isOwner: j['isOwner'] as bool? ?? false,
        canAdd: j['canAdd'] as bool? ?? false,
        canEdit: j['canEdit'] as bool? ?? false,
        canDelete: j['canDelete'] as bool? ?? false,
      );
}

/// Kullanıcının görebildiği bir ajanda (kendisininki ya da paylaşılan).
class Agenda {
  final int id; // ajanda sahibinin kullanıcı id'si
  final int? invitationId; // paylaşılan ajandalarda: ayrılmak için
  final String ownerName;
  final String ownerEmail;
  final Access access;

  Agenda({
    required this.id,
    required this.ownerName,
    required this.ownerEmail,
    required this.access,
    this.invitationId,
  });

  bool get isOwner => access.isOwner;
  String get title => isOwner ? 'Ajandam' : ownerName;

  /// "ekleme, düzenleme" gibi kısa yetki özeti.
  String get permissionSummary {
    if (isOwner) return 'Sahibi sensin';
    final p = [
      if (access.canAdd) 'ekleme',
      if (access.canEdit) 'düzenleme',
      if (access.canDelete) 'silme',
    ];
    return p.isEmpty ? 'Sadece görüntüleme' : 'Yetkilerin: ${p.join(', ')}';
  }

  factory Agenda.fromJson(Map<String, dynamic> j) => Agenda(
        id: j['id'] as int,
        invitationId: j['invitationId'] as int?,
        ownerName: j['ownerName'] as String,
        ownerEmail: j['ownerEmail'] as String,
        access: Access.fromJson(j),
      );
}

enum InvitationStatus { pending, accepted, declined }

class Invitation {
  final int id;
  final String email;
  final InvitationStatus status;
  final bool canAdd;
  final bool canEdit;
  final bool canDelete;
  final String? memberName; // gönderilen davetlerde: davetlinin hesabı varsa adı
  final AppUser? owner; // gelen davetlerde: davet eden

  Invitation({
    required this.id,
    required this.email,
    required this.status,
    required this.canAdd,
    required this.canEdit,
    required this.canDelete,
    this.memberName,
    this.owner,
  });

  factory Invitation.fromJson(Map<String, dynamic> j) => Invitation(
        id: j['id'] as int,
        email: j['email'] as String,
        status: InvitationStatus.values.byName(j['status'] as String),
        canAdd: j['canAdd'] as bool,
        canEdit: j['canEdit'] as bool,
        canDelete: j['canDelete'] as bool,
        memberName: j['memberName'] as String?,
        owner: j['owner'] == null
            ? null
            : AppUser.fromJson(j['owner'] as Map<String, dynamic>),
      );
}

class AuthResult {
  final String token;
  final AppUser user;
  AuthResult(this.token, this.user);
}

// ---------- API ----------

class PhotoApi {
  static final http.Client _client = http.Client();

  /// Oturum anahtarı. Session tarafından ayarlanır.
  static String? token;

  /// Sunucu 401 dönünce çağrılır (oturumu kapatmak için).
  static void Function()? onUnauthorized;

  /// Fotoğrafları (Image.network) yüklerken de gereken başlıklar.
  static Map<String, String> get authHeaders =>
      token == null ? const {} : {'Authorization': 'Bearer $token'};

  static Map<String, String> get _jsonHeaders =>
      {'Content-Type': 'application/json', ...authHeaders};

  Uri _u(String path) => Uri.parse('$apiUrl$path');

  dynamic _decode(http.Response r) => jsonDecode(utf8.decode(r.bodyBytes));

  /// Beklenen durum kodu değilse anlaşılır bir hata fırlatır.
  void _check(http.Response r, List<int> ok, {bool isAuthCall = false}) {
    if (ok.contains(r.statusCode)) return;
    String message = 'Sunucu hatası (${r.statusCode})';
    try {
      final body = _decode(r);
      if (body is Map && body['error'] != null) message = body['error'].toString();
    } catch (_) {}
    if (r.statusCode == 401 && !isAuthCall) onUnauthorized?.call();
    throw ApiException(message, r.statusCode);
  }

  Future<http.Response> _get(String path) =>
      _client.get(_u(path), headers: authHeaders).timeout(_timeout);

  Future<http.Response> _post(String path, [Object? body]) => _client
      .post(_u(path), headers: _jsonHeaders, body: jsonEncode(body ?? {}))
      .timeout(_timeout);

  Future<http.Response> _put(String path, Object body) => _client
      .put(_u(path), headers: _jsonHeaders, body: jsonEncode(body))
      .timeout(_timeout);

  Future<http.Response> _delete(String path) =>
      _client.delete(_u(path), headers: authHeaders).timeout(_timeout);

  // ---------- Hesap ----------

  Future<AuthResult> login(String email, String password) async {
    final r = await _post('/auth/login', {'email': email, 'password': password});
    _check(r, [200], isAuthCall: true);
    final j = _decode(r) as Map<String, dynamic>;
    return AuthResult(
        j['token'] as String, AppUser.fromJson(j['user'] as Map<String, dynamic>));
  }

  Future<AuthResult> register(String email, String password, String name) async {
    final r = await _post(
        '/auth/register', {'email': email, 'password': password, 'name': name});
    _check(r, [201], isAuthCall: true);
    final j = _decode(r) as Map<String, dynamic>;
    return AuthResult(
        j['token'] as String, AppUser.fromJson(j['user'] as Map<String, dynamic>));
  }

  /// Bekleyen davet sayısı.
  Future<int> pendingInvitations() async {
    final r = await _get('/me');
    _check(r, [200]);
    return (_decode(r) as Map<String, dynamic>)['pendingInvitations'] as int;
  }

  // ---------- Ajandalar ve davetler ----------

  Future<List<Agenda>> agendas() async {
    final r = await _get('/agendas');
    _check(r, [200]);
    return (_decode(r) as List)
        .map((e) => Agenda.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Invitation> invite(String email,
      {bool canAdd = true, bool canEdit = false, bool canDelete = false}) async {
    final r = await _post('/invitations', {
      'email': email,
      'canAdd': canAdd,
      'canEdit': canEdit,
      'canDelete': canDelete,
    });
    _check(r, [201]);
    return Invitation.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<List<Invitation>> sentInvitations() async {
    final r = await _get('/invitations/sent');
    _check(r, [200]);
    return (_decode(r) as List)
        .map((e) => Invitation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Invitation>> receivedInvitations() async {
    final r = await _get('/invitations/received');
    _check(r, [200]);
    return (_decode(r) as List)
        .map((e) => Invitation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Invitation> updateInvitation(int id,
      {bool? canAdd, bool? canEdit, bool? canDelete}) async {
    final r = await _put('/invitations/$id', {
      if (canAdd != null) 'canAdd': canAdd,
      if (canEdit != null) 'canEdit': canEdit,
      if (canDelete != null) 'canDelete': canDelete,
    });
    _check(r, [200]);
    return Invitation.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<void> acceptInvitation(int id) async =>
      _check(await _post('/invitations/$id/accept'), [200]);

  Future<void> declineInvitation(int id) async =>
      _check(await _post('/invitations/$id/decline'), [200]);

  /// Sahip için üyeyi çıkarır; davetli için ajandadan ayrılır.
  Future<void> deleteInvitation(int id) async =>
      _check(await _delete('/invitations/$id'), [204, 404]);

  // ---------- Yerler ----------

  Future<List<Place>> places(int agendaId, PlaceStatus status) async {
    final r = await _get('/places?agenda=$agendaId&status=${status.name}');
    _check(r, [200]);
    return (_decode(r) as List)
        .map((e) => Place.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Place> place(int id) async {
    final r = await _get('/places/$id');
    _check(r, [200]);
    return Place.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<Place> createPlace(int agendaId, PlaceInput input) async {
    final r = await _post('/places', {...input.toJson(), 'agendaId': agendaId});
    _check(r, [201]);
    return Place.fromJson(_decode(r) as Map<String, dynamic>);
  }

  /// Sadece [fields] içindeki alanları günceller.
  Future<Place> updatePlace(int id, Map<String, dynamic> fields) async {
    final r = await _put('/places/$id', fields);
    _check(r, [200]);
    return Place.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<void> deletePlace(int id) async =>
      _check(await _delete('/places/$id'), [204, 404]);

  // ---------- Fotoğraflar ----------

  Future<Photo> upload(XFile file, {required int placeId}) async {
    final req = http.MultipartRequest('POST', _u('/places/$placeId/photos'));
    req.headers.addAll(authHeaders);
    req.files.add(await http.MultipartFile.fromPath(
      'photo',
      file.path,
      filename: file.name,
      contentType: _mediaType(file),
    ));
    final streamed = await _client.send(req).timeout(_timeout);
    final r = await http.Response.fromStream(streamed);
    _check(r, [201]);
    return Photo.fromJson(_decode(r) as Map<String, dynamic>);
  }

  Future<void> delete(int photoId) async =>
      _check(await _delete('/photos/$photoId'), [204, 404]);

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
