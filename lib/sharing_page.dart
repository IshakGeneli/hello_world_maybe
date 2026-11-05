import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';

/// Ajandamı paylaş: kişi davet et, üyelerin yetkilerini değiştir, üyeyi çıkar.
class SharingPage extends StatefulWidget {
  const SharingPage({super.key});

  @override
  State<SharingPage> createState() => _SharingPageState();
}

class _SharingPageState extends State<SharingPage> {
  final PhotoApi _api = PhotoApi();
  List<Invitation>? _items;
  String? _error;

  /// Değiştirilmekte olan davetler (switch'ler kilitlensin diye).
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await _api.sentInvitations();
      // Reddedenleri en alta al
      list.sort((a, b) => (a.status == InvitationStatus.declined ? 1 : 0)
          .compareTo(b.status == InvitationStatus.declined ? 1 : 0));
      if (mounted) setState(() => _items = list);
    } catch (e) {
      if (mounted) setState(() => _error = 'Yüklenemedi: $e');
    }
  }

  Future<void> _invite() async {
    final result = await showModalBottomSheet<Invitation>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _InviteSheet(),
    );
    if (result == null || !mounted) return;
    showMessage(
      context,
      result.memberName != null
          ? 'Davet gönderildi: ${result.memberName}'
          : 'Davet kaydedildi. ${result.email} bu e-postayla hesap açınca daveti görecek.',
    );
    await _load();
  }

  Future<void> _setPermission(Invitation inv,
      {bool? canAdd, bool? canEdit, bool? canDelete}) async {
    setState(() => _busy.add(inv.id));
    try {
      final updated = await _api.updateInvitation(inv.id,
          canAdd: canAdd, canEdit: canEdit, canDelete: canDelete);
      if (!mounted) return;
      setState(() {
        final i = _items!.indexWhere((x) => x.id == inv.id);
        if (i >= 0) _items![i] = updated;
      });
    } catch (e) {
      if (mounted) showMessage(context, 'Değiştirilemedi: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(inv.id));
    }
  }

  Future<void> _remove(Invitation inv) async {
    final who = inv.memberName ?? inv.email;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(inv.status == InvitationStatus.accepted
            ? '$who ajandadan çıkarılsın mı?'
            : 'Davet geri alınsın mı?'),
        content: const Text('Bu kişi artık ajandanı göremeyecek.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Çıkar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteInvitation(inv.id);
      if (mounted) setState(() => _items!.removeWhere((x) => x.id == inv.id));
    } catch (e) {
      if (mounted) showMessage(context, 'Çıkarılamadı: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;

    Widget body;
    if (items == null) {
      body = Center(
        child: _error != null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!),
                const SizedBox(height: 12),
                FilledButton(onPressed: _load, child: const Text('Tekrar dene')),
              ])
            : const CircularProgressIndicator(),
      );
    } else if (items.isEmpty) {
      body = ListView(children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.group_add_outlined,
                    size: 72, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text('Ajandanı henüz kimseyle paylaşmadın',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text(
                  'Davet ettiğin kişi ajandanı görür ve yer ekleyebilir. '
                  'Düzenleme ve silme iznini sen verirsin.',
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
          ),
        ),
      ]);
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _memberCard(items[i]),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ajandamı paylaş')),
      body: RefreshIndicator(onRefresh: _load, child: body),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _invite,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Kişi davet et'),
      ),
    );
  }

  Widget _memberCard(Invitation inv) {
    final theme = Theme.of(context);
    final busy = _busy.contains(inv.id);
    final declined = inv.status == InvitationStatus.declined;

    final (statusText, statusColor) = switch (inv.status) {
      InvitationStatus.accepted => ('Katıldı', Colors.green),
      InvitationStatus.pending => (
          inv.memberName == null ? 'Bekliyor · hesabı yok' : 'Bekliyor',
          Colors.orange
        ),
      InvitationStatus.declined => ('Reddetti', theme.colorScheme.error),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                child: Text((inv.memberName ?? inv.email)
                    .characters
                    .first
                    .toUpperCase()),
              ),
              title: Text(inv.memberName ?? inv.email),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (inv.memberName != null) Text(inv.email),
                  Text(statusText,
                      style: TextStyle(
                          color: statusColor, fontWeight: FontWeight.w600)),
                ],
              ),
              isThreeLine: inv.memberName != null,
              trailing: IconButton(
                icon: const Icon(Icons.person_remove_outlined),
                tooltip: 'Çıkar',
                onPressed: () => _remove(inv),
              ),
            ),
            if (declined)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      try {
                        await _api.invite(inv.email,
                            canAdd: inv.canAdd,
                            canEdit: inv.canEdit,
                            canDelete: inv.canDelete);
                        if (mounted) showMessage(context, 'Davet yeniden gönderildi');
                        await _load();
                      } catch (e) {
                        if (mounted) showMessage(context, 'Gönderilemedi: $e');
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Yeniden davet et'),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    _permChip('Ekleme', Icons.add, inv.canAdd, busy,
                        (v) => _setPermission(inv, canAdd: v)),
                    _permChip('Düzenleme', Icons.edit_outlined, inv.canEdit, busy,
                        (v) => _setPermission(inv, canEdit: v)),
                    _permChip('Silme', Icons.delete_outline, inv.canDelete, busy,
                        (v) => _setPermission(inv, canDelete: v)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _permChip(String label, IconData icon, bool value, bool busy,
          ValueChanged<bool> onChanged) =>
      FilterChip(
        avatar: value ? null : Icon(icon, size: 18),
        label: Text(label),
        selected: value,
        onSelected: busy ? null : onChanged,
      );
}

/// Davet formu (alttan açılan sayfa). Gönderince [Invitation] döner.
class _InviteSheet extends StatefulWidget {
  const _InviteSheet();

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final PhotoApi _api = PhotoApi();

  // Ekleme varsayılan açık; düzenleme ve silme kapalı
  bool _canAdd = true;
  bool _canEdit = false;
  bool _canDelete = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final inv = await _api.invite(_email.text.trim(),
          canAdd: _canAdd, canEdit: _canEdit, canDelete: _canDelete);
      if (mounted) Navigator.pop(context, inv);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Ajandana kişi davet et', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Davet ettiğin kişi ajandanı görebilir. Neleri yapabileceğini aşağıdan seç.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'E-posta',
                hintText: 'arkadas@ornek.com',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(t)) {
                  return 'Geçerli bir e-posta gir';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.add_location_alt_outlined),
              title: const Text('Ekleyebilir'),
              subtitle: const Text('Yeni yer ve fotoğraf ekler'),
              value: _canAdd,
              onChanged: (v) => setState(() => _canAdd = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.edit_outlined),
              title: const Text('Düzenleyebilir'),
              subtitle: const Text('Bilgileri, puanı ve yorumu değiştirir'),
              value: _canEdit,
              onChanged: (v) => setState(() => _canEdit = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.delete_outline),
              title: const Text('Silebilir'),
              subtitle: const Text('Yerleri ve fotoğrafları siler'),
              value: _canDelete,
              onChanged: (v) => setState(() => _canDelete = v),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Text('Davet gönder'),
            ),
          ],
        ),
      ),
    );
  }
}
