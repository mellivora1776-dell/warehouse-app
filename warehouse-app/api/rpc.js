// ============================================================
//  api/rpc.js  ·  창고 재고 관리 — 단일 진입점
//
//  PRD 5-8-4 / 7-3-1 구현:
//   · RLS 가 anon 을 전면 차단하므로 모든 접근이 여기를 지난다
//   · service_role 키는 Vercel 환경변수에만 있고 브라우저로 나가지 않는다
//   · 권한 판정(관리자/보조/조회)을 여기서 한다. 화면 제어는 편의일 뿐이다
//
//  환경변수 (Vercel > Settings > Environment Variables)
//   SUPABASE_URL               https://xxxx.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY  Project Settings > API > service_role
//   SESSION_SECRET             아무 긴 랜덤 문자열 (openssl rand -base64 32)
// ============================================================

const crypto = require('crypto');

const SB     = process.env.SUPABASE_URL;
const KEY    = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SECRET = process.env.SESSION_SECRET || '';
const TTL_MS = 12 * 60 * 60 * 1000; // 세션 12시간

// ── Supabase REST ───────────────────────────────
async function sb(path, init = {}) {
  const r = await fetch(`${SB}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: KEY,
      authorization: `Bearer ${KEY}`,
      'content-type': 'application/json',
      ...(init.headers || {}),
    },
  });
  const text = await r.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  if (!r.ok) {
    const msg = (body && (body.message || body.hint || body.details)) || `DB 오류 (${r.status})`;
    const err = new Error(msg);
    err.status = r.status === 404 ? 500 : 400;
    throw err;
  }
  return body;
}
const rpc = (fn, args) => sb(`rpc/${fn}`, { method: 'POST', body: JSON.stringify(args || {}) });
const sel = (table, qs) => sb(`${table}?${qs}`);

// ── 세션 토큰 (HMAC) ────────────────────────────
function sign(payload) {
  const b = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const s = crypto.createHmac('sha256', SECRET).update(b).digest('base64url');
  return `${b}.${s}`;
}
function readToken(req) {
  const raw = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!raw || !raw.includes('.')) return null;
  const [b, s] = raw.split('.');
  const want = crypto.createHmac('sha256', SECRET).update(b).digest('base64url');
  if (s.length !== want.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(s), Buffer.from(want))) return null;
  let p;
  try { p = JSON.parse(Buffer.from(b, 'base64url').toString()); } catch { return null; }
  if (!p.exp || Date.now() > p.exp) return null;
  return p;
}

// ── PIN 시도 제한 (인스턴스 단위, 최선 노력) ────
const attempts = new Map();
function throttle(ip) {
  const now = Date.now();
  const a = attempts.get(ip) || { n: 0, at: now };
  if (now - a.at > 10 * 60 * 1000) { a.n = 0; a.at = now; }
  a.n += 1; a.at = now;
  attempts.set(ip, a);
  return a.n <= 12;
}

// ── 권한 (PRD 5-8-1) ────────────────────────────
const ADMIN_ONLY = new Set([
  'outbound', 'inbound', 'counts', 'reverse', 'amend', 'editNote',
  'productUpdate', 'productFlags', 'aliasAdd', 'aliasDelete', 'locationAdd',
]);
const LIMITED_HISTORY = new Set(['assistant', 'guest']); // 이력 조회 '제한'

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST 만 받습니다' });
  if (!SB || !KEY || !SECRET) {
    return res.status(500).json({ error: '서버 환경변수가 설정되지 않았습니다 (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SESSION_SECRET)' });
  }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
  body = body || {};
  const action = body.action;

  try {
    // ── 로그인 ──
    if (action === 'login') {
      const ip = (req.headers['x-forwarded-for'] || 'local').split(',')[0].trim();
      if (!throttle(ip)) return res.status(429).json({ error: '시도가 너무 많습니다. 10분 뒤에 다시 해주세요' });
      const pin = String(body.pin || '');
      if (!/^\d{4,8}$/.test(pin)) return res.status(400).json({ error: 'PIN 형식이 맞지 않습니다' });
      const rows = await rpc('verify_pin', { p_pin: pin });
      const me = Array.isArray(rows) ? rows[0] : rows;
      if (!me) return res.status(401).json({ error: 'PIN 이 맞지 않습니다' });
      const token = sign({ id: me.id, name: me.name, role: me.role, exp: Date.now() + TTL_MS });
      return res.json({ token, me: { id: me.id, name: me.name, role: me.role } });
    }

    // ── 이후는 전부 세션 필요 ──
    const me = readToken(req);
    if (!me) return res.status(401).json({ error: '세션이 만료되었습니다. 다시 로그인해주세요' });
    if (ADMIN_ONLY.has(action) && me.role !== 'admin') {
      return res.status(403).json({ error: '이 작업은 마스터 권한만 가능합니다' });
    }

    switch (action) {
      // 카탈로그 일괄 적재 — 이후 검색·전개는 브라우저에서 한다
      case 'bootstrap': {
        const [products, aliases, components, locations, users, inventory] = await Promise.all([
          sel('products', 'select=*&order=code.asc'),
          sel('product_aliases', 'select=id,product_id,alias,source,note&order=id.asc'),
          sel('product_components', 'select=id,parent_id,child_id,part_label,qty,rule_type,note&order=id.asc'),
          sel('locations', 'select=*&order=sort_order.asc,code.asc'),
          sel('users', 'select=id,name,role,is_active&is_active=is.true&order=id.asc'),
          sel('inventory', 'select=id,product_id,location_id,qty&qty=gt.0'),
        ]);
        return res.json({ me, products, aliases, components, locations, users, inventory });
      }

      case 'inventory':
        return res.json({ inventory: await sel('inventory', 'select=id,product_id,location_id,qty&qty=gt.0') });

      case 'movements': {
        const f = body.filters || {};
        const q = ['select=*', 'order=occurred_at.desc'];
        let from = f.from;
        if (LIMITED_HISTORY.has(me.role)) {
          const wk = new Date(Date.now() - 7 * 864e5).toISOString();
          if (!from || from < wk) from = wk; // 제한: 최근 7일
        }
        if (from) q.push(`occurred_at=gte.${encodeURIComponent(from)}`);
        if (f.to) q.push(`occurred_at=lte.${encodeURIComponent(f.to)}`);
        if (f.code) q.push(`code=eq.${encodeURIComponent(f.code)}`);
        if (f.reason) q.push(`reason=eq.${encodeURIComponent(f.reason)}`);
        q.push(`limit=${Math.min(Number(f.limit) || 200, 500)}`);
        return res.json({ rows: await sel('v_movements', q.join('&')) });
      }

      case 'mismatch':
        return res.json({ rows: await sel('v_stock_mismatch', 'select=*&limit=200') });

      case 'audit':
        return res.json({
          rows: await sel('product_audit',
            `select=*&product_id=eq.${Number(body.product_id)}&order=changed_at.desc&limit=50`),
        });

      // ── 쓰기 (마스터 전용) ──
      case 'outbound':
        return res.json(await rpc('post_outbound', {
          p_lines: body.lines,
          p_created_by: me.id,
          p_performed_by: body.performed_by || me.id,
          p_occurred_at: body.occurred_at || new Date().toISOString(),
          p_ref_no: body.ref_no || null,
        }));

      case 'inbound':
        return res.json(await rpc('post_inbound', {
          p_lines: body.lines,
          p_created_by: me.id,
          p_performed_by: body.performed_by || me.id,
          p_occurred_at: body.occurred_at || new Date().toISOString(),
          p_ref_no: body.ref_no || null,
        }));

      case 'counts':
        return res.json(await rpc('post_counts', {
          p_lines: body.lines, p_created_by: me.id, p_memo: body.memo || null,
        }));

      case 'reverse':
        return res.json({ id: await rpc('reverse_movement', {
          p_movement_id: body.movement_id, p_created_by: me.id, p_memo: body.memo || null,
        }) });

      case 'amend':
        return res.json(await rpc('amend_movement', {
          p_movement_id: body.movement_id,
          p_created_by: me.id,
          p_new_qty: body.qty ?? null,
          p_new_location_id: body.location_id ?? null,
          p_new_reason: body.reason || null,
          p_new_counterparty: body.counterparty ?? null,
          p_new_receiver: body.receiver ?? null,
          p_new_spec_note: body.spec_note ?? null,
          p_memo: body.memo || null,
        }));

      case 'editNote':
        return res.json({ id: await rpc('edit_movement_note', {
          p_movement_id: body.movement_id,
          p_created_by: me.id,
          p_counterparty: body.counterparty ?? null,
          p_receiver: body.receiver ?? null,
          p_spec_note: body.spec_note ?? null,
          p_memo: body.memo ?? null,
          p_performed_by: body.performed_by ?? null,
        }) });

      case 'productUpdate':
        return res.json({ product: await rpc('update_product', {
          p_id: body.id, p_patch: body.patch, p_actor: me.id,
        }) });

      case 'productFlags':
        return res.json({ changed: await rpc('set_product_flags', {
          p_ids: body.ids, p_field: body.field, p_value: body.value, p_actor: me.id,
        }) });

      case 'aliasAdd':
        return res.json({
          rows: await sb('product_aliases', {
            method: 'POST',
            headers: { Prefer: 'return=representation' },
            body: JSON.stringify({
              product_id: body.product_id, alias: body.alias,
              source: '운영중학습', note: body.note || null, created_by: me.id,
            }),
          }),
        });

      case 'aliasDelete':
        await sb(`product_aliases?id=eq.${Number(body.id)}`, { method: 'DELETE' });
        return res.json({ ok: true });

      case 'locationAdd':
        return res.json({
          rows: await sb('locations', {
            method: 'POST',
            headers: { Prefer: 'return=representation' },
            body: JSON.stringify({
              zone: body.zone, level: body.level || '바닥',
              sort_order: Number(body.sort_order) || 0,
            }),
          }),
        });

      default:
        return res.status(400).json({ error: `알 수 없는 요청입니다 (${action})` });
    }
  } catch (e) {
    return res.status(e.status || 400).json({ error: e.message || '처리하지 못했습니다' });
  }
};
