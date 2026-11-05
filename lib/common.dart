import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

const _months = [
  'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
  'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
];

/// 5 Kasım 2026
String formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// Bugüne göre kalan gün: "Bugün", "Yarın", "12 gün sonra", "3 gün önce"
String relativeDays(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Bugün';
  if (diff == 1) return 'Yarın';
  if (diff == -1) return 'Dün';
  return diff > 0 ? '$diff gün sonra' : '${-diff} gün önce';
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Yeri Google Haritalar'da (ya da varsayılan harita uygulamasında) aç.
Future<void> openInMaps(BuildContext context, Place p) async {
  final query = p.hasCoords ? '${p.lat},${p.lng}' : (p.locationName ?? p.title);
  final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(query)}');
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showMessage(context, 'Harita açılamadı');
}

/// Yıldızlarla puan. [onChanged] verilirse dokunarak değiştirilebilir.
class StarRating extends StatelessWidget {
  final int? value;
  final double size;
  final ValueChanged<int?>? onChanged;

  const StarRating({super.key, this.value, this.size = 20, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final color = Colors.amber.shade700;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final filled = value != null && i < value!;
        final icon = Icon(
          filled ? Icons.star_rounded : Icons.star_outline_rounded,
          color: filled ? color : Theme.of(context).colorScheme.outline,
          size: size,
        );
        if (onChanged == null) return icon;
        return InkResponse(
          radius: size,
          // Aynı yıldıza tekrar dokununca puan kaldırılır
          onTap: () => onChanged!(value == i + 1 ? null : i + 1),
          child: Padding(padding: const EdgeInsets.all(4), child: icon),
        );
      }),
    );
  }
}

/// Ağ resmi: yüklenirken ve hata olunca düzgün yer tutucu gösterir.
class NetImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final int? cacheWidth;

  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.cacheWidth});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Image.network(
      url,
      fit: fit,
      cacheWidth: cacheWidth,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : Container(color: bg),
      errorBuilder: (_, __, ___) => Container(
        color: bg,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}

/// Tam ekran fotoğraf görüntüleyici (kaydırarak geçiş, yakınlaştırma, silme).
class PhotoViewerPage extends StatefulWidget {
  final List<Photo> photos;
  final int initialIndex;
  final Future<bool> Function(Photo photo)? onDelete;

  const PhotoViewerPage({
    super.key,
    required this.photos,
    this.initialIndex = 0,
    this.onDelete,
  });

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late final List<Photo> _photos = List.of(widget.photos);
  late int _index = widget.initialIndex;

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
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
    if (ok != true || !mounted) return;
    final photo = _photos[_index];
    final deleted = await widget.onDelete!(photo);
    if (!deleted || !mounted) return;
    if (_photos.length == 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _photos.removeAt(_index);
      if (_index >= _photos.length) _index = _photos.length - 1;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: _photos.length > 1 ? Text('${_index + 1} / ${_photos.length}') : null,
        actions: [
          if (widget.onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Sil',
              onPressed: _delete,
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _photos.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          child: Center(
            child: Image.network(
              _photos[i].url,
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
    );
  }
}
