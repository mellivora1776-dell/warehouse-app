import test from 'node:test'
import assert from 'node:assert/strict'
import { preview } from '../src/calc.mjs'
test('입고·출고·실사 미리보기', () => {
  assert.equal(preview(10, 'in', '3').after, 13)
  assert.equal(preview(10, 'out', '3').after, 7)
  assert.equal(preview(7, 'count', '5').after, 5)
  assert.equal(preview(null, 'count', '0').after, 0)
  for (const kind of ['in', 'out']) assert.ok(preview(null, kind, '3').error)
  assert.match(preview(2, 'out', '4').error, /2대 부족/)
  for (const n of ['0', '1.5', '-1', '1e3'])
    assert.ok(preview(10, 'in', n).error)
  assert.ok(preview(2147483647, 'in', '1').error)
})
