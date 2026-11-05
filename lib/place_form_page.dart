import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'common.dart';
import 'location_picker_page.dart';
import 'osm.dart';

/// Yer ekleme / düzenleme formu. Kaydedince güncel [Place] ile geri döner.
class PlaceFormPage extends StatefulWidget {
  final Place? existing;
  final PlaceStatus initialStatus;

  /// "Gezildi olarak işaretle": durumu gezildi yapar, tarih yoksa bugünü koyar.
  final bool markVisited;

  const PlaceFormPage({
    super.key,
    this.existing,
    this.initialStatus = PlaceStatus.planned,
    this.markVisited = false,
  });

  @override
  State<PlaceFormPage> createState() => _PlaceFormPageState();
}

class _PlaceFormPageState extends State<PlaceFormPage> {
  final _formKey = GlobalKey<FormState>();
  final PhotoApi _api = PhotoApi();

  late final PlaceInput _input = _initialInput();

  PlaceInput _initialInput() {
    final input = widget.existing != null
        ? PlaceInput.from(widget.existing!)
        : PlaceInput(status: widget.initialStatus);
    if (widget.markVisited) {
      input.status = PlaceStatus.visited;
      final now = DateTime.now();
      // Planlanan tarih gelecekteyse gezilen tarih olarak bugünü al
      if (input.date == null || input.date!.isAfter(now)) {
        input.date = DateTime(now.year, now.month, now.day);
      }
    }
    return input;
  }

  late final _title = TextEditingController(text: _input.title);
  late final _location = TextEditingController(text: _input.locationName ?? '');
  late final _notes = TextEditingController(text: _input.notes ?? '');
  late final _comment = TextEditingController(text: _input.comment ?? '');

  bool _saving = false;
  bool _locating = false;

  bool get _editing => widget.existing != null;
  bool get _visited => _input.status == PlaceStatus.visited;

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _input.date ?? now,
      firstDate: DateTime(1950),
      lastDate: DateTime(now.year + 20),
      helpText: _visited ? 'Gezdiğin tarih' : 'Gitmeyi planladığın tarih',
    );
    if (picked != null) setState(() => _input.date = picked);
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) showMessage(context, 'Telefonun konum servisi kapalı. Açıp tekrar dene.');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        if (mounted) showMessage(context, 'Konum izni verilmedi.');
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Konum izni kapalı. Ayarlardan açman gerekiyor.'),
            action: SnackBarAction(
                label: 'Ayarlar', onPressed: Geolocator.openAppSettings),
          ));
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      setState(() {
        _input.lat = pos.latitude;
        _input.lng = pos.longitude;
      });
      // Konum adı boşsa adresi otomatik doldur
      if (_location.text.trim().isEmpty) {
        final name = await Osm.reverse(pos.latitude, pos.longitude);
        if (name != null && mounted && _location.text.trim().isEmpty) {
          _location.text = name;
        }
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Konum alınamadı: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickOnMap() async {
    FocusScope.of(context).unfocus();
    final picked = await Navigator.push<PickedLocation>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          lat: _input.lat,
          lng: _input.lng,
          // Koordinat yoksa yazılan adı ya da yer adını aramaya hazırla
          initialQuery: _input.lat == null
              ? (_location.text.trim().isNotEmpty
                  ? _location.text.trim()
                  : _title.text.trim())
              : null,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _input.lat = picked.lat;
      _input.lng = picked.lng;
      if (picked.name != null) _location.text = picked.name!;
    });
  }

  String? _clean(String s) => s.trim().isEmpty ? null : s.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    _input
      ..title = _title.text.trim()
      ..locationName = _clean(_location.text)
      ..notes = _clean(_notes.text)
      ..comment = _visited ? _clean(_comment.text) : _input.comment;

    setState(() => _saving = true);
    try {
      final saved = _editing
          ? await _api.updatePlace(widget.existing!.id, _input.toJson())
          : await _api.createPlace(_input);
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) showMessage(context, 'Kaydedilemedi: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Yeri düzenle' : 'Yeni yer'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Kaydet'),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<PlaceStatus>(
              segments: const [
                ButtonSegment(
                    value: PlaceStatus.planned,
                    icon: Icon(Icons.flag_outlined),
                    label: Text('Gezilecek')),
                ButtonSegment(
                    value: PlaceStatus.visited,
                    icon: Icon(Icons.check_circle_outline),
                    label: Text('Gezildi')),
              ],
              selected: {_input.status},
              onSelectionChanged: (s) => setState(() => _input.status = s.first),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _title,
              autofocus: !_editing,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Yer adı *',
                hintText: 'ör. Kapadokya',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Yer adı gerekli' : null,
            ),
            const SizedBox(height: 12),

            // Tarih
            InputDecorator(
              decoration: InputDecoration(
                labelText: _visited ? 'Gezdiğin tarih' : 'Planlanan tarih',
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              child: Row(
                children: [
                  const Icon(Icons.event_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          padding: EdgeInsets.zero),
                      onPressed: _pickDate,
                      child: Text(_input.date == null
                          ? 'Tarih seç'
                          : formatDate(_input.date!)),
                    ),
                  ),
                  if (_input.date != null)
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Tarihi kaldır',
                      onPressed: () => setState(() => _input.date = null),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Konum
            TextFormField(
              controller: _location,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Konum',
                hintText: 'ör. Göreme, Nevşehir',
                prefixIcon: Icon(Icons.place_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _pickOnMap,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Haritadan seç'),
                ),
                OutlinedButton.icon(
                  onPressed: _locating ? null : _useMyLocation,
                  icon: _locating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.my_location),
                  label: const Text('Şu anki konumum'),
                ),
              ],
            ),
            if (_input.lat != null && _input.lng != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 160,
                  child: Stack(
                    children: [
                      MapPreview(
                        key: ValueKey('${_input.lat},${_input.lng}'),
                        lat: _input.lat!,
                        lng: _input.lng!,
                        onTap: _pickOnMap,
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: IconButton.filledTonal(
                          icon: const Icon(Icons.close),
                          tooltip: 'Konumu kaldır',
                          onPressed: () => setState(() {
                            _input.lat = null;
                            _input.lng = null;
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_input.lat!.toStringAsFixed(5)}, ${_input.lng!.toStringAsFixed(5)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),

            TextFormField(
              controller: _notes,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Notlar',
                hintText: 'Görülecekler, ulaşım, rezervasyon…',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),

            if (_visited) ...[
              const SizedBox(height: 20),
              Text('Değerlendirme', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              StarRating(
                value: _input.rating,
                size: 36,
                onChanged: (v) => setState(() => _input.rating = v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _comment,
                minLines: 3,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Yorum',
                  hintText: 'Nasıldı? Tavsiye eder misin?',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
