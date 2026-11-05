// Gezi ajandası + fotoğraf API'si
//
// Yerler (gezilecek / gezilen):
//   GET    /places?status=planned|visited   -> liste (kapak fotoğrafı ve foto sayısıyla)
//   POST   /places                          -> yer ekle (JSON)
//   GET    /places/:id                      -> yer + fotoğrafları
//   PUT    /places/:id                      -> yeri güncelle (JSON, sadece gönderilen alanlar)
//   DELETE /places/:id                      -> yeri ve fotoğraflarını sil
//   POST   /places/:id/photos               -> yere fotoğraf ekle (multipart, alan: "photo")
//
// Fotoğraflar:
//   GET    /health                -> sunucu ve veritabanı çalışıyor mu
//   GET    /photos                -> tüm fotoğraflar (en yeni önce)
//   POST   /photos                -> yere bağlı olmayan fotoğraf yükle
//   GET    /photos/:id/image      -> fotoğrafın kendisi
//   DELETE /photos/:id            -> fotoğrafı sil
//
// Gerekli ortam değişkeni: DATABASE_URL (Neon'un verdiği bağlantı adresi)

const express = require('express');
const multer = require('multer');
const { Pool, types } = require('pg');

// DATE sütunlarını saat dilimi kaymasın diye "YYYY-MM-DD" metni olarak al
types.setTypeParser(1082, (v) => v);

const PORT = process.env.PORT || 3000;
const MAX_MB = Number(process.env.MAX_UPLOAD_MB || 10);

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL tanımlı değil. Neon bağlantı adresini ortam değişkeni olarak ekleyin.');
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  // Neon SSL ister; adreste sslmode yoksa yine de SSL kullan
  ssl: process.env.DATABASE_URL.includes('localhost') ? false : { rejectUnauthorized: false },
  max: 5,
});

async function initDb() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS places (
      id             SERIAL PRIMARY KEY,
      title          TEXT NOT NULL,
      status         TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'visited')),
      date           DATE,
      location_name  TEXT,
      lat            DOUBLE PRECISION,
      lng            DOUBLE PRECISION,
      notes          TEXT,
      rating         SMALLINT CHECK (rating BETWEEN 1 AND 5),
      comment        TEXT,
      created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS photos (
      id          SERIAL PRIMARY KEY,
      filename    TEXT NOT NULL,
      mime_type   TEXT NOT NULL,
      size_bytes  INTEGER NOT NULL,
      data        BYTEA NOT NULL,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  // Eski kurulumlar için: fotoğrafı bir yere bağlayan sütun
  await pool.query(
    'ALTER TABLE photos ADD COLUMN IF NOT EXISTS place_id INTEGER REFERENCES places(id) ON DELETE CASCADE'
  );
  await pool.query('CREATE INDEX IF NOT EXISTS photos_place_id_idx ON photos(place_id)');
}

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_MB * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (file.mimetype && file.mimetype.startsWith('image/')) return cb(null, true);
    cb(new BadRequest('Sadece resim dosyaları yüklenebilir'));
  },
});

class BadRequest extends Error {}

const app = express();
app.use(express.json({ limit: '1mb' }));

function baseUrl(req) {
  const proto = req.headers['x-forwarded-proto'] || req.protocol;
  return `${proto}://${req.get('host')}`;
}

function photoUrl(req, id) {
  return `${baseUrl(req)}/photos/${id}/image`;
}

function photoJson(req, row) {
  return {
    id: row.id,
    placeId: row.place_id ?? null,
    filename: row.filename,
    mimeType: row.mime_type,
    sizeBytes: row.size_bytes,
    createdAt: row.created_at,
    url: photoUrl(req, row.id),
  };
}

function placeJson(req, row) {
  return {
    id: row.id,
    title: row.title,
    status: row.status,
    date: row.date,
    locationName: row.location_name,
    lat: row.lat,
    lng: row.lng,
    notes: row.notes,
    rating: row.rating,
    comment: row.comment,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    photoCount: row.photo_count !== undefined ? Number(row.photo_count) : undefined,
    coverUrl: row.cover_id ? photoUrl(req, row.cover_id) : null,
  };
}

function parseId(value) {
  const id = Number(value);
  if (!Number.isInteger(id) || id <= 0) throw new BadRequest('Geçersiz id');
  return id;
}

