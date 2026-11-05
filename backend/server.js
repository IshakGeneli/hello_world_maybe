// Fotoğraf yükleme API'si
//
//   GET    /health              -> sunucu ve veritabanı çalışıyor mu
//   GET    /photos              -> fotoğraf listesi (en yeni önce)
//   POST   /photos              -> fotoğraf yükle (multipart, alan adı: "photo")
//   GET    /photos/:id/image    -> fotoğrafın kendisi
//   DELETE /photos/:id          -> fotoğrafı sil
//
// Gerekli ortam değişkeni: DATABASE_URL (Neon'un verdiği bağlantı adresi)

const express = require('express');
const multer = require('multer');
const { Pool } = require('pg');

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
    CREATE TABLE IF NOT EXISTS photos (
      id          SERIAL PRIMARY KEY,
      filename    TEXT NOT NULL,
      mime_type   TEXT NOT NULL,
      size_bytes  INTEGER NOT NULL,
      data        BYTEA NOT NULL,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
}

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_MB * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (file.mimetype && file.mimetype.startsWith('image/')) return cb(null, true);
    cb(new Error('Sadece resim dosyaları yüklenebilir'));
  },
});

const app = express();

function baseUrl(req) {
  const proto = req.headers['x-forwarded-proto'] || req.protocol;
  return `${proto}://${req.get('host')}`;
}

function toJson(req, row) {
  return {
    id: row.id,
    filename: row.filename,
    mimeType: row.mime_type,
    sizeBytes: row.size_bytes,
    createdAt: row.created_at,
    url: `${baseUrl(req)}/photos/${row.id}/image`,
  };
}

app.get('/', (_req, res) => res.json({ ok: true, service: 'hello-world-backend' }));

app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, db: 'ok' });
  } catch (e) {
    res.status(500).json({ ok: false, db: 'error', error: e.message });
  }
});

app.get('/photos', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      'SELECT id, filename, mime_type, size_bytes, created_at FROM photos ORDER BY created_at DESC, id DESC'
    );
    res.json(rows.map((r) => toJson(req, r)));
  } catch (e) {
    next(e);
  }
});

app.post('/photos', upload.single('photo'), async (req, res, next) => {
  try {
    if (!req.file) return res.status(400).json({ error: '"photo" alanında dosya yok' });
    const { originalname, mimetype, size, buffer } = req.file;
    const { rows } = await pool.query(
      `INSERT INTO photos (filename, mime_type, size_bytes, data)
       VALUES ($1, $2, $3, $4)
       RETURNING id, filename, mime_type, size_bytes, created_at`,
      [originalname || 'photo.jpg', mimetype, size, buffer]
    );
    res.status(201).json(toJson(req, rows[0]));
  } catch (e) {
    next(e);
  }
});

app.get('/photos/:id/image', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    if (!Number.isInteger(id)) return res.status(400).json({ error: 'Geçersiz id' });
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
    const id = Number(req.params.id);
    if (!Number.isInteger(id)) return res.status(400).json({ error: 'Geçersiz id' });
    const { rowCount } = await pool.query('DELETE FROM photos WHERE id = $1', [id]);
    if (!rowCount) return res.status(404).json({ error: 'Bulunamadı' });
    res.status(204).end();
  } catch (e) {
    next(e);
  }
});

// Hata yakalayıcı (dosya çok büyük, resim değil vb.)
// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  if (err instanceof multer.MulterError) {
    const msg = err.code === 'LIMIT_FILE_SIZE' ? `Dosya ${MAX_MB} MB'tan büyük` : err.message;
    return res.status(400).json({ error: msg });
  }
  if (err && err.message === 'Sadece resim dosyaları yüklenebilir') {
    return res.status(400).json({ error: err.message });
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
