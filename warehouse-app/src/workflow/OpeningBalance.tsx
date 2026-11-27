import { type Row, qty, rowLabel, standardName, stockCount } from './model'

export function OpeningBalance({ row }: { row: Row }) {
  return (
    <div className="compare-line">
      <b>{standardName(row)}</b>
      <span>
        {rowLabel(row)} · {row.direction > 0 ? '입고' : '출고'}{' '}
        {qty(stockCount(row))}
      </span>
      <small>채팅 확인 대기 · {row.opening_question}</small>
    </div>
  )
}