// Gelen JSON'u doğrula ve veritabanı sütunlarına çevir.
// partial=true ise sadece gönderilen alanlar döner (güncelleme için).
function placeFields(body, partial) {
  if (!body || typeof body !== 'object') throw new BadRequest('JSON gövdesi gerekli');
  const out = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);
  const text = (k, col) => {
    if (!has(k)) return;
    const v = body[k];
    if (v !== null && typeof v !== 'string') throw new BadRequest(`${k} metin olmalı`);
    out[col] = v === null || v.trim() === '' ? null : v.trim();
  };

  if (has('title') || !partial) {
    const t = typeof body.title === 'string' ? body.title.trim() : '';
    if (!t) throw new BadRequest('Yer adı (title) gerekli');
    out.title = t;
  }
  if (has('status')) {
    if (!['planned', 'visited'].includes(body.status)) {
      throw new BadRequest("status 'planned' ya da 'visited' olmalı");
    }
    out.status = body.status;
  }
  if (has('date')) {
    const d = body.date;
    if (d !== null && !(typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d))) {
      throw new BadRequest('date YYYY-AA-GG biçiminde olmalı');
    }
    out.date = d;
  }
  text('locationName', 'location_name');
  for (const k of ['lat', 'lng']) {
    if (!has(k)) continue;
    const v = body[k];
    if (v !== null && (typeof v !== 'number' || !Number.isFinite(v))) {
      throw new BadRequest(`${k} sayı olmalı`);
    }
    out[k] = v;
  }
  text('notes', 'notes');
  if (has('rating')) {
    const r = body.rating;
    if (r !== null && !(Number.isInteger(r) && r >= 1 && r <= 5)) {
      throw new BadRequest('rating 1 ile 5 arasında tam sayı olmalı');
    }
    out.rating = r;
  }
  text('comment', 'comment');
  return out;
}

const PLACE_SELECT = `
  SELECT p.*,
         (SELECT count(*) FROM photos ph WHERE ph.place_id = p.id) AS photo_count,
         (SELECT ph.id FROM photos ph WHERE ph.place_id = p.id
            ORDER BY ph.created_at, ph.id LIMIT 1) AS cover_id
  FROM places p`;

app.get('/', (_req, res) => res.json({ ok: true, service: 'hello-world-backend' }));

app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, db: 'ok' });
  } catch (e) {
    res.status(500).json({ ok: false, db: 'error', error: e.message });
  }
});

// ---------- Yerler ----------

app.get('/places', async (req, res, next) => {
  try {
    const { status } = req.query;
    let sql = PLACE_SELECT;
    const params = [];
    if (status) {
      if (!['planned', 'visited'].includes(status)) throw new BadRequest('Geçersiz status');
      params.push(status);
      sql += ' WHERE p.status = $1';
    }
    // Gezilecekler: tarihi yakın olan önce; gezilenler: en son gezilen önce
    sql += status === 'visited'
      ? ' ORDER BY p.date DESC NULLS LAST, p.updated_at DESC'
      : ' ORDER BY p.date ASC NULLS LAST, p.created_at DESC';
    const { rows } = await pool.query(sql, params);
    res.json(rows.map((r) => placeJson(req, r)));
  } catch (e) {
    next(e);
  }
});

app.post('/places', async (req, res, next) => {
  try {
    const f = placeFields(req.body, false);
    const cols = Object.keys(f);
    const { rows } = await pool.query(
      `INSERT INTO places (${cols.join(', ')})
       VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')})
       RETURNING id`,
      cols.map((c) => f[c])
    );
    const created = await pool.query(`${PLACE_SELECT} WHERE p.id = $1`, [rows[0].id]);
    res.status(201).json(placeJson(req, created.rows[0]));
  } catch (e) {
    next(e);
  }
});

app.get('/places/:id', async (req, res, next) => {
  try {
    const id = parseId(req.params.id);
    const { rows } = await pool.query(`${PLACE_SELECT} WHERE p.id = $1`, [id]);
    if (!rows.length) return res.status(404).json({ error: 'Yer bulunamadı' });
    const photos = await pool.query(
      `SELECT id, place_id, filename, mime_type, size_bytes, created_at
       FROM photos WHERE place_id = $1 ORDER BY created_at, id`,
      [id]
    );
    res.json({ ...placeJson(req, rows[0]), photos: photos.rows.map((r) => photoJson(req, r)) });
  } catch (e) {
    next(e);
  }
});

