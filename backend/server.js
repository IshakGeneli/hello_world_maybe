// Gezi ajandası API'si — hesaplar, paylaşılan ajandalar, yerler, fotoğraflar
//
// Hesap:
//   POST   /auth/register   {email, password, name?}  -> {token, user}
//   POST   /auth/login      {email, password}         -> {token, user}
//   GET    /me                                        -> {user, pendingInvitations}
//
// Ajandalar (kendi ajandam + bana paylaşılanlar, yetkileriyle):
//   GET    /agendas
//
// Davetler:
//   POST   /invitations              {email, canAdd?, canEdit?, canDelete?}  (ajanda sahibi)
//   GET    /invitations/sent         (gönderdiklerim / ajandamın üyeleri)
//   GET    /invitations/received     (bana gelen bekleyen davetler)
//   PUT    /invitations/:id          {canAdd?, canEdit?, canDelete?}  (sahip yetki değiştirir)
//   POST   /invitations/:id/accept   (davetli)
//   POST   /invitations/:id/decline  (davetli)
//   DELETE /invitations/:id          (sahip üyeyi çıkarır ya da davetli ayrılır)
//
// Yerler (her yer bir ajandaya — sahibinin hesabına — aittir):
//   GET    /places?agenda=<sahipId>&status=planned|visited
//   POST   /places                 {agendaId?, title, ...}    (yetki: ekleme)
//   GET    /places/:id
//   PUT    /places/:id                                         (yetki: düzenleme)
//   DELETE /places/:id                                         (yetki: silme)
//   POST   /places/:id/photos      multipart "photo"           (yetki: ekleme)
//
// Fotoğraflar:
//   GET    /photos/:id/image                                   (yetki: görüntüleme)
//   DELETE /photos/:id                                         (yetki: silme)
//
// /health ve /auth/* dışındaki her istek "Authorization: Bearer <token>" ister.
// Ortam değişkenleri: DATABASE_URL (zorunlu), JWT_SECRET (yoksa veritabanında üretilir)

const crypto = require('node:crypto');
const { promisify } = require('node:util');
const express = require('express');
const jwt = require('jsonwebtoken');
const multer = require('multer');
const { Pool, types } = require('pg');

const scrypt = promisify(crypto.scrypt);

// DATE sütunlarını saat dilimi kaymasın diye "YYYY-MM-DD" metni olarak al
types.setTypeParser(1082, (v) => v);

const PORT = process.env.PORT || 3000;
const MAX_MB = Number(process.env.MAX_UPLOAD_MB || 10);
const TOKEN_DAYS = 90;

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL tanımlı değil. Neon bağlantı adresini ortam değişkeni olarak ekleyin.');
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL.includes('localhost') ? false : { rejectUnauthorized: false },
  max: 5,
});

let JWT_SECRET = process.env.JWT_SECRET;

