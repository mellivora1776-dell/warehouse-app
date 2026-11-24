import { createClient } from '@supabase/supabase-js'
import { createHash } from 'node:crypto'

const bucket = 'warehouse-documents-v2'
function mediaType(buf) {
  if (buf.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])))
    return 'image/png'
  if (buf.subarray(0, 3).equals(Buffer.from([255, 216, 255])))
    return 'image/jpeg'
  if (
    buf.subarray(0, 4).toString() === 'RIFF' &&
    buf.subarray(8, 12).toString() === 'WEBP'
  )
    return 'image/webp'
  if (buf.subarray(0, 5).toString() === '%PDF-') return 'application/pdf'
}
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  if (!['POST', 'GET'].includes(req.method)) return res.status(405).end()
  const auth = req.headers.authorization
  if (!auth?.startsWith('Bearer ')) return res.status(401).end()
  const opts = { auth: { persistSession: false, autoRefreshToken: false } }
  try {
    const url = process.env.VITE_SUPABASE_URL
    const user = createClient(url, process.env.VITE_SUPABASE_PUBLISHABLE_KEY, {
      ...opts,
      global: { headers: { Authorization: auth } },
    })
    const profile = await user.rpc('wm_profile')
    if (profile.error || profile.data?.role !== 'admin')
      return res.status(403).json({ error: '관리자 권한이 필요합니다.' })
    const storage = createClient(
      url,
      process.env.SUPABASE_SERVICE_ROLE_KEY,
      opts,
    ).storage.from(bucket)
    if (req.method === 'GET') {
      const ref = await user.rpc('wm2_file_ref', { p_doc: req.query.document })
      if (ref.error || !ref.data)
        return res.status(404).json({ error: '보관된 원본이 없습니다.' })
      const signed = await storage.createSignedUrl(ref.data, 60)
      if (signed.error) throw signed.error
      return res.json({ url: signed.data.signedUrl })
    }
    const encoded = req.body?.content
    if (
      typeof encoded !== 'string' ||
      !encoded.length ||
      encoded.length > 4194304 ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)
    )
      return res
        .status(400)
        .json({ error: '파일은 3MB까지 첨부할 수 있습니다.' })
    const bytes = Buffer.from(encoded, 'base64'),
      mime = mediaType(bytes)
    if (!mime)
      return res
        .status(415)
        .json({ error: 'JPG, PNG, WebP 또는 PDF 원본을 선택해 주세요.' })
    const sha = createHash('sha256').update(bytes).digest('hex')
    const uploaded = await storage.upload(sha, bytes, {
      contentType: mime,
      upsert: false,
    })
    if (uploaded.error && !(await storage.exists(sha)).data)
      throw uploaded.error
    return res.json({ sha256: sha })
  } catch {
    return res.status(503).json({ error: '원본 저장소에 연결할 수 없습니다.' })
  }
}
