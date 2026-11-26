import { useState } from 'react'
import { rpc } from '../db'
import { categoryLabels, methods, today, type Category } from './model'
import { DayField, ErrorText, requestId, doneRequest, useTask } from './shared'

type Props = {
  item: { id: string; name: string }
  initialDay?: string
  flow: 'in' | 'out'
  onSaved: () => void
}
export function ManualForm({ item, initialDay, flow, onSaved }: Props) {
  const [cat, setCat] = useState<Category | ''>(''),
    [n, setN] = useState(''),
    [day, setDay] = useState(initialDay ?? today()),
    [customer, setCustomer] = useState(''),
    [method, setMethod] = useState(''),
    [note, setNote] = useState(''),
    [notice, setNotice] = useState('')
  const task = useTask()
  const sale = cat === 'sale'
  const choices: Category[] =
    flow === 'in'
      ? ['production_in', 'return', 'as']
      : ['sale', 'production_out', 'as']
  async function save(e: React.FormEvent) {
    e.preventDefault()
    await task.run(async () => {
      const payload = {
        p_item: item.id,
        p_day: day,
        p_category: cat,
        p_qty: Number(n),
        p_customer: customer,
        p_method: sale ? method || null : null,
        p_direction: flow,
        p_note: note,
      }
      const scope = 'manual:' + item.id + ':' + flow
      await rpc('wm2_manual', {
        ...payload,
        p_request: requestId(scope, payload),
      })
      doneRequest(scope)
      setN('')
      setNotice(day + ' 일일 마감에 검토 후보를 등록했습니다.')
      onSaved()
    })
  }
  return (
    <form onSubmit={save} className="work-form">
      <label>
        수불 유형
        <select
          required
          value={cat}
          onChange={(e) => setCat(e.target.value as Category)}
        >
          <option value="">선택</option>
          {choices.map((c) => (
            <option key={c} value={c}>
              {categoryLabels[c]}
            </option>
          ))}
        </select>
      </label>
      <div className="form-pair">
        <DayField day={day} setDay={setDay} />
      </div>
      {sale && (
        <div className="form-pair">
          <label>
            거래처
            <input
              maxLength={250}
              value={customer}
              onChange={(e) => setCustomer(e.target.value)}
            />
          </label>
          <label>
            출고 방식
            <select value={method} onChange={(e) => setMethod(e.target.value)}>
              <option value="">미확인</option>
              {methods.map((m) => (
                <option key={m}>{m}</option>
              ))}
            </select>
          </label>
        </div>
      )}
      <label>
        {flow === 'in' ? '입고할 수량' : '출고할 수량'}
        <input
          required
          type="number"
          inputMode="numeric"
          step="1"
          min="1"
          max="2147483647"
          value={n}
          onChange={(e) => setN(e.target.value)}
        />
      </label>
      <label>
        메모 · 선택
        <input
          maxLength={1000}
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      </label>
      <p className="help">실제 재고에는 일일 마감 승인 때 반영됩니다.</p>
      <ErrorText text={task.error} />
      {notice && (
        <p role="status" className="callout">
          {notice}
        </p>
      )}
      <button className="primary" disabled={task.busy}>
        {task.busy ? '등록 중…' : '일일 마감 후보 등록'}
      </button>
    </form>
  )
}
