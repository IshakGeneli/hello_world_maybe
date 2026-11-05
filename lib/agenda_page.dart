import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';
import 'invitations_page.dart';
import 'place_detail_page.dart';
import 'place_form_page.dart';
import 'session.dart';
import 'sharing_page.dart';

/// Ana ekran: seçili ajandanın Gezilecek / Gezilen sekmeleri.
class AgendaPage extends StatefulWidget {
  const AgendaPage({super.key});

  @override
  State<AgendaPage> createState() => _AgendaPageState();
}

class _AgendaPageState extends State<AgendaPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final PhotoApi _api = PhotoApi();

  /// Değişince iki sekme de listeyi yeniden yükler.
  final ValueNotifier<int> _refresh = ValueNotifier(0);

  late Agenda _current = _ownAgenda();
  List<Agenda> _agendas = [];
  int _pendingInvitations = 0;

  Agenda _ownAgenda() {
    final u = Session.instance.user!;
    return Agenda(
        id: u.id, ownerName: u.name, ownerEmail: u.email, access: Access.owner);
  }

  @override
  void initState() {
    super.initState();
    _loadAgendas();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _refresh.dispose();
    super.dispose();
  }

  Future<void> _loadAgendas() async {
    try {
      final results = await Future.wait([_api.agendas(), _api.pendingInvitations()]);
      if (!mounted) return;
      final agendas = results[0] as List<Agenda>;
      setState(() {
        _agendas = agendas;
        _pendingInvitations = results[1] as int;
        // Seçili ajanda hâlâ erişilebilir mi? Yetkileri güncelle; değilse kendi ajandama dön
        _current = agendas.firstWhere((a) => a.id == _current.id,
            orElse: () => agendas.firstWhere((a) => a.isOwner,
                orElse: _ownAgenda));
      });
    } catch (_) {
      // Liste yüklenemezse kendi ajandamla devam
    }
  }

  void _switchTo(Agenda a) {
    if (a.id == _current.id) return;
    setState(() => _current = a);
  }

  Future<void> _addPlace() async {
    final status = _tabs.index == 0 ? PlaceStatus.planned : PlaceStatus.visited;
    final created = await Navigator.push<Place>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PlaceFormPage(agendaId: _current.id, initialStatus: status),
      ),
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
    if (mounted) _refresh.value++;
  }

  Future<void> _openInvitations() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InvitationsPage()),
    );
    // Davet kabul edildiyse yeni ajanda listede görünsün
    await _loadAgendas();
  }

  Future<void> _openSharing() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SharingPage()),
    );
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Çıkış yapılsın mı?'),
        content: Text(Session.instance.user!.email),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Çıkış yap')),
        ],
      ),
    );
    if (ok == true) await Session.instance.signOut();
  }

  Widget _title() {
    final theme = Theme.of(context);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_current.title, overflow: TextOverflow.ellipsis),
        if (!_current.isOwner)
          Text('Paylaşılan ajanda',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
    if (_agendas.length <= 1) return title;

    return PopupMenuButton<Agenda>(
      tooltip: 'Ajanda değiştir',
      onSelected: _switchTo,
      itemBuilder: (_) => [
        for (final a in _agendas)
          PopupMenuItem(
            value: a,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(a.isOwner ? Icons.person : Icons.group_outlined),
              title: Text(a.title),
              subtitle: Text(a.isOwner ? a.ownerEmail : a.permissionSummary),
              trailing: a.id == _current.id ? const Icon(Icons.check) : null,
            ),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: title),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: _title(),
        actions: [
          IconButton(
            tooltip: 'Davetler',
            onPressed: _openInvitations,
            icon: Badge(
              isLabelVisible: _pendingInvitations > 0,
              label: Text('$_pendingInvitations'),
              child: const Icon(Icons.mail_outline),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'share') _openSharing();
              if (v == 'signout') _signOut();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'share',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.person_add_alt),
                  title: Text('Ajandamı paylaş'),
                ),
              ),
              PopupMenuItem(
                value: 'signout',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout),
                  title: const Text('Çıkış yap'),
                  subtitle: Text(Session.instance.user!.email),
                ),
              ),
            ],
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
      body: Column(
        children: [
          if (!_current.isOwner)
            Container(
              width: double.infinity,
              color: theme.colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '${_current.ownerName} seninle paylaştı · ${_current.permissionSummary}',
                style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _PlaceList(
                  key: ValueKey('${_current.id}-planned'),
                  agendaId: _current.id,
                  status: PlaceStatus.planned,
                  refresh: _refresh,
                  onOpen: _openPlace,
                  onForbidden: _loadAgendas,
                ),
                _PlaceList(
                  key: ValueKey('${_current.id}-visited'),
                  agendaId: _current.id,
                  status: PlaceStatus.visited,
                  refresh: _refresh,
                  onOpen: _openPlace,
                  onForbidden: _loadAgendas,
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _current.access.canAdd
          ? FloatingActionButton.extended(
              onPressed: _addPlace,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Yer ekle'),
            )
          : null,
    );
  }
}

class _PlaceList extends StatefulWidget {
  final int agendaId;
  final PlaceStatus status;
  final ValueNotifier<int> refresh;
  final Future<void> Function(Place) onOpen;

  /// Ajandaya erişim kalktıysa (üyelikten çıkarıldıysa) çağrılır.
  final VoidCallback onForbidden;

  const _PlaceList({
    super.key,
    required this.agendaId,
    required this.status,
    required this.refresh,
    required this.onOpen,
    required this.onForbidden,
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
      final list = await _api.places(widget.agendaId, widget.status);
      if (mounted) setState(() => _places = list);
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Sunucu yanıt vermedi.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      if (e.statusCode == 404 || e.statusCode == 403) widget.onForbidden();
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
    final me = Session.instance.user;

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
                      // Başkası eklediyse kimin eklediğini göster
                      if (p.createdBy != null && p.createdBy != me?.name) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.person_outline,
                            size: 14, color: theme.colorScheme.outline),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(p.createdBy!,
                              style: theme.textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis),
                        ),
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
