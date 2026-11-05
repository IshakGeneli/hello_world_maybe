import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';
import 'photos_page.dart';
import 'place_detail_page.dart';
import 'place_form_page.dart';

/// Ana ekran: Gezilecek / Gezilen sekmeleri.
class AgendaPage extends StatefulWidget {
  const AgendaPage({super.key});

  @override
  State<AgendaPage> createState() => _AgendaPageState();
}

class _AgendaPageState extends State<AgendaPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  /// Değişince iki sekme de listeyi yeniden yükler.
  final ValueNotifier<int> _refresh = ValueNotifier(0);

  @override
  void dispose() {
    _tabs.dispose();
    _refresh.dispose();
    super.dispose();
  }

  Future<void> _addPlace() async {
    final status = _tabs.index == 0 ? PlaceStatus.planned : PlaceStatus.visited;
    final created = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => PlaceFormPage(initialStatus: status)),
    );
    if (created == null || !mounted) return;
    _refresh.value++;
    await _openPlace(created);
  }

  Future<void> _openPlace(Place place) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlaceDetailPage(placeId: place.id)),
    );
    // Detayda değişiklik olmuş olabilir (puan, durum, foto…)
    if (mounted) _refresh.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gezi Ajandam'),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Tüm fotoğraflar',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PhotosPage()),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.flag_outlined), text: 'Gezilecek'),
            Tab(icon: Icon(Icons.check_circle_outline), text: 'Gezilen'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _PlaceList(
              status: PlaceStatus.planned, refresh: _refresh, onOpen: _openPlace),
          _PlaceList(
              status: PlaceStatus.visited, refresh: _refresh, onOpen: _openPlace),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPlace,
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Yer ekle'),
      ),
    );
  }
}

class _PlaceList extends StatefulWidget {
  final PlaceStatus status;
  final ValueNotifier<int> refresh;
  final Future<void> Function(Place) onOpen;

  const _PlaceList({
    required this.status,
    required this.refresh,
    required this.onOpen,
  });

  @override
  State<_PlaceList> createState() => _PlaceListState();
}

class _PlaceListState extends State<_PlaceList>
    with AutomaticKeepAliveClientMixin {
  final PhotoApi _api = PhotoApi();
  List<Place>? _places;
  bool _loading = true;
  bool _slow = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _places == null;
      _error = null;
      _slow = false;
    });
    final slowTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _loading) setState(() => _slow = true);
    });
    try {
      final list = await _api.places(widget.status);
      if (mounted) setState(() => _places = list);
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Sunucu yanıt vermedi.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Liste yüklenemedi: $e');
    } finally {
      slowTimer.cancel();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
                : 'Yükleniyor…'),
          ],
        ),
      );
    }

    if (_error != null && _places == null) {
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

    final places = _places ?? [];
    final planned = widget.status == PlaceStatus.planned;

    return RefreshIndicator(
      onRefresh: _load,
      child: places.isEmpty
          ? ListView(
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.55,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(planned ? Icons.travel_explore : Icons.luggage_outlined,
                              size: 72, color: theme.colorScheme.primary),
                          const SizedBox(height: 16),
                          Text(
                            planned
                                ? 'Henüz gezilecek yer yok'
                                : 'Henüz gezilen yer yok',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            planned
                                ? 'Gitmek istediğin yerleri "Yer ekle" ile ekle.'
                                : 'Gezdiğin yerleri ekle ya da gezilecek bir yeri "Gezildi" olarak işaretle.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: places.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _PlaceCard(
                place: places[i],
                onTap: () => widget.onOpen(places[i]),
              ),
            ),
    );
  }
}

class _PlaceCard extends StatelessWidget {
  final Place place;
  final VoidCallback onTap;

  const _PlaceCard({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = place;
    final planned = p.status == PlaceStatus.planned;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: p.coverUrl != null
                      ? NetImage(p.coverUrl!, cacheWidth: 240)
                      : Container(
                          color: theme.colorScheme.primaryContainer,
                          child: Icon(
                            planned ? Icons.flag_outlined : Icons.place_outlined,
                            color: theme.colorScheme.onPrimaryContainer,
                            size: 32,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    if (p.locationName != null) ...[
                      const SizedBox(height: 2),
                      Row(children: [
                        Icon(Icons.place_outlined,
                            size: 14, color: theme.colorScheme.outline),
                        const SizedBox(width: 2),
                        Expanded(
                          child: Text(p.locationName!,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                    ],
                    if (p.date != null) ...[
                      const SizedBox(height: 2),
                      Row(children: [
                        Icon(Icons.event_outlined,
                            size: 14, color: theme.colorScheme.outline),
                        const SizedBox(width: 2),
                        Text(
                          planned
                              ? '${formatDate(p.date!)} · ${relativeDays(p.date!)}'
                              : formatDate(p.date!),
                          style: theme.textTheme.bodySmall,
                        ),
                      ]),
                    ],
                    const SizedBox(height: 4),
                    Row(children: [
                      if (!planned) StarRating(value: p.rating, size: 16),
                      if (!planned && p.photoCount > 0) const SizedBox(width: 8),
                      if (p.photoCount > 0) ...[
                        Icon(Icons.photo_outlined,
                            size: 14, color: theme.colorScheme.outline),
                        const SizedBox(width: 2),
                        Text('${p.photoCount}', style: theme.textTheme.bodySmall),
                      ],
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
