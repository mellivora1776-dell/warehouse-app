import { createClient } from '@supabase/supabase-js'
import { createHash, randomBytes } from 'node:crypto'

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  if (req.method !== 'POST') return res.status(405).end()
  const pin = req.body?.pin
  if (typeof pin !== 'string' || !/^\d{8}$/.test(pin))
    return res.status(400).json({ error: 'PIN 8자리를 입력해 주세요.' })
  const url = process.env.VITE_SUPABASE_URL || process.env.SUPABASE_URL
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!url || !secret)
    return res
      .status(503)
      .json({ error: '로그인 서버의 연결 설정을 확인해 주세요.' })
  const options = {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
  }
  const server = createClient(url, secret, options)
  try {
    const address = String(
      req.headers['x-vercel-forwarded-for'] ||
        req.socket?.remoteAddress ||
        'local',
    )
      .split(',')[0]
      .trim()
    const { data: ticket, error } = await server.rpc('wm_pin_check', {
      p_pin: pin,
      p_client: createHash('sha256').update(address).digest('hex'),
    })
    if (error) throw error
    if (ticket.limited)
      return res
        .status(429)
        .json({ error: '로그인 시도가 많습니다. 10분 후 다시 시도해 주세요.' })
    if (!ticket.id)
      return res.status(401).json({ error: 'PIN을 확인해 주세요.' })
    const email = 'pin-' + ticket.id + '@warehouse.invalid'
    // The UUID is assigned when a PIN is issued. Browser sign-up cannot choose it.
    const admin = server.auth.admin
    let identity = await admin.getUserById(ticket.id)
    if (!identity.data.user) {
      const created = await admin.createUser({
        id: ticket.id,
        email,
        email_confirm: true,
        password: randomBytes(32).toString('hex'),
        app_metadata: { warehouse_pin: true },
      })
      if (created.error) identity = await admin.getUserById(ticket.id)
      else identity = created
    }
    if (
      identity.data.user?.email !== email ||
      !identity.data.user.app_metadata.warehouse_pin
    )
      throw new Error('identity')
    // generateLink produces a one-time token on the server and sends no email.
    const link = await admin.generateLink({ type: 'magiclink', email })
    if (link.error || link.data.user.id !== ticket.id)
      throw new Error('auth link')
    const { data, error: authError } = await server.auth.verifyOtp({
      type: 'magiclink',
      token_hash: link.data.properties.hashed_token,
    })
    if (authError || !data.session || data.user?.id !== ticket.id)
      throw new Error('auth session')
    return res
      .status(200)
      .json({
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
      })
  } catch {
    return res
      .status(503)
      .json({
        error:
          '로그인 서비스를 사용할 수 없습니다. 잠시 후 다시 시도해 주세요.',
      })
  }
}
