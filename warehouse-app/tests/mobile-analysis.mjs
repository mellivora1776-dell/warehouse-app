import assert from 'node:assert/strict'
import { mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

// Invoked by the loopback-only QA browser runner with a dedicated fixture date.
export async function verifyAnalysisMobile({
  page,
  rpc,
  navigate,
  fits,
  day,
  output,
}) {
  const prefix = 'mobile-analysis/' + randomUUID(),
    lookup = async (name) =>
      (await rpc('wm_items', { p_query: name })).rows.find(
        (r) => r.name === name,
      )
  const motor = await lookup('KJ3AB-750 모터'),
    fan = await lookup('KJB3-2600')
  assert.ok(
    motor &&
      (await rpc('wm_item', { p_item: motor.id })).racks.includes('2F-D-11') &&
      fan?.qty === 0,
    'The analysis fixture needs the referenced motor rack and zero fan stock.',
  )
  const lines = [
    ['9', 'production_out', '3-1', 9, '유환열'],
    ['7', 'production_out', 'A3-750-M', 7, '최병호'],
    ['3', 'sale', 'KTB-032T 모터', 3, '송전사'],
    ['in', 'production_in', 'KJB3-2600', 3, ''],
    ['f', 'sale', 'KJB3-2600', 1, '대신화물'],
    ['visit', 'sale', 'KJB3-2600', 1, '현대FAN'],
  ]
  for (const [key, category, raw_name, qty, person] of lines) {
    const isSale = category === 'sale',
      id = prefix + '/' + key
    const line = {
      line_id: '1',
      raw_name,
      qty,
      ...(category === 'production_out'
        ? {
            item_id: motor.id,
            context: 'blower_motor',
            requester: person,
            match_basis: '시험 현장 확인',
          }
        : {}),
      ...(isSale
        ? { customer: person, method: key === 'visit' ? '방문' : '화물' }
        : {}),
    }
    const doc = {
      schema_version: 2,
      case_id: id,
      document_id: id + '/v1',
      version: 1,
      category,
      document_type: '격리 검증',
      work_date: day,
      lines: [line],
    }
    const plan = await rpc('wm3_preview', { p_doc: doc })
    assert.ok(plan.can_submit)
    const send = () =>
      rpc('wm2_import', { p_doc: { ...doc, preview_stamp: plan.stamp } })
    assert.deepEqual((await send()).stored_lines, plan.lines)
    assert.ok((await send()).duplicate)
  }
  const orderName = 'KJ3AB-750(440/60) [주문품]'
  for (const [key, category] of [
    ['finished-in', 'production_in'],
    ['finished-sale', 'sale'],
  ]) {
    const id = prefix + '/' + key
    const sale = category === 'sale'
    const doc = {
      schema_version: 2,
      case_id: id,
      document_id: id + '/v1',
      version: 1,
      category,
      document_type: '격리 주문품 시험',
      work_date: day,
      lines: [
        {
          line_id: '1',
          raw_name: 'KJ3AB-750 440/60',
          qty: 25,
          standard_name: 'KJ3AB-750 완성품',
          standard_spec: '440V·60Hz',
          variant: 'order',
          product_kind: 'finished',
          match_basis: '시험 문서에서 주문 완성품 확인',
          ...(sale ? { customer: '태성FAN', method: '퀵(용차 배송)' } : {}),
        },
      ],
    }
    const check = await rpc('wm3_preview', { p_doc: doc })
    assert.ok(check.can_submit)
    await rpc('wm2_import', { p_doc: { ...doc, preview_stamp: check.stamp } })
    const row = (await rpc('wm2_day', { p_day: day })).rows.find(
      (r) => r.external_id === doc.document_id,
    )
    if (!row.item_id) {
      assert.equal(row.resolution, 'order_candidate')
      await rpc('wm2_new_sku', {
        p_line: row.id,
        p_rev: row.rev,
        p_sku: 'QA-440-60-FINISHED',
        p_name: 'KJ3AB-750 완성품',
        p_spec: '440V·60Hz',
        p_racks: [],
        p_ordered: true,
        p_first_receipt: true,
      })
    }
  }
  await page.setViewportSize({ width: 390, height: 844 })
  await navigate(page, true, 'picking', '피킹리스트')
  await page.getByLabel('출고 날짜').fill(day)
  const group = page
    .locator('.pick-item')
    .filter({ has: page.getByText('KJ3AB-750 모터', { exact: true }) })
  await group.getByText('총 16개', { exact: true }).waitFor()
  await group.getByText('9개', { exact: true }).waitFor()
  await group.getByText('7개', { exact: true }).waitFor()
  assert.equal(await group.getByRole('checkbox').count(), 2)
  const outside = page
    .locator('.pick-item')
    .filter({ hasText: 'KTB-032T 모터' })
  await outside.getByText('피킹 전용 · 재고 차감 없음').waitFor()
  assert.ok(await outside.getByRole('checkbox').isEnabled())
  await fits(page)
  await mkdir(output, { recursive: true })
  await page.getByRole('heading', { name: '피킹리스트', exact: true }).click()
  await page.screenshot({ path: join(output, 'after-picking.png') })
  await Promise.all([
    page.waitForResponse((r) => r.url().includes('/rpc/wm2_pick') && r.ok()),
    outside.getByRole('checkbox').check(),
  ])
  assert.ok(
    (await rpc('wm2_day', { p_day: day })).rows.some(
      (r) => r.resolution === 'pick_only' && r.picked && !r.entry_id,
    ),
  )
  await navigate(page, true, 'daily', '일일 마감')
  await page.getByLabel('대상 날짜').fill(day)
  const card = page.locator('.day-item').filter({
    has: page.getByRole('heading', { name: 'KJB3-2600', exact: true }),
  })
  await card.getByText('영업출고 · 현대FAN · 방문', { exact: true }).waitFor()
  await card.getByText('영업출고 · 대신화물 · 화물', { exact: true }).waitFor()
  assert.deepEqual(
    (await card.locator('.day-trade>b').allTextContents()).sort(),
    ['+3개', '−1개', '−1개'].sort(),
  )
  assert.equal(await page.getByText('예상 마감', { exact: true }).count(), 0)
  assert.equal(await page.getByText(/유환열|최병호/).count(), 0)
  await fits(page)
  await page.getByRole('heading', { name: '일일 마감', exact: true }).click()
  const ordered = page.locator('.day-item').filter({
    has: page.getByRole('heading', { name: orderName, exact: true }),
  })
  await ordered
    .getByText('영업출고 · 태성FAN · 퀵(용차 배송)', { exact: true })
    .waitFor()
  assert.deepEqual(
    (await ordered.locator('.day-trade>b').allTextContents()).sort(),
    ['+25개', '−25개'].sort(),
  )
  await page.screenshot({
    path: join(output, 'after-daily.png'),
    fullPage: true,
  })
  assert.equal((await lookup('KJB3-2600')).qty, 0)
  console.log(
    'PASS · mobile rack total 16, independent picks 9/7, external motor pick, individual +3/−1/−1 trades, finished order +25/−25, read-only inventory, screenshots',
  )
}

// Run through the administrator's normal screens with a separate loopback-only fixture day.
export async function verifyConfirmedOrder({ page, rpc, navigate, fits }) {
  let day
  for (let i = 1; i <= 730; i++) {
    const d = new Date(Date.UTC(2057, 0, i)).toISOString().slice(0, 10)
    const state = await rpc('wm2_day', { p_day: d })
    if (!state.rows.length && !state.issues.length) {
      day = d
      break
    }
  }
  assert.ok(day)
  const key = randomUUID(),
    model = 'QA-주문-' + key.slice(0, 8)
  const doc = {
    schema_version: 2,
    case_id: key,
    document_id: key + '/v1',
    version: 1,
    work_date: day,
    category: 'sale',
    customer: '시험 거래처',
    document_type: '직납출고지시서',
    lines: [
      {
        line_id: '1',
        raw_name: model,
        spec: '220/380/50',
        qty: 9,
        standard_name: model,
        standard_spec: '220/380V·50Hz',
        variant: 'order',
        product_kind: 'finished',
        order_confirmed: true,
        match_basis: '시험 주문서 및 사용자 확인',
      },
    ],
  }
  await navigate(page, true, 'intake', '분석 자료 등록')
  await page.getByLabel('분석 결과 JSON').fill(JSON.stringify(doc))
  await page.getByRole('button', { name: '등록 전 사전 검증' }).click()
  await page.getByText(/확정 주문품 · 신규 SKU 생성 예정/).waitFor()
  assert.deepEqual(await rpc('wm4_catalog', { p_query: model }), [])
  await page.getByRole('button', { name: '검토 자료 등록' }).click()
  await page.getByText(/검토 자료를 등록했습니다/).waitFor()
  const [r] = (await rpc('wm2_day', { p_day: day })).rows
  assert.ok(r.item_id)
  assert.equal(r.check_reason, '출고 전 재고 수량 확인')
  await navigate(page, true, 'picking', '피킹리스트')
  await page.getByLabel('출고 날짜').fill(day)
  await page.getByText('출고 전 재고 수량 확인', { exact: true }).waitFor()
  assert.ok(await page.getByRole('checkbox').isEnabled())
  await navigate(page, true, 'daily', '일일 마감')
  await page.getByLabel('대상 날짜').fill(day)
  const question = page.getByRole('button', {
    name: /QA-주문-.*출고 전 재고 수량 확인/,
  })
  await question.click()
  const sheet = page.getByRole('dialog', { name: '출고 전 재고 수량 확인' })
  assert.equal(
    await sheet.getByRole('button', { name: /SKU|품목 찾기/ }).count(),
    0,
  )
  await sheet.getByLabel(/첫 창고 거래 직전 보유량/).fill('12')
  await fits(page)
  await sheet.getByRole('button', { name: '마감에 사용할 수량 저장' }).click()
  await sheet.waitFor({ state: 'hidden' })
  await page.getByRole('button', { name: /첫 거래 전 재고 12개/ }).waitFor()
  assert.equal((await rpc('wm_item', { p_item: r.item_id })).qty, null)
  await page.getByRole('button', { name: /일일 마감 승인/ }).click()
  await page.getByText(/1차 마감을 저장했습니다/).waitFor()
  assert.equal((await rpc('wm_item', { p_item: r.item_id })).qty, 3)
  assert.ok((await rpc('wm3_preview', { p_doc: doc })).already_closed)
  console.log(
    'PASS · confirmed order intake, dual-voltage label, one opening question, stock stays unknown until close 12→3.',
  )
}
