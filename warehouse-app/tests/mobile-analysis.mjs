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
    page.waitForResponse(
      (r) => r.url().includes('/rpc/wm2_pick') && r.ok(),
    ),
    outside.getByRole('checkbox').check(),
  ])
  assert.ok(
    (await rpc('wm2_day', { p_day: day })).rows.some(
      (r) => r.resolution === 'pick_only' && r.picked && !r.entry_id,
    ),
  )
  await navigate(page, true, 'daily', '일일 마감')
  await page.getByLabel('대상 날짜').fill(day)
  const card = page
    .locator('.close-item')
    .filter({ has: page.getByText('KJB3-2600', { exact: true }) })
  await card.locator('.close-numbers b').last().waitFor()
  assert.deepEqual(await card.locator('.close-numbers b').allTextContents(), [
    '0',
    '+3',
    '−2',
    '1',
  ])
  assert.equal(await card.evaluate((e) => e.open), false)
  await fits(page)
  await page.getByRole('heading', { name: '일일 마감', exact: true }).click()
  await page.screenshot({ path: join(output, 'after-daily.png') })
  await card.locator('summary').click()
  await card.getByText('현대FAN · 방문', { exact: true }).waitFor()
  await card.getByText('대신화물 · 화물', { exact: true }).waitFor()
  assert.equal((await lookup('KJB3-2600')).qty, 0)
  console.log(
    'PASS · mobile rack total 16, independent picks 9/7, external motor pick, 0+3−2=1 forecast, read-only inventory, screenshots',
  )
}
