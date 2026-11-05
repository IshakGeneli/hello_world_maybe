import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'common.dart';
import 'location_picker_page.dart';
import 'place_form_page.dart';

class PlaceDetailPage extends StatefulWidget {
  final int placeId;

  const PlaceDetailPage({super.key, required this.placeId});

  @override
  State<PlaceDetailPage> createState() => _PlaceDetailPageState();
}

class _Pending {
  final XFile file;
  bool failed = false;
  _Pending(this.file);
}

class _PlaceDetailPageState extends State<PlaceDetailPage> {
  final PhotoApi _api = PhotoApi();
  final ImagePicker _picker = ImagePicker();

  Place? _place;
  Access _access = const Access();
  List<Photo> _photos = [];
  final List<_Pending> _pending = [];
  String? _error;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _slow = false;
    });
    final slowTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _place == null) setState(() => _slow = true);
    });
    try {
      final p = await _api.place(widget.placeId);
      if (!mounted) return;
      setState(() {
        _place = p;
        _access = p.access ?? const Access();
        _photos = List.of(p.photos);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Yüklenemedi: $e');
    } finally {
      slowTimer.cancel();
    }
  }

  // ---------- Fotoğraflar ----------

  void _showPhotoSourceSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeriden seç'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Fotoğraf çek'),
              onTap: () {
                Navigator.pop(ctx);
                _takePhoto();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    try {
      final picked =
          await _picker.pickMultiImage(imageQuality: 85, maxWidth: 2000);
      if (picked.isNotEmpty) await _uploadAll(picked);
    } catch (e) {
      if (mounted) showMessage(context, 'Galeri açılamadı: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final photo = await _picker.pickImage(
          source: ImageSource.camera, imageQuality: 85, maxWidth: 2000);
      if (photo != null) await _uploadAll([photo]);
    } catch (e) {
      if (mounted) showMessage(context, 'Kamera açılamadı: $e');
    }
  }

  Future<void> _uploadAll(List<XFile> files) async {
    final items = files.map(_Pending.new).toList();
    setState(() => _pending.addAll(items));
    for (final p in items) {
      await _uploadOne(p);
    }
  }

  Future<void> _uploadOne(_Pending p) async {
    setState(() => p.failed = false);
    try {
      final photo = await _api.upload(p.file, placeId: widget.placeId);
      if (!mounted) return;
      setState(() {
        _pending.remove(p);
        _photos.add(photo);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => p.failed = true);
      showMessage(context, 'Yüklenemedi: $e');
    }
  }

  Future<bool> _deletePhoto(Photo photo) async {
    try {
      await _api.delete(photo.id);
      if (mounted) setState(() => _photos.removeWhere((p) => p.id == photo.id));
      return true;
    } catch (e) {
      if (mounted) showMessage(context, 'Silinemedi: $e');
      return false;
    }
  }

  void _openViewer(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoViewerPage(
          photos: _photos,
          initialIndex: index,
          onDelete: _access.canDelete ? _deletePhoto : null,
        ),
      ),
    );
  }

  // ---------- Yer işlemleri ----------

  Future<void> _edit({bool markVisited = false}) async {
    final updated = await Navigator.push<Place>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PlaceFormPage(existing: _place, markVisited: markVisited),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _place = updated);
      if (markVisited) showMessage(context, 'Gezilenlere taşındı 🎉');
    }
  }

  Future<void> _deletePlace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Yer silinsin mi?'),
        content: Text(
            '"${_place!.title}" ve ${_photos.length} fotoğrafı kalıcı olarak silinecek.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Vazgeç')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(d).colorScheme.error),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.deletePlace(widget.placeId);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showMessage(context, 'Silinemedi: $e');
    }
  }

  Future<void> _moveToPlanned() async {
    try {
      final updated =
          await _api.updatePlace(_place!.id, {'status': 'planned'});
      if (mounted) setState(() => _place = updated);
    } catch (e) {
      if (mounted) showMessage(context, 'Değiştirilemedi: $e');
    }
  }

  Future<void> _setRating(int? rating) async {
    final old = _place!;
    try {
      final updated = await _api.updatePlace(old.id, {'rating': rating});
      if (mounted) setState(() => _place = updated);
    } catch (e) {
      if (mounted) showMessage(context, 'Puan kaydedilemedi: $e');
    }
  }

  // ---------- Görünüm ----------

  @override
  Widget build(BuildContext context) {
    final p = _place;

    if (p == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tekrar dene'),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    if (_slow) ...[
                      const SizedBox(height: 16),
                      const Text('Sunucu uyanıyor…'),
                    ],
                  ],
                ),
        ),
      );
    }

    final theme = Theme.of(context);
    final visited = p.status == PlaceStatus.visited;

    return Scaffold(
      appBar: AppBar(
        title: Text(p.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_access.canEdit)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Düzenle',
              onPressed: () => _edit(),
            ),
          if (_access.canDelete || (visited && _access.canEdit))
            PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') _deletePlace();
              if (v == 'planned') _moveToPlanned();
            },
            itemBuilder: (_) => [
              if (visited && _access.canEdit)
                const PopupMenuItem(
                    value: 'planned', child: Text('Gezileceklere geri taşı')),
              if (_access.canDelete)
                const PopupMenuItem(value: 'delete', child: Text('Yeri sil')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            // Fotoğraf şeridi
            if (_photos.isNotEmpty || _pending.isNotEmpty || _access.canAdd)
            SizedBox(
              height: 140,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                children: [
                  for (var i = 0; i < _photos.length; i++)
                    _thumb(
                      onTap: () => _openViewer(i),
                      child: NetImage(_photos[i].url, cacheWidth: 360),
                    ),
                  for (final pe in _pending) _pendingThumb(pe),
                  if (_access.canAdd)
                  _thumb(
                    onTap: _showPhotoSourceSheet,
                    child: Container(
                      color: theme.colorScheme.secondaryContainer,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_a_photo_outlined,
                              color: theme.colorScheme.onSecondaryContainer),
                          const SizedBox(height: 4),
                          Text('Fotoğraf ekle',
                              style: TextStyle(
                                  color: theme.colorScheme.onSecondaryContainer,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            ListTile(
              leading: Icon(visited ? Icons.check_circle : Icons.flag_outlined,
                  color: visited ? Colors.green : theme.colorScheme.primary),
              title: Text(visited ? 'Gezildi' : 'Gezilecek'),
              subtitle: p.createdBy != null ? Text('Ekleyen: ${p.createdBy}') : null,
            ),
            if (p.date != null)
              ListTile(
                leading: const Icon(Icons.event_outlined),
                title: Text(formatDate(p.date!)),
                subtitle: Text(relativeDays(p.date!)),
              ),
            if (p.hasCoords)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: 170,
                    child: MapPreview(
                      key: ValueKey('${p.lat},${p.lng}'),
                      lat: p.lat!,
                      lng: p.lng!,
                      onTap: () => openInMaps(context, p),
                    ),
                  ),
                ),
              ),
            if (p.locationName != null || p.hasCoords)
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(p.locationName ?? 'Kaydedilen konum'),
                subtitle: p.hasCoords
                    ? Text(
                        '${p.lat!.toStringAsFixed(5)}, ${p.lng!.toStringAsFixed(5)}')
                    : null,
                trailing: const Icon(Icons.map_outlined),
                onTap: () => openInMaps(context, p),
              ),

            if (!visited && _access.canEdit)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: FilledButton.icon(
                  onPressed: () => _edit(markVisited: true),
                  icon: const Icon(Icons.check),
                  label: const Text('Gezildi olarak işaretle'),
                ),
              ),

            if (visited) ...[
              _section('Değerlendirme'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: StarRating(
                      value: p.rating,
                      size: 32,
                      onChanged: _access.canEdit ? _setRating : null),
                ),
              ),
              _section('Yorum'),
              _textBlock(
                  p.comment,
                  _access.canEdit
                      ? 'Henüz yorum yok. Düzenle ile ekleyebilirsin.'
                      : 'Henüz yorum yok.'),
            ],

            _section('Notlar'),
            _textBlock(p.notes, 'Not yok.'),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _textBlock(String? text, String empty) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          text ?? empty,
          style: text == null
              ? TextStyle(color: Theme.of(context).colorScheme.outline)
              : null,
        ),
      );

  Widget _thumb({required Widget child, VoidCallback? onTap}) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(width: 128, height: 128, child: child),
          ),
        ),
      );

  Widget _pendingThumb(_Pending p) => _thumb(
        onTap: p.failed ? () => _uploadOne(p) : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(File(p.file.path), fit: BoxFit.cover, cacheWidth: 360),
            Container(color: Colors.black45),
            Center(
              child: p.failed
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh, color: Colors.white),
                        Text('Tekrar dene',
                            style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    )
                  : const CircularProgressIndicator(color: Colors.white),
            ),
          ],
        ),
      );
}
