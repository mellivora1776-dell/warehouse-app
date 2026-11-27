import { useState } from 'react'
import { rpc } from '../db'
import { type Row, qty, rowLabel, standardName, stockCount } from './model'
import { ErrorText, Sheet, useTask } from './shared'

export function OpeningBalance({
  rows,
  stamp,
  admin,
  close,
  saved,
  hold,
}: {
  rows: Row[]
  stamp: string
  admin: boolean
  close: () => void
  saved: () => void
  hold: (row: Row) => void
}) {
  const row = rows[0]
  const [expectedStamp] = useState(stamp)
  const [value, setValue] = useState(String(row.opening_balance ?? ''))
  const task = useTask(() => {
    saved()
    close()
  })
  const label = row.opening_question || '첫 거래 전 재고 수량 확인'
  return (
    <Sheet title={label} close={close}>
      <h2>{standardName(row)}</h2>
      <div className="record-history">
        {rows.map((r) => (
          <p key={r.id}>
            {rowLabel(r)} · {r.direction > 0 ? '입고' : '출고'}{' '}
            {qty(stockCount(r))}
            {admin && (
              <button
                className="record-action opening-hold"
                onClick={() => hold(r)}
              >
                이 거래 보류
              </button>
            )}
          </p>
        ))}
      </div>
      <form
        className="work-form"
        onSubmit={(e) => {
          e.preventDefault()
          void task.run(async () => {
            await rpc('wm5_set_opening', {
              p_line: row.id,
              p_stamp: expectedStamp,
              p_qty: Number(value),
            })
            saved()
            close()
          })
        }}
      >
        <label>
          {row.work_day} 첫 창고 거래 직전 보유량
          <input
            type="number"
            inputMode="numeric"
            min="0"
            max="2147483647"
            step="1"
            required
            disabled={!admin}
            value={value}
            onChange={(e) => setValue(e.target.value)}
          />
        </label>
        <p className="help">
          그날 입출고가 시작되기 전, 이 주문 사양으로 보유한 수량을 입력하세요.
          첫 입고 전 재고가 없었다면 0입니다. 일일 마감 승인 때 입출고와 함께
          반영됩니다.
        </p>
        <ErrorText text={task.error} />
        {admin && (
          <button
            className="primary"
            disabled={task.busy || value.trim() === ''}
          >
            마감에 사용할 수량 저장
          </button>
        )}
      </form>
    </Sheet>
  )
}
