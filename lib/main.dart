import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hello World',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// Henüz yüklenmekte olan fotoğraf (ızgarada yer tutucu olarak görünür).
class _Pending {
  final XFile file;
  bool failed = false;
  _Pending(this.file);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  final PhotoApi _api = PhotoApi();

  List<Photo> _photos = [];
  final List<_Pending> _pending = [];
  bool _loading = true;
  bool _slow = false; // sunucu uyanıyor mesajı için
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _photos.isEmpty;
      _error = null;
      _slow = false;
    });
    final slowTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _loading) setState(() => _slow = true);
    });
    try {
      final list = await _api.list();
      if (!mounted) return;
      setState(() => _photos = list);
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Sunucu yanıt vermedi. Tekrar dene.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Fotoğraflar yüklenemedi: $e');
    } finally {
      slowTimer.cancel();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _uploadAll(List<XFile> files) async {
    final items = files.map(_Pending.new).toList();
    setState(() => _pending.insertAll(0, items));
    // Sırayla yükle: ücretsiz sunucuyu yormamak için
    for (final p in items) {
      await _uploadOne(p);
    }
  }

  Future<void> _uploadOne(_Pending p) async {
    setState(() => p.failed = false);
    try {
      final photo = await _api.upload(p.file);
      if (!mounted) return;
      setState(() {
        _pending.remove(p);
        _photos.insert(0, photo);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => p.failed = true);
      _showMessage('Yüklenemedi: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final picked = await _picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 2000,
      );
      if (picked.isNotEmpty) await _uploadAll(picked);
    } catch (e) {
      _showMessage('Galeri açılamadı: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 2000,
      );
      if (photo != null) await _uploadAll([photo]);
    } catch (e) {
      _showMessage('Kamera açılamadı: $e');
    }
  }

  Future<void> _delete(Photo photo) async {
    final index = _photos.indexOf(photo);
    setState(() => _photos.remove(photo));
    try {
      await _api.delete(photo.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _photos.insert(index < 0 ? 0 : index, photo));
      _showMessage('Silinemedi: $e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _showSourceSheet() {
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

  void _openPhoto(Photo photo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Sil',
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: ctx,
                    builder: (d) => AlertDialog(
                      title: const Text('Fotoğraf silinsin mi?'),
                      content: const Text('Sunucudan da silinecek.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('Vazgeç')),
                        FilledButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: const Text('Sil')),
                      ],
                    ),
                  );
                  if (ok == true && ctx.mounted) {
                    Navigator.pop(ctx);
                    _delete(photo);
                  }
                },
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image.network(
                photo.url,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const CircularProgressIndicator(color: Colors.white),
                errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 64),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);

    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_slow
                ? 'Sunucu uyanıyor, bu bir dakika kadar sürebilir…'
                : 'Fotoğraflar yükleniyor…'),
          ],
        ),
      );
    }

    if (_error != null && _photos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Tekrar dene'),
              ),
            ],
          ),
        ),
      );
    }

    final count = _pending.length + _photos.length;

    return RefreshIndicator(
      onRefresh: _load,
      child: count == 0
          ? ListView(
              // RefreshIndicator için kaydırılabilir olmalı
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.6,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined,
                          size: 72, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      Text('Merhaba Dünya! 👋',
                          style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      const Text('Fotoğraf eklemek için butona bas.'),
                    ],
                  ),
                ),
              ],
            )
          : GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemCount: count,
              itemBuilder: (_, i) {
                if (i < _pending.length) return _pendingTile(_pending[i]);
                final photo = _photos[i - _pending.length];
                return GestureDetector(
                  onTap: () => _openPhoto(photo),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      photo.url,
                      fit: BoxFit.cover,
                      cacheWidth: 400,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : Container(color: theme.colorScheme.surfaceContainerHighest),
                      errorBuilder: (_, __, ___) => Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _pendingTile(_Pending p) {
    return GestureDetector(
      onTap: p.failed ? () => _uploadOne(p) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(File(p.file.path), fit: BoxFit.cover, cacheWidth: 400),
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
                  : const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 3),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fotoğraflarım'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Yenile',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showSourceSheet,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('Fotoğraf ekle'),
      ),
    );
  }
}