async function initDb() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )`);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id             SERIAL PRIMARY KEY,
      email          TEXT NOT NULL UNIQUE,
      name           TEXT NOT NULL,
      password_hash  TEXT NOT NULL,
      created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
    )`);
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
    )`);
  await pool.query(
    'ALTER TABLE places ADD COLUMN IF NOT EXISTS owner_id INTEGER REFERENCES users(id) ON DELETE CASCADE'
  );
  await pool.query('CREATE INDEX IF NOT EXISTS places_owner_idx ON places(owner_id)');
  await pool.query(
    'ALTER TABLE places ADD COLUMN IF NOT EXISTS created_by INTEGER REFERENCES users(id) ON DELETE SET NULL'
  );
  await pool.query(`
    CREATE TABLE IF NOT EXISTS photos (
      id          SERIAL PRIMARY KEY,
      filename    TEXT NOT NULL,
      mime_type   TEXT NOT NULL,
      size_bytes  INTEGER NOT NULL,
      data        BYTEA NOT NULL,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    )`);
  await pool.query(
    'ALTER TABLE photos ADD COLUMN IF NOT EXISTS place_id INTEGER REFERENCES places(id) ON DELETE CASCADE'
  );
  await pool.query('CREATE INDEX IF NOT EXISTS photos_place_id_idx ON photos(place_id)');
  await pool.query(`
    CREATE TABLE IF NOT EXISTS invitations (
      id          SERIAL PRIMARY KEY,
      owner_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      email       TEXT NOT NULL,
      can_add     BOOLEAN NOT NULL DEFAULT true,
      can_edit    BOOLEAN NOT NULL DEFAULT false,
      can_delete  BOOLEAN NOT NULL DEFAULT false,
      status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (owner_id, email)
    )`);
  await pool.query('CREATE INDEX IF NOT EXISTS invitations_email_idx ON invitations(email)');

  if (!JWT_SECRET) {
    await pool.query(
      `INSERT INTO settings (key, value) VALUES ('jwt_secret', $1) ON CONFLICT (key) DO NOTHING`,
      [crypto.randomBytes(48).toString('hex')]
    );
    const { rows } = await pool.query(`SELECT value FROM settings WHERE key = 'jwt_secret'`);
    JWT_SECRET = rows[0].value;
  }
}

// ---------- Yardımcılar ----------

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
const bad = (m) => new HttpError(400, m);
const forbidden = (m = 'Bu işlem için yetkin yok') => new HttpError(403, m);
const notFound = (m = 'Bulunamadı') => new HttpError(404, m);

// async route sarmalayıcı: hataları hata yakalayıcıya iletir
const h = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_MB * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (file.mimetype && file.mimetype.startsWith('image/')) return cb(null, true);
    cb(bad('Sadece resim dosyaları yüklenebilir'));
  },
});

function parseId(value) {
  const id = Number(value);
  if (!Number.isInteger(id) || id <= 0) throw bad('Geçersiz id');
  return id;
}

function normEmail(e) {
  if (typeof e !== 'string') throw bad('E-posta gerekli');
  const email = e.trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw bad('Geçerli bir e-posta gir');
  return email;
}

async function hashPassword(pw) {
  const salt = crypto.randomBytes(16);
  const hash = await scrypt(pw, salt, 64);
  return `scrypt$${salt.toString('hex')}$${hash.toString('hex')}`;
}

async function checkPassword(pw, stored) {
  const [algo, saltHex, hashHex] = String(stored).split('$');
  if (algo !== 'scrypt' || !saltHex || !hashHex) return false;
  const expected = Buffer.from(hashHex, 'hex');
  const actual = await scrypt(pw, Buffer.from(saltHex, 'hex'), expected.length);
  return crypto.timingSafeEqual(expected, actual);
}

function userJson(u) {
  return { id: u.id, email: u.email, name: u.name };
}

function issueToken(user) {
  return jwt.sign({ sub: user.id }, JWT_SECRET, { expiresIn: `${TOKEN_DAYS}d` });
}

const auth = h(async (req, _res, next) => {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) throw new HttpError(401, 'Giriş yapman gerekiyor');
  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET);
  } catch {
    throw new HttpError(401, 'Oturumun süresi doldu, tekrar giriş yap');
  }
  const { rows } = await pool.query('SELECT id, email, name FROM users WHERE id = $1', [payload.sub]);
  if (!rows.length) throw new HttpError(401, 'Hesap bulunamadı, tekrar giriş yap');
  req.user = rows[0];
  next();
});

/// Kullanıcının bir ajandadaki yetkileri; erişimi yoksa null.
async function agendaAccess(user, ownerId) {
  if (user.id === ownerId) {
    return { isOwner: true, canView: true, canAdd: true, canEdit: true, canDelete: true };
  }
  const { rows } = await pool.query(
    `SELECT can_add, can_edit, can_delete FROM invitations
     WHERE owner_id = $1 AND email = $2 AND status = 'accepted'`,
    [ownerId, user.email]
  );
  if (!rows.length) return null;
  const r = rows[0];
  return {
    isOwner: false,
    canView: true,
    canAdd: r.can_add,
    canEdit: r.can_edit,
    canDelete: r.can_delete,
  };
}

async function requireAgenda(user, ownerId, perm) {
  const access = await agendaAccess(user, ownerId);
  if (!access) throw notFound('Ajanda bulunamadı');
  if (perm && !access[perm]) throw forbidden(permMessage(perm));
  return access;
}

function permMessage(perm) {
  return {
    canAdd: 'Bu ajandaya ekleme yetkin yok',
    canEdit: 'Bu ajandada düzenleme yetkin yok',
    canDelete: 'Bu ajandada silme yetkin yok',
  }[perm] || 'Bu işlem için yetkin yok';
}

/// Yeri getir ve kullanıcının o yerin ajandasında [perm] yetkisi olduğunu doğrula.
async function requirePlace(user, placeId, perm) {
  const { rows } = await pool.query('SELECT owner_id FROM places WHERE id = $1', [placeId]);
  if (!rows.length || rows[0].owner_id == null) throw notFound('Yer bulunamadı');
  const access = await agendaAccess(user, rows[0].owner_id);
  if (!access) throw notFound('Yer bulunamadı');
  if (perm && !access[perm]) throw forbidden(permMessage(perm));
  return { ownerId: rows[0].owner_id, access };
}

function baseUrl(req) {
  const proto = req.headers['x-forwarded-proto'] || req.protocol;
  return `${proto}://${req.get('host')}`;
}

