import { useState } from 'react'
import { rpc } from '../db'
import {
  qty,
  timeKo,
  methods,
  standardName,
  type Movement,
  type Row,
} from './model'
import {
  Sheet,
  ErrorText,
  useTask,
  useData,
  doneRequest,
  requestId,
  Loading,
} from './shared'

export type RecordTarget = {
  entry: number | null
  line: string | null
  name: string
  category: string
  rev: number
  quantity: number | null
  original: number | null
  customer: string
  method: string
}
export function movementTarget(m: Movement): RecordTarget {
  return {
    entry: m.id,
    line: null,
    name: m.display_name || m.name,
    category: m.category,
    rev: m.record_rev,
    quantity: m.record_qty,
    original: ['count', 'opening'].includes(m.kind) ? m.after_qty : m.amount,
    customer: m.record_customer || '',
    method: m.record_method_raw || m.record_method || '',
  }
}
export function dayTarget(r: Row): RecordTarget {
  return {
    entry: r.entry_id,
    line: r.entry_id ? null : r.id,
    name: standardName(r),
    category: r.category,
    rev: r.record_rev ?? 0,
    quantity: r.record_qty ?? null,
    original:
      r.stock_managed === false ? r.final_qty : (r.stock_qty ?? r.final_qty),
    customer: r.record_customer ?? r.customer,
    method: r.record_method_raw ?? r.method ?? '',
  }
}
export function AmendmentHistory({ target }: { target: RecordTarget }) {
  const history = useData<
    {
      revision: number
      qty: number | null
      reason: string
      actor: string
      at: string
      customer: string
      method: string | null
    }[]
  >(
    'wm4_amendments',
    { p_entry: target.entry, p_line: target.line },
    target.rev,
  )
  return (
    <section className="record-history">
      <b>원승인 수량 {qty(target.original)}</b>
      {history.data ? (
        history.data.map((h) => (
          <p key={h.revision}>
            {h.qty == null ? '기록 삭제' : '기록 수량 ' + qty(h.qty)}
            {h.customer && ' · ' + h.customer}
            {h.method && ' · ' + h.method}
            <small>
              {h.reason} · {h.actor} · {timeKo(h.at)}
            </small>
          </p>
        ))
      ) : (
        <Loading error={history.error} retry={history.reload} />
      )}
    </section>
  )
}
export function RecordEdit({
  target,
  deleting: initialDelete = false,
  close,
  saved,
}: {
  target: RecordTarget
  deleting?: boolean
  close: () => void
  saved: () => void
}) {
  const [deleting, setDeleting] = useState(initialDelete)
  const [amount, setAmount] = useState(
      String(target.quantity ?? target.original ?? ''),
    ),
    [customer, setCustomer] = useState(target.customer),
    [method, setMethod] = useState(target.method),
    [reason, setReason] = useState('')
  const task = useTask(() => {
    saved()
    close()
  })
  return (
    <Sheet title={deleting ? '확정 기록 삭제' : '확정 기록 수정'} close={close}>
      <h2>{target.name}</h2>
      <p className="callout">
        원승인과 현재고를 유지합니다. 실제 수량 조정은 품목 상세의 실사에서
        처리하세요.
      </p>
      <form
        className="work-form"
        onSubmit={(e) => {
          e.preventDefault()
          void task.run(async () => {
            const payload = {
              p_entry: target.entry,
              p_line: target.line,
              p_rev: target.rev,
              p_qty: deleting ? null : Number(amount),
              p_customer: customer,
              p_method: method || null,
              p_reason: reason.trim(),
            }
            const key = 'record:' + (target.entry ?? target.line)
            await rpc('wm4_amend', {
              ...payload,
              p_request: requestId(key, payload),
            })
            doneRequest(key)
            saved()
            close()
          })
        }}
      >
        {!deleting && (
          <>
            <label>
              {target.category === 'count'
                ? '기록에 표시할 실사 수량'
                : '기록에 표시할 수량'}
              <input
                type="number"
                inputMode="numeric"
                required
                step="1"
                min={target.category === 'count' ? 0 : 1}
                max="2147483647"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
              />
            </label>
            {target.category === 'sale' && (
              <div className="form-pair">
                <label>
                  거래처
                  <input
                    required
                    maxLength={250}
                    value={customer}
                    onChange={(e) => setCustomer(e.target.value)}
                  />
                </label>
                <label>
                  출고 방식
                  <select
                    required
                    value={method}
                    onChange={(e) => setMethod(e.target.value)}
                  >
                    {Array.from(
                      new Set([...methods, method].filter(Boolean)),
                    ).map((m) => (
                      <option key={m}>{m}</option>
                    ))}
                  </select>
                </label>
              </div>
            )}
          </>
        )}
        <label>
          {deleting ? '삭제 사유' : '수정 사유'}
          <input
            required
            maxLength={1500}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </label>
        <ErrorText text={task.error} />
        <button className="primary" disabled={task.busy || !reason.trim()}>
          {deleting ? '기록 삭제 확정' : '기록 수정 저장'}
        </button>
      </form>
      {!initialDelete && target.quantity != null && (
        <button className="textbtn" onClick={() => setDeleting((v) => !v)}>
          {deleting ? '수정으로 돌아가기' : '이 기록 삭제'}
        </button>
      )}
      <AmendmentHistory target={target} />
    </Sheet>
  )
}
export function Disposition({
  row,
  hold = false,
  saved,
  close,
}: {
  row: Row
  hold?: boolean
  saved: () => void
  close: () => void
}) {
  const [why, setWhy] = useState('')
  const task = useTask(() => {
    saved()
    close()
  })
  const verb = hold ? '보류' : '삭제'
  return (
    <Sheet title={'마감 전 거래 ' + verb} close={close}>
      <h2>{standardName(row)}</h2>
      <p className="help">
        {row.work_day} · {qty(row.final_qty)} ·{' '}
        {hold
          ? '다음에 이어서 처리할 수 있습니다.'
          : '이 지시를 피킹과 마감 대상에서 제외합니다.'}
      </p>
      <form
        className="work-form"
        onSubmit={(e) => {
          e.preventDefault()
          void task.run(async () => {
            await rpc('wm4_dispose', {
              p_line: row.id,
              p_rev: row.rev,
              p_decision: hold ? 'hold' : 'exclude',
              p_reason: why.trim(),
            })
            saved()
            close()
          })
        }}
      >
        <label>
          {verb} 사유
          <input
            required
            maxLength={1500}
            value={why}
            onChange={(e) => setWhy(e.target.value)}
          />
        </label>
        <ErrorText text={task.error} />
        <button className="primary" disabled={task.busy || !why.trim()}>
          {verb} 확정
        </button>
      </form>
    </Sheet>
  )
}
