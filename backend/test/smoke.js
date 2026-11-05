// Çalışan bir sunucuya karşı uçtan uca deneme.
// Kullanım: BASE=http://localhost:3000 node test/smoke.js
const assert = require('node:assert/strict');

const BASE = process.env.BASE || 'http://localhost:3000';
const PNG = Buffer.from('\x89PNG\r\n\x1a\nfake', 'binary');

async function req(method, path, { token, body, form } = {}) {
  const opts = { method, headers: {} };
  if (token) opts.headers.Authorization = `Bearer ${token}`;
  if (form) {
    opts.body = form;
  } else if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(BASE + path, opts);
  const text = await r.text();
  let json;
  try { json = text ? JSON.parse(text) : null; } catch { json = text; }
  return { status: r.status, json, raw: text };
}

function imageForm(buf = PNG, type = 'image/png', name = 'test.png') {
  const f = new FormData();
  f.append('photo', new Blob([buf], { type }), name);
  return f;
}

const local = (url) => url.replace(/^https?:\/\/[^/]+/, '');

async function step(name, fn) {
  try {
    await fn();
    console.log('✓', name);
  } catch (e) {
    console.error('✗', name);
    throw e;
  }
}

(async () => {
  let ali, ayse, can; // {token, user}
  let alisPlace, legacyId;

  await step('health', async () => {
    const r = await req('GET', '/health');
    assert.equal(r.status, 200);
    assert.equal(r.json.db, 'ok');
  });

  await step('girişsiz istekler 401', async () => {
    assert.equal((await req('GET', '/places')).status, 401);
    assert.equal((await req('GET', '/agendas')).status, 401);
    assert.equal((await req('GET', '/places', { token: 'bozuk' })).status, 401);
  });

  // ---- Hesaplar ----
  await step('kayıt doğrulama', async () => {
    assert.equal((await req('POST', '/auth/register', { body: { email: 'x', password: '123456' } })).status, 400);
    assert.equal((await req('POST', '/auth/register', { body: { email: 'a@b.co', password: '123' } })).status, 400);
  });

  await step('ilk kayıt eski yerleri sahiplenir', async () => {
    // test ortamında hesap öncesi eklenmiş bir yer (CI adımı ekledi)
    const r = await req('POST', '/auth/register', {
      body: { email: '  Ali@Example.com ', password: 'sifre123', name: 'Ali' },
    });
    assert.equal(r.status, 201, r.raw);
    ali = r.json;
    assert.equal(ali.user.email, 'ali@example.com');
    const list = await req('GET', '/places', { token: ali.token });
    assert.equal(list.status, 200, list.raw);
    const legacy = list.json.find((p) => p.title === 'Eski Yer');
    assert.ok(legacy, 'eski yer Ali\'ye geçmeli');
    legacyId = legacy.id;
  });

  await step('aynı e-postayla ikinci kayıt 409', async () => {
    const r = await req('POST', '/auth/register', { body: { email: 'ali@example.com', password: 'baska123' } });
    assert.equal(r.status, 409);
  });

  await step('giriş', async () => {
    assert.equal((await req('POST', '/auth/login', { body: { email: 'ali@example.com', password: 'yanlis' } })).status, 401);
    const r = await req('POST', '/auth/login', { body: { email: 'ALI@example.com', password: 'sifre123' } });
    assert.equal(r.status, 200);
    assert.ok(r.json.token);
    const me = await req('GET', '/me', { token: r.json.token });
    assert.equal(me.json.user.name, 'Ali');
  });

  await step('diğer hesaplar', async () => {
    ayse = (await req('POST', '/auth/register', { body: { email: 'ayse@example.com', password: 'sifre123', name: 'Ayşe' } })).json;
    can = (await req('POST', '/auth/register', { body: { email: 'can@example.com', password: 'sifre123', name: 'Can' } })).json;
    assert.ok(ayse.token && can.token);
    // ikinci hesap eski yerleri görmez
    const l = await req('GET', '/places', { token: ayse.token });
    assert.equal(l.json.length, 0);
  });

  // ---- Kendi ajandası ----
  await step('kendi ajandasına yer + fotoğraf', async () => {
    const r = await req('POST', '/places', {
      token: ali.token,
      body: { title: 'Kapadokya', status: 'planned', date: '2027-04-20', lat: 38.64, lng: 34.83 },
    });
    assert.equal(r.status, 201, r.raw);
    alisPlace = r.json;
    assert.equal(alisPlace.agendaId, ali.user.id);
    assert.equal(alisPlace.createdBy, 'Ali');
    const ph = await req('POST', `/places/${alisPlace.id}/photos`, { token: ali.token, form: imageForm() });
    assert.equal(ph.status, 201, ph.raw);
    const img = await fetch(BASE + local(ph.json.url), { headers: { Authorization: `Bearer ${ali.token}` } });
    assert.equal(img.status, 200);
    assert.deepEqual(Buffer.from(await img.arrayBuffer()), PNG);
    alisPlace.photoUrl = ph.json.url;
    alisPlace.photoId = ph.json.id;
  });

  await step('davetsiz kişi başkasının ajandasını göremez', async () => {
    assert.equal((await req('GET', `/places?agenda=${ali.user.id}`, { token: ayse.token })).status, 404);
    assert.equal((await req('GET', `/places/${alisPlace.id}`, { token: ayse.token })).status, 404);
    assert.equal((await req('PUT', `/places/${alisPlace.id}`, { token: ayse.token, body: { title: 'x' } })).status, 404);
    assert.equal((await req('DELETE', `/places/${alisPlace.id}`, { token: ayse.token })).status, 404);
    const img = await fetch(BASE + local(alisPlace.photoUrl), { headers: { Authorization: `Bearer ${ayse.token}` } });
    assert.equal(img.status, 404);
    assert.equal((await req('POST', '/places', { token: ayse.token, body: { title: 'x', agendaId: ali.user.id } })).status, 404);
  });

  // ---- Davetler ----
  let invAyse, invCan;
  await step('davet gönder (ekleme varsayılan açık)', async () => {
    assert.equal((await req('POST', '/invitations', { token: ali.token, body: { email: 'ali@example.com' } })).status, 400);
    const r = await req('POST', '/invitations', { token: ali.token, body: { email: 'Ayse@Example.com' } });
    assert.equal(r.status, 201, r.raw);
    invAyse = r.json;
    assert.equal(invAyse.status, 'pending');
    assert.equal(invAyse.canAdd, true);
    assert.equal(invAyse.canEdit, false);
    assert.equal(invAyse.canDelete, false);
    assert.equal(invAyse.memberName, 'Ayşe');
    // henüz hesabı olmayan birine de davet gidebilir
    const r2 = await req('POST', '/invitations', { token: ali.token, body: { email: 'yeni@example.com' } });
    assert.equal(r2.status, 201);
    assert.equal(r2.json.memberName, null);
    const sent = await req('GET', '/invitations/sent', { token: ali.token });
    assert.equal(sent.json.length, 2);
  });

  await step('bekleyen davet erişim vermez', async () => {
    assert.equal((await req('GET', `/places?agenda=${ali.user.id}`, { token: ayse.token })).status, 404);
    const me = await req('GET', '/me', { token: ayse.token });
    assert.equal(me.json.pendingInvitations, 1);
  });

  await step('daveti kabul et', async () => {
    const rec = await req('GET', '/invitations/received', { token: ayse.token });
    assert.equal(rec.json.length, 1);
    assert.equal(rec.json[0].owner.name, 'Ali');
    // başkası kabul edemez
    assert.equal((await req('POST', `/invitations/${invAyse.id}/accept`, { token: can.token })).status, 404);
    const a = await req('POST', `/invitations/${invAyse.id}/accept`, { token: ayse.token });
    assert.equal(a.status, 200, a.raw);
    assert.equal((await req('POST', `/invitations/${invAyse.id}/accept`, { token: ayse.token })).status, 400);
    const ag = await req('GET', '/agendas', { token: ayse.token });
    assert.equal(ag.json.length, 2);
    const shared = ag.json.find((x) => !x.isOwner);
    assert.equal(shared.id, ali.user.id);
    assert.equal(shared.ownerName, 'Ali');
    assert.deepEqual([shared.canAdd, shared.canEdit, shared.canDelete], [true, false, false]);
  });

  let aysesPlace;
  await step('üye: görüntüleme + ekleme var, düzenleme/silme yok', async () => {
    const l = await req('GET', `/places?agenda=${ali.user.id}`, { token: ayse.token });
    assert.equal(l.status, 200);
    assert.ok(l.json.some((p) => p.id === alisPlace.id));
    const d = await req('GET', `/places/${alisPlace.id}`, { token: ayse.token });
    assert.equal(d.status, 200);
    assert.deepEqual(
      [d.json.access.isOwner, d.json.access.canAdd, d.json.access.canEdit, d.json.access.canDelete],
      [false, true, false, false]
    );
    const img = await fetch(BASE + local(alisPlace.photoUrl), { headers: { Authorization: `Bearer ${ayse.token}` } });
    assert.equal(img.status, 200);

    const add = await req('POST', '/places', { token: ayse.token, body: { title: 'Efes', agendaId: ali.user.id } });
    assert.equal(add.status, 201, add.raw);
    aysesPlace = add.json;
    assert.equal(aysesPlace.agendaId, ali.user.id); // Ali'nin ajandasına eklendi
    assert.equal(aysesPlace.createdBy, 'Ayşe');
    assert.equal((await req('POST', `/places/${alisPlace.id}/photos`, { token: ayse.token, form: imageForm() })).status, 201);

    const put = await req('PUT', `/places/${alisPlace.id}`, { token: ayse.token, body: { rating: 5 } });
    assert.equal(put.status, 403);
    assert.equal((await req('DELETE', `/places/${alisPlace.id}`, { token: ayse.token })).status, 403);
    assert.equal((await req('DELETE', `/photos/${alisPlace.photoId}`, { token: ayse.token })).status, 403);
  });

  await step('sahip yetkileri değiştirir', async () => {
    assert.equal((await req('PUT', `/invitations/${invAyse.id}`, { token: ayse.token, body: { canEdit: true } })).status, 404);
    assert.equal((await req('PUT', `/invitations/${invAyse.id}`, { token: ali.token, body: { canEdit: 'evet' } })).status, 400);
    const u = await req('PUT', `/invitations/${invAyse.id}`, {
      token: ali.token,
      body: { canAdd: false, canEdit: true, canDelete: true },
    });
    assert.equal(u.status, 200, u.raw);
    assert.deepEqual([u.json.canAdd, u.json.canEdit, u.json.canDelete], [false, true, true]);

    assert.equal((await req('POST', '/places', { token: ayse.token, body: { title: 'x', agendaId: ali.user.id } })).status, 403);
    const put = await req('PUT', `/places/${alisPlace.id}`, { token: ayse.token, body: { rating: 5, status: 'visited' } });
    assert.equal(put.status, 200, put.raw);
    assert.equal(put.json.rating, 5);
    assert.equal((await req('DELETE', `/photos/${alisPlace.photoId}`, { token: ayse.token })).status, 204);
    assert.equal((await req('DELETE', `/places/${aysesPlace.id}`, { token: ayse.token })).status, 204);
  });

  await step('davet reddetme ve yeniden davet', async () => {
    invCan = (await req('POST', '/invitations', { token: ali.token, body: { email: 'can@example.com', canEdit: true } })).json;
    assert.equal(invCan.canEdit, true);
    assert.equal((await req('POST', `/invitations/${invCan.id}/decline`, { token: can.token })).status, 200);
    assert.equal((await req('GET', `/places?agenda=${ali.user.id}`, { token: can.token })).status, 404);
    const again = await req('POST', '/invitations', { token: ali.token, body: { email: 'can@example.com' } });
    assert.equal(again.json.status, 'pending');
    assert.equal(again.json.id, invCan.id);
  });

  await step('üyeyi çıkar / ajandadan ayrıl', async () => {
    assert.equal((await req('DELETE', `/invitations/${invAyse.id}`, { token: can.token })).status, 404);
    assert.equal((await req('DELETE', `/invitations/${invAyse.id}`, { token: ayse.token })).status, 204); // ayrıldı
    assert.equal((await req('GET', `/places?agenda=${ali.user.id}`, { token: ayse.token })).status, 404);
    assert.equal((await req('GET', '/agendas', { token: ayse.token })).json.length, 1);
    assert.equal((await req('DELETE', `/invitations/${invCan.id}`, { token: ali.token })).status, 204); // sahip çıkardı
  });

  await step('yer doğrulama ve sıralama (kendi ajandası)', async () => {
    assert.equal((await req('POST', '/places', { token: ali.token, body: { status: 'planned' } })).status, 400);
    assert.equal((await req('POST', '/places', { token: ali.token, body: { title: 'x', rating: 9 } })).status, 400);
    assert.equal((await req('POST', '/places', { token: ali.token, body: { title: 'x', date: '05.11.2026' } })).status, 400);
    const v = await req('GET', '/places?status=visited', { token: ali.token });
    assert.ok(v.json.every((p) => p.status === 'visited'));
    assert.equal((await req('GET', '/places?status=bad', { token: ali.token })).status, 400);
  });

  await step('yer silinince fotoğrafları da silinir', async () => {
    const ph = await req('POST', `/places/${legacyId}/photos`, { token: ali.token, form: imageForm() });
    assert.equal((await req('DELETE', `/places/${legacyId}`, { token: ali.token })).status, 204);
    const img = await fetch(BASE + local(ph.json.url), { headers: { Authorization: `Bearer ${ali.token}` } });
    assert.equal(img.status, 404);
  });

  await step('bozuk JSON 400', async () => {
    const r = await fetch(`${BASE}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{bozuk',
    });
    assert.equal(r.status, 400);
  });

  console.log('TÜM TESTLER GEÇTİ');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
