import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';

/// Bana gelen davetler ve katıldığım ajandalar.
class InvitationsPage extends StatefulWidget {
  const InvitationsPage({super.key});

  @override
  State<InvitationsPage> createState() => _InvitationsPageState();
}

class _InvitationsPageState extends State<InvitationsPage> {
  final PhotoApi _api = PhotoApi();
  List<Invitation>? _pending;
  List<Agenda> _joined = [];
  String? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results =
          await Future.wait([_api.receivedInvitations(), _api.agendas()]);
      if (!mounted) return;
      setState(() {
        _pending = results[0] as List<Invitation>;
        _joined =
            (results[1] as List<Agenda>).where((a) => !a.isOwner).toList();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Yüklenemedi: $e');
    }
  }

  Future<void> _respond(Invitation inv, bool accept) async {
    setState(() => _busy.add(inv.id));
    try {
      if (accept) {
        await _api.acceptInvitation(inv.id);
      } else {
        await _api.declineInvitation(inv.id);
      }
      if (!mounted) return;
      showMessage(
          context,
          accept
              ? 'Ajandaya katıldın: ${inv.owner?.name ?? ''}. Üstteki ajanda adına dokunarak geçiş yapabilirsin.'
              : 'Davet reddedildi');
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, 'Yapılamadı: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(inv.id));
    }
  }

  Future<void> _leave(Agenda a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Ajandadan ayrılınsın mı?'),
        content: Text(
            '${a.ownerName} kişisinin paylaştığı ajandayı artık göremezsin. Tekrar katılmak için yeni davet gerekir.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Ayrıl')),
        ],
      ),
    );
    if (ok != true || a.invitationId == null) return;
    try {
      await _api.deleteInvitation(a.invitationId!);
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, 'Ayrılamadı: $e');
    }
  }

  String _permText(bool add, bool edit, bool del) {
    final p = [if (add) 'ekleme', if (edit) 'düzenleme', if (del) 'silme'];
    return p.isEmpty ? 'Sadece görüntüleme' : 'Yetkiler: ${p.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = _pending;

    if (pending == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Davetler')),
        body: Center(
          child: _error != null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: _load, child: const Text('Tekrar dene')),
                ])
              : const CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Davetler')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text('Bekleyen davetler', style: theme.textTheme.titleSmall),
            ),
            if (pending.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 0, 4, 16),
                child: Text('Bekleyen davetin yok.'),
              ),
            for (final inv in pending)
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: const CircleAvatar(
                            child: Icon(Icons.mail_outline)),
                        title: Text(
                            '${inv.owner?.name ?? 'Biri'} seni gezi ajandasına davet etti'),
                        subtitle: Text(
                            '${inv.owner?.email ?? ''}\n${_permText(inv.canAdd, inv.canEdit, inv.canDelete)}'),
                        isThreeLine: true,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _busy.contains(inv.id)
                                ? null
                                : () => _respond(inv, false),
                            child: const Text('Reddet'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _busy.contains(inv.id)
                                ? null
                                : () => _respond(inv, true),
                            child: const Text('Kabul et'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text('Katıldığın ajandalar',
                  style: theme.textTheme.titleSmall),
            ),
            if (_joined.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('Henüz başka bir ajandaya katılmadın.'),
              ),
            for (final a in _joined)
              Card(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.group_outlined)),
                  title: Text(a.ownerName),
                  subtitle: Text('${a.ownerEmail}\n${a.permissionSummary}'),
                  isThreeLine: true,
                  trailing: TextButton(
                    onPressed: () => _leave(a),
                    child: const Text('Ayrıl'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
