import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common.dart';
import 'osm.dart';

/// Haritadan seçilen konum.
class PickedLocation {
  final double lat;
  final double lng;
  final String? name;
  const PickedLocation(this.lat, this.lng, this.name);
}

/// Ortak OpenStreetMap katmanları (harita karosu + zorunlu telif yazısı).
List<Widget> osmLayers({List<Marker> markers = const []}) => [
      TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.example.hello_world',
      ),
      if (markers.isNotEmpty) MarkerLayer(markers: markers),
      RichAttributionWidget(
        attributions: [
          TextSourceAttribution(
            'OpenStreetMap katkıcıları',
            onTap: () => launchUrl(
              Uri.parse('https://openstreetmap.org/copyright'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
    ];

Marker pinMarker(LatLng point) => Marker(
      point: point,
      width: 48,
      height: 48,
      alignment: Alignment.topCenter,
      child: const Icon(Icons.location_on, color: Colors.red, size: 48),
    );

/// Küçük, kaydırılamayan harita önizlemesi (form ve detay ekranı için).
class MapPreview extends StatelessWidget {
  final double lat;
  final double lng;
  final VoidCallback? onTap;

  const MapPreview({super.key, required this.lat, required this.lng, this.onTap});

  @override
  Widget build(BuildContext context) {
    final point = LatLng(lat, lng);
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: point,
            initialZoom: 14,
            interactionOptions:
                const InteractionOptions(flags: InteractiveFlag.none),
          ),
          children: osmLayers(markers: [pinMarker(point)]),
        ),
        if (onTap != null)
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: onTap),
            ),
          ),
      ],
    );
  }
}

/// Haritada iğneyi yerleştirerek ya da adla arayarak konum seçme ekranı.
/// Seçince [PickedLocation] ile geri döner.
class LocationPickerPage extends StatefulWidget {
  final double? lat;
  final double? lng;
  /// Arama kutusuna önceden yazılacak metin (ör. formdaki konum adı).
  final String? initialQuery;

  const LocationPickerPage({super.key, this.lat, this.lng, this.initialQuery});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  // Konum yoksa Türkiye'nin ortasından başla
  static const _turkey = LatLng(39.0, 35.2);

  final MapController _map = MapController();
  late final TextEditingController _query =
      TextEditingController(text: widget.initialQuery ?? '');
  final FocusNode _queryFocus = FocusNode();

  late LatLng _center = widget.lat != null && widget.lng != null
      ? LatLng(widget.lat!, widget.lng!)
      : _turkey;

  /// Aramadan seçilen yerin adı; harita elle kaydırılınca silinir.
  String? _pickedName;
  List<OsmPlace>? _results;
  bool _searching = false;
  bool _locating = false;
  bool _confirming = false;

  bool get _hasInitial => widget.lat != null && widget.lng != null;

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    _map.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    _queryFocus.unfocus();
    setState(() {
      _searching = true;
      _results = null;
    });
    try {
      final r = await Osm.search(q);
      if (!mounted) return;
      setState(() => _results = r);
      if (r.isEmpty) showMessage(context, 'Sonuç bulunamadı');
    } catch (e) {
      if (mounted) showMessage(context, 'Arama yapılamadı: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _selectResult(OsmPlace p) {
    final point = LatLng(p.lat, p.lng);
    _map.move(point, 15);
    setState(() {
      _center = point;
      _pickedName = p.shortName;
      _results = null;
    });
  }

  Future<void> _goToMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) showMessage(context, 'Telefonun konum servisi kapalı.');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) showMessage(context, 'Konum izni verilmedi.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      final point = LatLng(pos.latitude, pos.longitude);
      _map.move(point, 16);
      setState(() {
        _center = point;
        _pickedName = null;
      });
    } catch (e) {
      if (mounted) showMessage(context, 'Konum alınamadı: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _confirm() async {
    setState(() => _confirming = true);
    // Aramadan gelmediyse iğnenin olduğu yerin adresini bul
    final name =
        _pickedName ?? await Osm.reverse(_center.latitude, _center.longitude);
    if (!mounted) return;
    Navigator.pop(
        context, PickedLocation(_center.latitude, _center.longitude, name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Haritadan konum seç')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: _hasInitial ? 15 : 5.5,
              onTap: (_, point) {
                _map.move(point, _map.camera.zoom);
                setState(() {
                  _center = point;
                  _pickedName = null;
                  _results = null;
                });
              },
              onPositionChanged: (camera, hasGesture) {
                _center = camera.center;
                if (hasGesture && (_pickedName != null || _results != null)) {
                  setState(() {
                    _pickedName = null;
                    _results = null;
                  });
                }
              },
            ),
            children: osmLayers(),
          ),

          // Ortada sabit iğne: seçilen konum haritanın ortası
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 48),
                child: Icon(Icons.location_on,
                    size: 48, color: Colors.red.shade600,
                    shadows: const [Shadow(blurRadius: 6, color: Colors.black38)]),
              ),
            ),
          ),

          // Arama kutusu ve sonuçlar
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Column(
              children: [
                Material(
                  elevation: 3,
                  borderRadius: BorderRadius.circular(28),
                  child: TextField(
                    controller: _query,
                    focusNode: _queryFocus,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: 'Yer ara (ör. Galata Kulesi)',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(
                              icon: const Icon(Icons.arrow_forward),
                              tooltip: 'Ara',
                              onPressed: _search,
                            ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_results != null && _results!.isNotEmpty)
                  Card(
                    margin: const EdgeInsets.only(top: 8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _results!.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final r = _results![i];
                          return ListTile(
                            leading: const Icon(Icons.place_outlined),
                            title: Text(r.shortName,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(r.displayName,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => _selectResult(r),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Konumuma git
          Positioned(
            right: 12,
            bottom: 120,
            child: FloatingActionButton.small(
              heroTag: 'myloc',
              onPressed: _locating ? null : _goToMyLocation,
              tooltip: 'Konumuma git',
              child: _locating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location),
            ),
          ),

          // Onay
          Positioned(
            left: 16,
            right: 16,
            bottom: 40,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  textStyle: theme.textTheme.titleMedium),
              onPressed: _confirming ? null : _confirm,
              icon: _confirming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(_pickedName != null
                  ? 'Seç: $_pickedName'
                  : 'Bu konumu seç'),
            ),
          ),
        ],
      ),
    );
  }
}