const photoUrl = (req, id) => `${baseUrl(req)}/photos/${id}/image`;

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
    agendaId: row.owner_id,
    title: row.title,
    status: row.status,
    date: row.date,
    locationName: row.location_name,
    lat: row.lat,
    lng: row.lng,
    notes: row.notes,
    rating: row.rating,
    comment: row.comment,
    createdBy: row.created_by_name ?? null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    photoCount: row.photo_count !== undefined ? Number(row.photo_count) : undefined,
    coverUrl: row.cover_id ? photoUrl(req, row.cover_id) : null,
  };
}

function placeFields(body, partial) {
  if (!body || typeof body !== 'object') throw bad('JSON gövdesi gerekli');
  const out = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);
  const text = (k, col) => {
    if (!has(k)) return;
    const v = body[k];
    if (v !== null && typeof v !== 'string') throw bad(`${k} metin olmalı`);
    out[col] = v === null || v.trim() === '' ? null : v.trim();
  };

  if (has('title') || !partial) {
    const t = typeof body.title === 'string' ? body.title.trim() : '';
    if (!t) throw bad('Yer adı (title) gerekli');
    out.title = t;
  }
  if (has('status')) {
    if (!['planned', 'visited'].includes(body.status)) {
      throw bad("status 'planned' ya da 'visited' olmalı");
    }
    out.status = body.status;
  }
  if (has('date')) {
    const d = body.date;
    if (d !== null && !(typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d))) {
      throw bad('date YYYY-AA-GG biçiminde olmalı');
    }
    out.date = d;
  }
  text('locationName', 'location_name');
  for (const k of ['lat', 'lng']) {
    if (!has(k)) continue;
    const v = body[k];
    if (v !== null && (typeof v !== 'number' || !Number.isFinite(v))) throw bad(`${k} sayı olmalı`);
    out[k] = v;
  }
  text('notes', 'notes');
  if (has('rating')) {
    const r = body.rating;
    if (r !== null && !(Number.isInteger(r) && r >= 1 && r <= 5)) {
      throw bad('rating 1 ile 5 arasında tam sayı olmalı');
    }
    out.rating = r;
  }
  text('comment', 'comment');
  return out;
}

function boolField(body, key) {
  if (!Object.prototype.hasOwnProperty.call(body, key)) return undefined;
  if (typeof body[key] !== 'boolean') throw bad(`${key} true/false olmalı`);
  return body[key];
}

const PLACE_SELECT = `
  SELECT p.*, cu.name AS created_by_name,
         (SELECT count(*) FROM photos ph WHERE ph.place_id = p.id) AS photo_count,
         (SELECT ph.id FROM photos ph WHERE ph.place_id = p.id
            ORDER BY ph.created_at, ph.id LIMIT 1) AS cover_id
  FROM places p
  LEFT JOIN users cu ON cu.id = p.created_by`;

async function loadPlace(req, id) {
  const { rows } = await pool.query(`${PLACE_SELECT} WHERE p.id = $1`, [id]);
  if (!rows.length) throw notFound('Yer bulunamadı');
  return placeJson(req, rows[0]);
}

function invitationJson(r) {
  return {
    id: r.id,
    email: r.email,
    status: r.status,
    canAdd: r.can_add,
    canEdit: r.can_edit,
    canDelete: r.can_delete,
    createdAt: r.created_at,
    owner: r.owner_name ? { id: r.owner_id, name: r.owner_name, email: r.owner_email } : undefined,
    memberName: r.member_name ?? null,
  };
}

