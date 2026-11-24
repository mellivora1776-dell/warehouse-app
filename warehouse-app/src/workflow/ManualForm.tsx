import { useState } from 'react'
import { rpc } from '../db'
import {
  categoryLabels,
  methods,
  today,
  type Movement,
  type Category,
} from './model'
import { DayField, ErrorText, requestId, doneRequest, useTask } from './shared'

type Props = {
  item: { id: string; name: string }
  initialDay?: string
  flow: 'in' | 'out' | 'correction'
  original?: Movement
  related?: string
  onSaved: () => void
}
export function ManualForm({
  item,
  initialDay,
  flow,
  original,
  related,
  onSaved,
}: Props) {
  const [cat, setCat] = useState<Category | ''>(original?.category ?? ''),
    [direction, setDir] = useState(
      flow === 'in' ? 'in' : flow === 'out' ? 'out' : '',
    ),
    [n, setN] = useState(''),
    [day, setDay] = useState(initialDay ?? today()),
    [customer, setCustomer] = useState(original?.customer ?? ''),
    [method, setMethod] = useState(original?.method ?? ''),
    [note, setNote] = useState(''),
    [notice, setNotice] = useState('')
  const task = useTask()
  const correction = flow === 'correction',
    sale = cat === 'sale'
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
        p_direction: direction,
        p_note: note,
        p_corrects: original?.id ?? null,
        p_related: related ?? null,
      }
      const scope = 'manual:' + item.id + ':' + (original?.id ?? flow)
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
      {correction ? (
        <p className="callout">
          원승인 #{original?.id} · {item.name} · {original?.signed_qty}개
        </p>
      ) : (
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
      )}
      <div className="form-pair">
        <DayField day={day} setDay={setDay} />
        {correction ? (
          <label>
            정정 방향
            <select
              required
              value={direction}
              onChange={(e) => setDir(e.target.value)}
            >
              <option value="">선택</option>
              <option value="in">재고 증가</option>
              <option value="out">재고 감소</option>
            </select>
          </label>
        ) : null}
      </div>
      {sale && !correction && (
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
        {correction
          ? '바로잡을 차이 수량'
          : flow === 'in'
            ? '입고할 수량'
            : '출고할 수량'}
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
        {correction ? '정정 사유' : '메모 · 선택'}
        <input
          required={correction}
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
        {task.busy
          ? '등록 중…'
          : correction
            ? '정정 후보 등록'
            : '일일 마감 후보 등록'}
      </button>
    </form>
  )
}
