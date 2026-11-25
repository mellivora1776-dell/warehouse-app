import { createClient } from '@supabase/supabase-js'

// This endpoint has only the project's public client key. The opaque bearer
// credential permits a single database operation: submitting a draft.
export default function handler(req, res) {
  return handleDocument(req, res, false)
}
export async function handleDocument(req, res, preview) {
  res.setHeader('Cache-Control', 'no-store')
  if (req.method !== 'POST') return res.status(405).end()
  const token = /^Bearer ([0-9a-f]{64})$/i.exec(
    req.headers.authorization || '',
  )?.[1]
  if (!token)
    return res.status(401).json({ error: '자료 등록용 키가 필요합니다.' })
  if (!req.body || Buffer.byteLength(JSON.stringify(req.body)) > 250000)
    return res
      .status(400)
      .json({ error: '분석 JSON의 크기 또는 형식을 확인해 주세요.' })
  try {
    const db = createClient(
      process.env.VITE_SUPABASE_URL,
      process.env.VITE_SUPABASE_PUBLISHABLE_KEY,
      {
        auth: { persistSession: false, autoRefreshToken: false },
      },
    )
    const { data, error } = await db.rpc(
      preview ? 'wm3_preview_token' : 'wm2_submit',
      {
        p_token: token,
        p_doc: req.body,
      },
    )
    if (error) {
      const status =
        error.code === '42501'
          ? 403
          : [
                'WM2_DOCUMENT_CONFLICT',
                'WM3_PREFLIGHT_CHANGED',
                'WM3_RECEIPT_MISMATCH',
              ].includes(error.message)
            ? 409
            : 422
      return res.status(status).json({
        error: /^WM[\w]+$/.test(error.message)
          ? error.message
          : '입력 자료의 날짜·수량·행 식별자를 확인해 주세요.',
      })
    }
    if (preview) return res.status(200).json(data)
    return res.status(data.duplicate ? 200 : 201).json({
      document: data.id,
      state: data.status,
      duplicate: data.duplicate,
      stock_posted: false,
      already_closed: data.already_closed ?? false,
      verified: data.verified,
      stored_lines: data.stored_lines,
    })
  } catch {
    return res
      .status(503)
      .json({ error: '자료 등록 서버 연결을 확인해 주세요.' })
  }
}