// ---------- Uygulama ----------

const app = express();
app.use(express.json({ limit: '1mb' }));

app.get('/', (_req, res) => res.json({ ok: true, service: 'hello-world-backend' }));

app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, db: 'ok' });
  } catch (e) {
    res.status(500).json({ ok: false, db: 'error', error: e.message });
  }
});

// ---------- Hesap ----------

app.post('/auth/register', h(async (req, res) => {
  const email = normEmail(req.body?.email);
  const password = req.body?.password;
  if (typeof password !== 'string' || password.length < 6) {
    throw bad('Şifre en az 6 karakter olmalı');
  }
  const rawName = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
  const name = rawName || email.split('@')[0];

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO users (email, name, password_hash) VALUES ($1, $2, $3)
       ON CONFLICT (email) DO NOTHING RETURNING id, email, name`,
      [email, name, await hashPassword(password)]
    );
    if (!rows.length) {
      await client.query('ROLLBACK');
      throw new HttpError(409, 'Bu e-postayla zaten bir hesap var. Giriş yapmayı dene.');
    }
    const user = rows[0];
    // İlk hesap, hesap özelliğinden önce eklenen yerleri sahiplenir
    const { rows: c } = await client.query('SELECT count(*)::int AS n FROM users');
    if (c[0].n === 1) {
      await client.query(
        'UPDATE places SET owner_id = $1, created_by = COALESCE(created_by, $1) WHERE owner_id IS NULL',
        [user.id]
      );
    }
    await client.query('COMMIT');
    res.status(201).json({ token: issueToken(user), user: userJson(user) });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}));

app.post('/auth/login', h(async (req, res) => {
  const email = normEmail(req.body?.email);
  const password = typeof req.body?.password === 'string' ? req.body.password : '';
  const { rows } = await pool.query('SELECT * FROM users WHERE email = $1', [email]);
  if (!rows.length || !(await checkPassword(password, rows[0].password_hash))) {
    throw new HttpError(401, 'E-posta ya da şifre hatalı');
  }
  res.json({ token: issueToken(rows[0]), user: userJson(rows[0]) });
}));

app.get('/me', auth, h(async (req, res) => {
  const { rows } = await pool.query(
    `SELECT count(*)::int AS n FROM invitations WHERE email = $1 AND status = 'pending'`,
    [req.user.email]
  );
  res.json({ user: userJson(req.user), pendingInvitations: rows[0].n });
}));

// ---------- Ajandalar ----------

app.get('/agendas', auth, h(async (req, res) => {
  const { rows } = await pool.query(
    `SELECT i.owner_id, u.name, u.email, i.can_add, i.can_edit, i.can_delete
     FROM invitations i JOIN users u ON u.id = i.owner_id
     WHERE i.email = $1 AND i.status = 'accepted'
     ORDER BY u.name`,
    [req.user.email]
  );
  res.json([
    {
      id: req.user.id,
      ownerName: req.user.name,
      ownerEmail: req.user.email,
      isOwner: true,
      canAdd: true,
      canEdit: true,
      canDelete: true,
    },
    ...rows.map((r) => ({
      id: r.owner_id,
      ownerName: r.name,
      ownerEmail: r.email,
      isOwner: false,
      canAdd: r.can_add,
      canEdit: r.can_edit,
      canDelete: r.can_delete,
    })),
  ]);
}));

// ---------- Davetler ----------

app.post('/invitations', auth, h(async (req, res) => {
  const email = normEmail(req.body?.email);
  if (email === req.user.email) throw bad('Kendini davet edemezsin');
  const canAdd = boolField(req.body, 'canAdd') ?? true;
  const canEdit = boolField(req.body, 'canEdit') ?? false;
  const canDelete = boolField(req.body, 'canDelete') ?? false;
  // Daha önce reddedildiyse ya da varsa: yetkileri güncelle; kabul edilmemişse yeniden beklet
  const { rows } = await pool.query(
    `INSERT INTO invitations (owner_id, email, can_add, can_edit, can_delete)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (owner_id, email) DO UPDATE
       SET can_add = EXCLUDED.can_add, can_edit = EXCLUDED.can_edit,
           can_delete = EXCLUDED.can_delete,
           status = CASE WHEN invitations.status = 'accepted' THEN 'accepted' ELSE 'pending' END,
           updated_at = now()
     RETURNING *`,
    [req.user.id, email, canAdd, canEdit, canDelete]
  );
  const member = await pool.query('SELECT name FROM users WHERE email = $1', [email]);
  res.status(201).json(invitationJson({ ...rows[0], member_name: member.rows[0]?.name }));
}));

app.get('/invitations/sent', auth, h(async (req, res) => {
  const { rows } = await pool.query(
    `SELECT i.*, u.name AS member_name
     FROM invitations i LEFT JOIN users u ON u.email = i.email
     WHERE i.owner_id = $1 ORDER BY i.created_at DESC`,
    [req.user.id]
  );
  res.json(rows.map(invitationJson));
}));

app.get('/invitations/received', auth, h(async (req, res) => {
  const { rows } = await pool.query(
    `SELECT i.*, u.name AS owner_name, u.email AS owner_email
     FROM invitations i JOIN users u ON u.id = i.owner_id
     WHERE i.email = $1 AND i.status = 'pending' ORDER BY i.created_at DESC`,
    [req.user.email]
  );
  res.json(rows.map(invitationJson));
}));

async function getInvitation(id) {
  const { rows } = await pool.query('SELECT * FROM invitations WHERE id = $1', [id]);
  if (!rows.length) throw notFound('Davet bulunamadı');
  return rows[0];
}

app.put('/invitations/:id', auth, h(async (req, res) => {
  const inv = await getInvitation(parseId(req.params.id));
  if (inv.owner_id !== req.user.id) throw notFound('Davet bulunamadı');
  const fields = {};
  for (const [k, col] of [['canAdd', 'can_add'], ['canEdit', 'can_edit'], ['canDelete', 'can_delete']]) {
    const v = boolField(req.body || {}, k);
    if (v !== undefined) fields[col] = v;
  }
  const cols = Object.keys(fields);
  if (cols.length) {
    await pool.query(
      `UPDATE invitations SET ${cols.map((c, i) => `${c} = $${i + 1}`).join(', ')}, updated_at = now()
       WHERE id = $${cols.length + 1}`,
      [...cols.map((c) => fields[c]), inv.id]
    );
  }
  const { rows } = await pool.query(
    `SELECT i.*, u.name AS member_name FROM invitations i
     LEFT JOIN users u ON u.email = i.email WHERE i.id = $1`,
    [inv.id]
  );
  res.json(invitationJson(rows[0]));
}));

async function respond(req, res, status) {
  const inv = await getInvitation(parseId(req.params.id));
  if (inv.email !== req.user.email) throw notFound('Davet bulunamadı');
  if (inv.status !== 'pending') throw bad('Bu davet zaten yanıtlanmış');
  await pool.query('UPDATE invitations SET status = $1, updated_at = now() WHERE id = $2', [status, inv.id]);
  res.json({ ok: true, status });
}

app.post('/invitations/:id/accept', auth, h((req, res) => respond(req, res, 'accepted')));
app.post('/invitations/:id/decline', auth, h((req, res) => respond(req, res, 'declined')));

app.delete('/invitations/:id', auth, h(async (req, res) => {
  const inv = await getInvitation(parseId(req.params.id));
  // Sahip üyeyi çıkarabilir, davetli de kendisi ayrılabilir
  if (inv.owner_id !== req.user.id && inv.email !== req.user.email) throw notFound('Davet bulunamadı');
  await pool.query('DELETE FROM invitations WHERE id = $1', [inv.id]);
  res.status(204).end();
}));

// ---------- Yerler ----------

app.get('/places', auth, h(async (req, res) => {
  const ownerId = req.query.agenda ? parseId(req.query.agenda) : req.user.id;
  await requireAgenda(req.user, ownerId, 'canView');
  const { status } = req.query;
  const params = [ownerId];
  let sql = `${PLACE_SELECT} WHERE p.owner_id = $1`;
  if (status) {
    if (!['planned', 'visited'].includes(status)) throw bad('Geçersiz status');
    params.push(status);
    sql += ' AND p.status = $2';
  }
  sql += status === 'visited'
    ? ' ORDER BY p.date DESC NULLS LAST, p.updated_at DESC'
    : ' ORDER BY p.date ASC NULLS LAST, p.created_at DESC';
  const { rows } = await pool.query(sql, params);
  res.json(rows.map((r) => placeJson(req, r)));
}));

app.post('/places', auth, h(async (req, res) => {
  const ownerId = req.body?.agendaId != null ? parseId(req.body.agendaId) : req.user.id;
  await requireAgenda(req.user, ownerId, 'canAdd');
  const f = placeFields(req.body, false);
  f.owner_id = ownerId;
  f.created_by = req.user.id;
  const cols = Object.keys(f);
  const { rows } = await pool.query(
    `INSERT INTO places (${cols.join(', ')})
     VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')}) RETURNING id`,
    cols.map((c) => f[c])
  );
  res.status(201).json(await loadPlace(req, rows[0].id));
}));

