// Çalışan bir sunucuya karşı uçtan uca deneme.
// Kullanım: BASE=http://localhost:3000 node test/smoke.js
const assert = require('node:assert/strict');

const BASE = process.env.BASE || 'http://localhost:3000';
const PNG = Buffer.from('\x89PNG\r\n\x1a\nfake', 'binary');

async function req(method, path, body, { form } = {}) {
  const opts = { method, headers: {} };
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
  await step('health', async () => {
    const r = await req('GET', '/health');
    assert.equal(r.status, 200);
    assert.equal(r.json.db, 'ok');
  });

  // ---- Bağımsız fotoğraflar (eski özellik) ----
  let loosePhotoId;
  await step('fotoğraf yükle / indir / sil', async () => {
    const up = await req('POST', '/photos', undefined, { form: imageForm() });
    assert.equal(up.status, 201, up.raw);
    loosePhotoId = up.json.id;
    assert.equal(up.json.placeId, null);
    const img = await fetch(`${BASE}/photos/${loosePhotoId}/image`);
    assert.equal(img.status, 200);
    assert.deepEqual(Buffer.from(await img.arrayBuffer()), PNG);
    const bad = await req('POST', '/photos', undefined, {
      form: imageForm(Buffer.from('{}'), 'application/json', 'x.json'),
    });
    assert.equal(bad.status, 400);
    assert.equal((await req('DELETE', `/photos/${loosePhotoId}`)).status, 204);
  });

  // ---- Yerler ----
  let planned, visited;
  await step('doğrulama: başlıksız yer reddedilir', async () => {
    assert.equal((await req('POST', '/places', { status: 'planned' })).status, 400);
    assert.equal((await req('POST', '/places', { title: 'x', rating: 9 })).status, 400);
    assert.equal((await req('POST', '/places', { title: 'x', status: 'nope' })).status, 400);
    assert.equal((await req('POST', '/places', { title: 'x', date: '05.11.2026' })).status, 400);
  });

  await step('gezilecek yer ekle', async () => {
    const r = await req('POST', '/places', {
      title: '  Kapadokya ',
      status: 'planned',
      date: '2027-04-20',
      locationName: 'Göreme, Nevşehir',
      lat: 38.6431,
      lng: 34.8289,
      notes: 'Balon turu için erken rezervasyon',
    });
    assert.equal(r.status, 201, r.raw);
    planned = r.json;
    assert.equal(planned.title, 'Kapadokya');
    assert.equal(planned.date, '2027-04-20');
    assert.equal(planned.photoCount, 0);
    assert.equal(planned.coverUrl, null);
  });

  await step('gezilen yer ekle (puan + yorum)', async () => {
    const r = await req('POST', '/places', {
      title: 'Efes Antik Kenti',
      status: 'visited',
      date: '2026-09-01',
      rating: 5,
      comment: 'Harikaydı',
    });
    assert.equal(r.status, 201, r.raw);
    visited = r.json;
    assert.equal(visited.rating, 5);
  });

  await step('duruma göre listele', async () => {
    const p = await req('GET', '/places?status=planned');
    assert.deepEqual(p.json.map((x) => x.id), [planned.id]);
    const v = await req('GET', '/places?status=visited');
    assert.deepEqual(v.json.map((x) => x.id), [visited.id]);
    assert.equal((await req('GET', '/places')).json.length, 2);
    assert.equal((await req('GET', '/places?status=bad')).status, 400);
  });

  await step('yere fotoğraf ekle -> kapak ve sayı', async () => {
    const a = await req('POST', `/places/${planned.id}/photos`, undefined, { form: imageForm() });
    assert.equal(a.status, 201, a.raw);
    assert.equal(a.json.placeId, planned.id);
    const b = await req('POST', `/places/${planned.id}/photos`, undefined, { form: imageForm() });
    assert.equal(b.status, 201);
    const d = await req('GET', `/places/${planned.id}`);
    assert.equal(d.json.photos.length, 2);
    assert.equal(d.json.photoCount, 2);
    assert.equal(d.json.coverUrl, a.json.url);
    assert.equal(
      (await req('POST', '/places/999999/photos', undefined, { form: imageForm() })).status,
      404
    );
  });

  await step('gezildi olarak işaretle + puanla (kısmi güncelleme)', async () => {
    const r = await req('PUT', `/places/${planned.id}`, {
      status: 'visited',
      rating: 4,
      comment: 'Balonlar muhteşemdi',
    });
    assert.equal(r.status, 200, r.raw);
    assert.equal(r.json.status, 'visited');
    assert.equal(r.json.rating, 4);
    assert.equal(r.json.title, 'Kapadokya'); // dokunulmayan alan korunur
    assert.equal(r.json.notes, 'Balon turu için erken rezervasyon');
    const cleared = await req('PUT', `/places/${planned.id}`, { notes: '', rating: null });
    assert.equal(cleared.json.notes, null);
    assert.equal(cleared.json.rating, null);
    assert.equal((await req('PUT', `/places/${planned.id}`, { title: '' })).status, 400);
    assert.equal((await req('PUT', '/places/999999', { title: 'x' })).status, 404);
  });

  await step('yer silinince fotoğrafları da silinir', async () => {
    const photosBefore = (await req('GET', `/places/${planned.id}`)).json.photos;
    assert.equal((await req('DELETE', `/places/${planned.id}`)).status, 204);
    assert.equal((await req('GET', `/places/${planned.id}`)).status, 404);
    const img = await fetch(photosBefore[0].url.replace(/^https?:\/\/[^/]+/, BASE));
    assert.equal(img.status, 404);
    assert.equal((await req('DELETE', `/places/${visited.id}`)).status, 204);
    assert.equal((await req('GET', '/places')).json.length, 0);
  });

  await step('bozuk JSON 400 döner', async () => {
    const r = await fetch(`${BASE}/places`, {
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
