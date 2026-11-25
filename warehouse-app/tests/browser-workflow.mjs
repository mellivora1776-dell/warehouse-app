// This runner only connects to loopback QA services and uses a fixture named 검증용.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, extname, resolve } from 'node:path'
import { randomUUID, createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { build } from 'vite'
import { chromium } from 'playwright-core'
import { verifyAnalysisMobile } from './mobile-analysis.mjs'
import pin from '../api/pin.js'
import intake from '../api/intake.js'
import preflight from '../api/preflight.js'
import evidence from '../api/evidence.js'

const config = JSON.parse(await readFile(process.env.WM_QA_CONFIG, 'utf8'))
const root = fileURLToPath(new URL('../', import.meta.url)),
  dist = await mkdtemp(join(tmpdir(), 'wm-qa-web-'))
const routes = {
  '/api/pin': pin,
  '/api/intake': intake,
  '/api/preflight': preflight,
  '/api/evidence': evidence,
}
const mime = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
}
const ports = {
  auth: config.authPort ?? 35491,
  rest: config.restPort ?? 35492,
  storage: config.storagePort ?? 35490,
}
const server = createServer(async (req, res) => {
  try {
    const parts = []
    for await (const part of req) parts.push(part)
    const body = Buffer.concat(parts),
      u = new URL(req.url, 'http://localhost')
    if (routes[u.pathname]) {
      req.query = Object.fromEntries(u.searchParams)
      req.body = body.length ? JSON.parse(body) : undefined
      res.status = (n) => {
        res.statusCode = n
        return res
      }
      res.json = (data) => {
        res.setHeader('Content-Type', 'application/json')
        res.end(JSON.stringify(data))
      }
      return await routes[u.pathname](req, res)
    }
    const api = /^\/sb\/(auth|rest|storage)\/v1(\/.*)?$/.exec(u.pathname)
    if (api) {
      const target =
          'http://127.0.0.1:' + ports[api[1]] + (api[2] || '/') + u.search,
        headers = {}
      for (const k of [
        'content-type',
        'authorization',
        'apikey',
        'accept',
        'prefer',
        'x-client-info',
        'x-upsert',
        'cache-control',
        'accept-profile',
        'content-profile',
      ])
        if (req.headers[k]) headers[k] = req.headers[k]
      const r = await fetch(target, {
        method: req.method,
        headers,
        body: body.length ? body : undefined,
      })
      res.statusCode = r.status
      res.setHeader(
        'Content-Type',
        r.headers.get('content-type') || 'application/json',
      )
      res.end(Buffer.from(await r.arrayBuffer()))
      return
    }
    const path = resolve(
      dist,
      '.' + (u.pathname === '/' ? '/index.html' : u.pathname),
    )
    assert.ok(path.startsWith(dist + '/'))
    res.setHeader('Content-Type', mime[extname(path)] ?? 'text/plain')
    res.end(await readFile(path))
  } catch (e) {
    res.statusCode = 500
    res.end('QA server error')
    console.error(e.message)
  }
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const origin = 'http://127.0.0.1:' + server.address().port,
  sb = origin + '/sb'
process.env.VITE_SUPABASE_URL = sb
process.env.SUPABASE_URL = sb
process.env.SUPABASE_SERVICE_ROLE_KEY = config.service
process.env.VITE_SUPABASE_PUBLISHABLE_KEY = config.anon
let browser
try {
  await build({
    root,
    logLevel: 'warn',
    define: {
      'process.env.NODE_ENV': JSON.stringify('production'),
      'import.meta.env.VITE_SUPABASE_URL': JSON.stringify(sb),
      'import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY': JSON.stringify(
        config.anon,
      ),
    },
    build: { outDir: dist, emptyOutDir: true },
  })
  const headers = (t) => ({
    'content-type': 'application/json',
    authorization: 'Bearer ' + t,
    apikey: config.anon,
  })
  const getToken = async (role) => {
    const r = await fetch(origin + '/api/pin', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ pin: config.pins[role] }),
    })
    assert.equal(r.status, 200)
    return (await r.json()).access_token
  }
  const [ops, employee] = await Promise.all([
    getToken('admin'),
    getToken('staff'),
  ])
  const rpc = async (name, args = {}, token = ops) => {
    const r = await fetch(sb + '/rest/v1/rpc/' + name, {
      method: 'POST',
      headers: headers(token),
      body: JSON.stringify(args),
    })
    const raw = await r.text()
    const b = raw ? JSON.parse(raw) : null
    assert.ok(r.ok, JSON.stringify({ name, error: b?.message }))
    return b
  }
  const item = (await rpc('wm_items', { p_query: '검증용' })).rows.find(
    (i) => i.name.startsWith('검증용') && i.name.length > 24,
  )
  assert.ok(item, 'A long-name test fixture starting with 검증용 is required')
  const detail = await rpc('wm_item', { p_item: item.id })
  await rpc('wm_change', {
    p_item: item.id,
    p_kind: 'count',
    p_amount: 10,
    p_memo: '격리 QA 시작',
    p_revision: detail.revision,
    p_request: randomUUID(),
  })
  let day
  for (let n = 1; n < 730; n++) {
    const d = new Date(Date.UTC(2041, 0, n)).toISOString().slice(0, 10),
      w = await rpc('wm2_day', { p_day: d })
    if (!w.rows.length && !w.issues.length) {
      day = d
      break
    }
  }
  assert.ok(day)
  const key = randomUUID(),
    doc = {
      schema_version: 2,
      document_id: 'qa-' + key + '-1',
      case_id: 'qa-' + key,
      version: 1,
      work_date: day,
      category: 'sale',
      document_type: 'QA 출고지시서',
      customer: '시험 거래처',
      method: '직납',
      source: { text: '검증 전용 원문' },
      lines: [{ line_id: 'A', raw_name: item.name, qty: 5 }],
    }
  const intakeToken = (await rpc('wm2_key', { p_action: 'rotate' })).token
  const send = async (document) => {
    const pre = await fetch(origin + '/api/preflight', {
      method: 'POST',
      headers: headers(intakeToken),
      body: JSON.stringify(document),
    })
    assert.equal(pre.status, 200)
    const plan = await pre.json()
    assert.ok(plan.can_submit, JSON.stringify(plan.blockers))
    const r = await fetch(origin + '/api/intake', {
      method: 'POST',
      headers: headers(intakeToken),
      body: JSON.stringify({ ...document, preview_stamp: plan.stamp }),
    })
    return { status: r.status, data: await r.json() }
  }
  const first = await send(doc)
  assert.equal(first.status, 201)
  assert.equal(first.data.stock_posted, false)
  assert.ok(first.data.verified)
  assert.equal(first.data.stored_lines[0].stock_qty, 5)
  assert.equal((await send(doc)).data.duplicate, true)
  browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium',
    args: ['--no-sandbox'],
    headless: true,
  })
  const phone = await browser.newContext({
      viewport: { width: 320, height: 740 },
      isMobile: true,
      hasTouch: true,
      locale: 'ko-KR',
    }),
    pc = await browser.newContext({
      viewport: { width: 1280, height: 850 },
      locale: 'ko-KR',
    })
  const a = await phone.newPage(),
    s = await pc.newPage()
  const exceptions = []
  for (const p of [a, s]) p.on('pageerror', (e) => exceptions.push(e.message))
  async function login(p, role) {
    await p.goto(origin)
    await p.getByLabel('PIN 번호').fill(config.pins[role])
    await p.getByRole('button', { name: '로그인', exact: true }).click()
    await p.getByRole('heading', { name: '재고 조회' }).waitFor()
  }
  await Promise.all([login(a, 'admin'), login(s, 'staff')])
  const popup = a.getByRole('dialog', { name: '미마감 내역' })
  await popup.getByRole('button', { name: day }).waitFor()
  await popup.getByRole('button', { name: '나중에 확인' }).click()
  const navigate = async (pg, mobile, id, title) => {
    if (mobile) await pg.getByLabel('업무 메뉴').selectOption(id)
    else
      await pg
        .getByRole('navigation')
        .getByRole('button', { name: title, exact: true })
        .click()
    await pg.getByRole('heading', { name: title, exact: true }).waitFor()
  }
  async function fits(p) {
    const size = await p.evaluate(() => ({
      window: [document.documentElement.scrollWidth, innerWidth],
      dialogs: [...document.querySelectorAll('dialog[open]')].map((d) => [
        d.scrollWidth,
        d.clientWidth,
      ]),
    }))
    assert.ok(
      size.window[0] <= size.window[1] &&
        size.dialogs.every(([a, b]) => a <= b + 1),
      JSON.stringify(size),
    )
  }
  await navigate(a, true, 'picking', '피킹리스트')
  await a.getByLabel('출고 날짜').fill(day)
  await a.getByLabel(item.name + ' 피킹 완료').click()
  assert.ok(await a.getByRole('checkbox').isChecked())
  await fits(a)
  const newer = {
    ...doc,
    document_id: 'qa-' + key + '-2',
    version: 2,
    replaces: doc.document_id,
    lines: [{ ...doc.lines[0], qty: 3 }],
  }
  await navigate(a, true, 'intake', '분석 자료 등록')
  await a.getByLabel('분석 결과 JSON').fill(JSON.stringify(newer))
  await a.getByRole('button', { name: '등록 전 사전 검증' }).click()
  await a.getByRole('button', { name: '검토 자료 등록' }).click()
  await a.getByText(/검토 자료를 등록했습니다/).waitFor()
  await navigate(a, true, 'picking', '피킹리스트')
  await a.getByText(/기존 피킹 변경/).waitFor()
  assert.equal(await a.getByRole('checkbox').isChecked(), false)
  const internal = {
    ...doc,
    document_id: 'internal-' + key,
    case_id: 'internal-' + key,
    category: 'production_out',
    method: null,
    lines: [{ ...doc.lines[0], qty: 2 }],
  }
  assert.equal((await send(internal)).status, 201)
  await navigate(a, true, 'daily', '일일 마감')
  const card = a.locator('.close-item').filter({ hasText: item.name })
  await card.locator('summary').click()
  await card.getByText('생산출고', { exact: true }).waitFor()
  assert.equal(await a.locator('.close-item').count(), 1)
  const trades = card.locator('.trade')
  await trades
    .filter({ hasText: '시험 거래처 · 직납' })
    .getByRole('button', { name: '거래 검토' })
    .click()
  let dialog = a.getByRole('dialog', { name: '거래 검토' })
  await dialog.getByLabel('검토 수량').fill('2')
  await dialog.getByText(/현재 10개 → 예상 6개/).waitFor()
  await fits(a)
  await dialog.getByRole('button', { name: '검토 저장' }).click()
  await dialog.waitFor({ state: 'hidden' })
  if (!(await card.evaluate((e) => e.open)))
    await card.locator('summary').click()
  await trades
    .filter({ hasText: '생산출고' })
    .getByRole('button', { name: '거래 검토' })
    .click()
  dialog = a.getByRole('dialog', { name: '거래 검토' })
  await dialog.getByLabel('검토 수량').fill('1')
  await dialog.getByText(/현재 10개 → 예상 7개/).waitFor()
  await dialog.getByRole('button', { name: '검토 저장' }).click()
  await dialog.waitFor({ state: 'hidden' })
  await card
    .locator('.close-numbers span')
    .filter({ hasText: '예상 마감' })
    .getByText('7', { exact: true })
    .waitFor()
  if (process.env.WM_QA_REVIEW_PNG)
    await a.screenshot({ path: process.env.WM_QA_REVIEW_PNG, fullPage: true })
  await fits(a)
  const stock = s.getByRole('button', { name: new RegExp(item.name) })
  await stock.waitFor()
  assert.match(await stock.textContent(), /10대/)
  await a.getByRole('button', { name: '일일 마감 승인', exact: true }).click()
  await a.getByRole('button', { name: '확인하고 마감 확정' }).click()
  await a.getByText(/1차 마감을 저장했습니다/).waitFor()
  await s.reload()
  await stock.waitFor()
  assert.match(await stock.textContent(), /7대/)
  await stock.click()
  await s
    .getByRole('dialog')
    .locator('.movement-row')
    .filter({ hasText: day })
    .getByText('시험 거래처 · 직납')
    .waitFor()
  assert.equal(
    await s.getByRole('button', { name: '실사 수량 수정' }).count(),
    0,
  )
  await s.getByLabel('품목 상세 닫기').click()
  await navigate(s, false, 'sales', '영업출고 조회')
  await s.getByLabel('영업출고 일자').fill(day)
  await s.getByLabel('출고 방식').selectOption('직납')
  const movement = s.locator('.movement-row')
  await movement.getByText(item.name).waitFor()
  assert.match(await movement.textContent(), /2개/)
  await movement.click()
  await s
    .getByRole('dialog')
    .getByRole('button', { name: '거래 근거·버전' })
    .click()
  assert.equal(
    await s.getByRole('button', { name: '원본 파일 보기' }).count(),
    0,
  )
  await navigate(a, true, 'stock', '재고 조회')
  const selected = a.getByRole('button', { name: new RegExp(item.name) })
  await selected.click()
  let itemSheet = a.getByRole('dialog')
  await itemSheet.getByRole('button', { name: '출고', exact: true }).click()
  await itemSheet
    .locator('.editor')
    .getByLabel('수불 유형')
    .selectOption('production_out')
  await itemSheet.getByLabel('대상 날짜').fill(day)
  await itemSheet.getByLabel('출고할 수량').fill('1')
  await itemSheet.getByRole('button', { name: '일일 마감 후보 등록' }).click()
  await itemSheet.getByText(/검토 후보를 등록했습니다/).waitFor()
  assert.equal((await rpc('wm_item', { p_item: item.id })).qty, 7)
  await itemSheet.getByRole('button', { name: '실사 수량 수정' }).click()
  await itemSheet.getByLabel(/직접 센 최종 수량/).fill('5')
  await itemSheet.getByRole('button', { name: '실사 수량 저장' }).click()
  await itemSheet.getByText(/실사 조정 기록을 저장했습니다/).waitFor()
  assert.equal((await rpc('wm_item', { p_item: item.id })).qty, 5)
  await fits(a)
  const attach = async (t, bytes) => {
    const r = await fetch(origin + '/api/evidence', {
      method: 'POST',
      headers: headers(t),
      body: JSON.stringify({ content: bytes.toString('base64') }),
    })
    return { status: r.status, data: await r.json() }
  }
  const fileBytes = Buffer.concat([
    Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ppSIAAAAASUVORK5CYII=',
      'base64',
    ),
    Buffer.from(key),
  ])
  assert.equal((await attach(employee, fileBytes)).status, 403)
  const upload = await attach(ops, fileBytes)
  assert.equal(upload.status, 200, JSON.stringify(upload.data))
  assert.deepEqual((await attach(ops, fileBytes)).data, upload.data)
  assert.equal(
    upload.data.sha256,
    createHash('sha256').update(fileBytes).digest('hex'),
  )
  await rpc('wm2_attach_file', {
    p_doc: first.data.document,
    p_sha: upload.data.sha256,
    p_name: 'fixture.png',
  })
  const reused = await send({
    ...doc,
    document_id: 'scan-' + key,
    source: { sha256: upload.data.sha256 },
  })
  assert.equal(reused.data.duplicate, true)
  const fileUrl = origin + '/api/evidence?document=' + first.data.document
  assert.equal(
    (await fetch(fileUrl, { headers: headers(employee) })).status,
    403,
  )
  const signed = await fetch(fileUrl, { headers: headers(ops) })
  assert.equal(signed.status, 200)
  const link = (await signed.json()).url
  assert.ok(link.startsWith(sb + '/storage/v1/'))
  assert.deepEqual(
    Buffer.from(await (await fetch(link)).arrayBuffer()),
    fileBytes,
  )
  if (process.env.WM_QA_ANALYSIS_PNG_DIR) {
    const detailClose = a.getByLabel('품목 상세 닫기')
    if (await detailClose.isVisible()) await detailClose.click()
    let analysisDay
    for (let i = 0; i < 365; i++) {
      const candidate = new Date(Date.UTC(2044, 10, 20 + i))
          .toISOString()
          .slice(0, 10),
        data = await rpc('wm2_day', { p_day: candidate })
      if (!data.rows.length && !data.issues.length) {
        analysisDay = candidate
        break
      }
    }
    assert.ok(analysisDay)
    await verifyAnalysisMobile({
      page: a,
      rpc,
      navigate,
      fits,
      day: analysisDay,
      output: process.env.WM_QA_ANALYSIS_PNG_DIR,
    })
  }
  assert.deepEqual(exceptions, [])
  console.log(
    'PASS · PIN roles, 320px/1280px, versioned intake, picking, grouped review edits, close 10→7, confirmed logs/sales, manual pending, immediate count 7→5, private file bytes, duplicate image and administrator-only access.',
  )
} finally {
  await browser?.close()
  await new Promise((r) => server.close(r))
  await rm(dist, { recursive: true, force: true })
}