app.put('/places/:id', async (req, res, next) => {
  try {
    const id = parseId(req.params.id);
    const f = placeFields(req.body, true);
    const cols = Object.keys(f);
    if (cols.length) {
      const sets = cols.map((c, i) => `${c} = $${i + 1}`).join(', ');
      const { rowCount } = await pool.query(
        `UPDATE places SET ${sets}, updated_at = now() WHERE id = $${cols.length + 1}`,
        [...cols.map((c) => f[c]), id]
      );
      if (!rowCount) return res.status(404).json({ error: 'Yer bulunamadı' });
    }
    const { rows } = await pool.query(`${PLACE_SELECT} WHERE p.id = $1`, [id]);
    if (!rows.length) return res.status(404).json({ error: 'Yer bulunamadı' });
    res.json(placeJson(req, rows[0]));
  } catch (e) {
    next(e);
  }
});

app.delete('/places/:id', async (req, res, next) => {
  try {
    const id = parseId(req.params.id);
    const { rowCount } = await pool.query('DELETE FROM places WHERE id = $1', [id]);
    if (!rowCount) return res.status(404).json({ error: 'Yer bulunamadı' });
    res.status(204).end();
  } catch (e) {
    next(e);
  }
});

app.post('/places/:id/photos', upload.single('photo'), async (req, res, next) => {
  try {
    const id = parseId(req.params.id);
    if (!req.file) return res.status(400).json({ error: '"photo" alanında dosya yok' });
    const exists = await pool.query('SELECT 1 FROM places WHERE id = $1', [id]);
    if (!exists.rowCount) return res.status(404).json({ error: 'Yer bulunamadı' });
    res.status(201).json(await insertPhoto(req, id));
  } catch (e) {
    next(e);
  }
});

// ---------- Fotoğraflar ----------

async function insertPhoto(req, placeId) {
  const { originalname, mimetype, size, buffer } = req.file;
  const { rows } = await pool.query(
    `INSERT INTO photos (place_id, filename, mime_type, size_bytes, data)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING id, place_id, filename, mime_type, size_bytes, created_at`,
    [placeId, originalname || 'photo.jpg', mimetype, size, buffer]
  );
  return photoJson(req, rows[0]);
}

app.get('/photos', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      'SELECT id, place_id, filename, mime_type, size_bytes, created_at FROM photos ORDER BY created_at DESC, id DESC'
    );
    res.json(rows.map((r) => photoJson(req, r)));
  } catch (e) {
    next(e);
  }
});

app.post('/photos', upload.single('photo'), async (req, res, next) => {
  try {
    if (!req.file) return res.status(400).json({ error: '"photo" alanında dosya yok' });
    res.status(201).json(await insertPhoto(req, null));
  } catch (e) {
    next(e);
  }
});

app.get('/photos/:id/image', async (req, res, next) => {
  try {
    const id = parseId(req.params.id);
    const { rows } = await pool.query('SELECT mime_type, data FROM photos WHERE id = $1', [id]);
    if (!rows.length) return res.status(404).json({ error: 'Bulunamadı' });
    res.set('Content-Type', rows[0].mime_type);
    res.set('Cache-Control', 'public, max-age=31536000, immutable');
    res.send(rows[0].data);
  } catch (e) {
    next(e);
  }
});

app.delete('/photos/:id', async (req, res, next) => {
  try {
    const id = parseId(req.params.id);
    const { rowCount } = await pool.query('DELETE FROM photos WHERE id = $1', [id]);
    if (!rowCount) return res.status(404).json({ error: 'Bulunamadı' });
    res.status(204).end();
  } catch (e) {
    next(e);
  }
});

// Hata yakalayıcı
// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  if (err instanceof multer.MulterError) {
    const msg = err.code === 'LIMIT_FILE_SIZE' ? `Dosya ${MAX_MB} MB'tan büyük` : err.message;
    return res.status(400).json({ error: msg });
  }
  if (err instanceof BadRequest) return res.status(400).json({ error: err.message });
  if (err && err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'Geçersiz JSON' });
  }
  console.error(err);
  res.status(500).json({ error: 'Sunucu hatası' });
});

initDb()
  .then(() => {
    app.listen(PORT, () => console.log(`Sunucu ${PORT} portunda çalışıyor`));
  })
  .catch((e) => {
    console.error('Veritabanına bağlanılamadı:', e.message);
    process.exit(1);
  });