app.get('/places/:id', auth, h(async (req, res) => {
  const id = parseId(req.params.id);
  const { access } = await requirePlace(req.user, id, 'canView');
  const place = await loadPlace(req, id);
  const photos = await pool.query(
    `SELECT id, place_id, filename, mime_type, size_bytes, created_at
     FROM photos WHERE place_id = $1 ORDER BY created_at, id`,
    [id]
  );
  res.json({ ...place, access, photos: photos.rows.map((r) => photoJson(req, r)) });
}));

app.put('/places/:id', auth, h(async (req, res) => {
  const id = parseId(req.params.id);
  await requirePlace(req.user, id, 'canEdit');
  const f = placeFields(req.body, true);
  const cols = Object.keys(f);
  if (cols.length) {
    await pool.query(
      `UPDATE places SET ${cols.map((c, i) => `${c} = $${i + 1}`).join(', ')}, updated_at = now()
       WHERE id = $${cols.length + 1}`,
      [...cols.map((c) => f[c]), id]
    );
  }
  res.json(await loadPlace(req, id));
}));

app.delete('/places/:id', auth, h(async (req, res) => {
  const id = parseId(req.params.id);
  await requirePlace(req.user, id, 'canDelete');
  await pool.query('DELETE FROM places WHERE id = $1', [id]);
  res.status(204).end();
}));

app.post('/places/:id/photos', auth, upload.single('photo'), h(async (req, res) => {
  const id = parseId(req.params.id);
  await requirePlace(req.user, id, 'canAdd');
  if (!req.file) throw bad('"photo" alanında dosya yok');
  const { originalname, mimetype, size, buffer } = req.file;
  const { rows } = await pool.query(
    `INSERT INTO photos (place_id, filename, mime_type, size_bytes, data)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING id, place_id, filename, mime_type, size_bytes, created_at`,
    [id, originalname || 'photo.jpg', mimetype, size, buffer]
  );
  res.status(201).json(photoJson(req, rows[0]));
}));

// ---------- Fotoğraflar ----------

async function requirePhoto(user, photoId, perm) {
  const { rows } = await pool.query('SELECT place_id FROM photos WHERE id = $1', [photoId]);
  if (!rows.length || rows[0].place_id == null) throw notFound();
  await requirePlace(user, rows[0].place_id, perm);
}

app.get('/photos/:id/image', auth, h(async (req, res) => {
  const id = parseId(req.params.id);
  await requirePhoto(req.user, id, 'canView');
  const { rows } = await pool.query('SELECT mime_type, data FROM photos WHERE id = $1', [id]);
  res.set('Content-Type', rows[0].mime_type);
  res.set('Cache-Control', 'private, max-age=31536000, immutable');
  res.send(rows[0].data);
}));

app.delete('/photos/:id', auth, h(async (req, res) => {
  const id = parseId(req.params.id);
  await requirePhoto(req.user, id, 'canDelete');
  await pool.query('DELETE FROM photos WHERE id = $1', [id]);
  res.status(204).end();
}));

// ---------- Hata yakalayıcı ----------

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  if (err instanceof multer.MulterError) {
    const msg = err.code === 'LIMIT_FILE_SIZE' ? `Dosya ${MAX_MB} MB'tan büyük` : err.message;
    return res.status(400).json({ error: msg });
  }
  if (err instanceof HttpError) return res.status(err.status).json({ error: err.message });
  if (err && err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Geçersiz JSON' });
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
