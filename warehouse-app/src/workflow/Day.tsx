import { useState } from 'react'
import { ChevronRight, AlertCircle } from 'lucide-react'
import { rpc } from '../db'
import { Empty, Refresh } from '../ui'
import {
  DayField,
  Sheet,
  Loading,
  ErrorText,
  useTask,
  useData,
  requestId,
  doneRequest,
} from './shared'
import {
  categoryLabels,
  decisions,
  attention,
  completed,
  pickCount,
  stockCount,
  standardName,
  planned,
  grouped,
  rowLabel,
  qty,
  timeKo,
  type DayData,
  type Row,
  type Issue,
  type Batch,
} from './model'
import { Evidence } from './Evidence'
import { RecordEdit, dayTarget, Disposition } from './RecordEdit'
import { Review } from './Review'

type Props = { day: string; setDay: (d: string) => void; admin: boolean }
export function BatchDetails({ id, close }: { id: string; close: () => void }) {
  const result = useData<{
    work_day: string
    sequence: number
    actor: string
    approved_at: string
    reviewed: DayData
  }>('wm2_batch', { p_id: id })
  const d = result.data
  return (
    <Sheet title="마감 당시 검토표" close={close}>
      {d ? (
        <>
          <h2>
            {d.work_day} · {d.sequence}차
          </h2>
          <p className="small-meta">
            {d.actor} · {timeKo(d.approved_at)}
          </p>
          {grouped(d.reviewed.rows).map((g) => {
            const p = planned(
              g.filter(
                (r) =>
                  r.decision === 'ready' ||
                  (r.decision === 'pending' && r.check_reason === ''),
              ),
            )
            return (
              <div className="projection" key={g[0].id}>
                <b>{standardName(g[0])}</b>
                <span>
                  승인 당시 {qty(g[0].qty)} → 승인 후{' '}
                  {qty(g[0].qty == null ? null : g[0].qty + p.net)}
                </span>
              </div>
            )
          })}
          {d.reviewed.rows.map((r) => (
            <div className="compare-line" key={r.id}>
              <b>{standardName(r)}</b>
              <div>
                {rowLabel(r)} · {qty(r.final_qty)} ·{' '}
                {completed(r)
                  ? '이전 차수 확정'
                  : r.related_hold
                    ? '보류'
                    : r.decision === 'pending' && r.check_reason === ''
                      ? '승인'
                      : decisions[r.decision]}
              </div>
              {r.reason && <small>{r.reason}</small>}
            </div>
          ))}
          {d.reviewed.issues.map((i) => (
            <p key={i.id}>
              {i.external_id} · {i.issue}
            </p>
          ))}
        </>
      ) : (
        <Loading error={result.error} retry={result.reload} />
      )}
    </Sheet>
  )
}
export function Daily({ day, setDay, admin }: Props) {
  const result = useData<DayData>('wm2_day', { p_day: day })
  const d = result.data
  const [cat, setCat] = useState(''),
    [edit, setEdit] = useState<Row | null>(null),
    [record, setRecord] = useState<Row | null>(null),
    [hold, setHold] = useState<Row | null>(null),
    [source, setSource] = useState<{ id: string; issue?: Issue } | null>(null),
    [batch, setBatch] = useState(''),
    [success, setSuccess] = useState('')
  const task = useTask(result.reload)
  const rows = d?.rows ?? [],
    issues = d?.issues ?? []
  const waiting = rows.filter(
    (r) =>
      !completed(r) &&
      !['hold', 'exclude'].includes(r.decision) &&
      !r.related_hold,
  )
  const held = rows.filter(
    (r) =>
      !completed(r) &&
      r.decision !== 'exclude' &&
      (r.decision === 'hold' || r.related_hold),
  )
  const problems = new Map<string, string>()
  waiting.forEach((r) => {
    const msg = attention(r)
    if (msg) problems.set(r.id, msg)
  })
  for (const g of grouped(waiting.filter((r) => !problems.has(r.id)))) {
    const plan = planned(g),
      current = g[0].qty
    if (current != null && current + plan.net < 0)
      for (const r of g.filter((r) => r.direction < 0))
        problems.set(
          r.id,
          '현재 ' +
            qty(current) +
            ' · 마감에 ' +
            qty(-current - plan.net) +
            ' 부족합니다.',
        )
  }
  const unresolved = issues.filter((i) => !i.deferred)
  const groups = grouped(
    rows.filter(
      (r) =>
        r.decision !== 'exclude' &&
        !held.includes(r) &&
        !problems.has(r.id) &&
        (!cat || r.category === cat),
    ),
  )
  const count = waiting.filter((r) => !problems.has(r.id)).length
  const blocked = !!unresolved.length || !!problems.size
  const scope = 'close:' + day
  function openRow(r: Row) {
    if (!admin) setSource({ id: r.document_id })
    else if (completed(r)) setRecord(r)
    else setEdit(r)
  }
  async function approve() {
    if (!d || blocked || !count) return
    await task.run(async () => {
      const b = await rpc<{ sequence: number }>('wm2_close', {
        p_day: day,
        p_stamp: d.stamp,
        p_request: requestId(scope, d.stamp),
      })
      doneRequest(scope)
      setSuccess(day + ' ' + b.sequence + '차 마감을 저장했습니다.')
      result.reload()
    })
  }
  function amount(r: Row) {
    if (r.record_deleted) return '기록 삭제'
    if (r.stock_managed === false)
      return (
        (r.pick_required
          ? completed(r) && r.record_rev
            ? '기록 ' + qty(r.record_qty)
            : '준비 ' + qty(pickCount(r))
          : '보고 ' + qty(r.record_qty ?? r.final_qty)) + ' · 재고 0개'
      )
    const n = completed(r) ? r.record_qty : stockCount(r)
    return n == null ? '수량 확인 필요' : (r.direction > 0 ? '+' : '−') + qty(n)
  }
  function label(r: Row) {
    if (r.category !== 'sale') return categoryLabels[r.category]
    const customer = completed(r)
      ? (r.record_customer ?? r.customer)
      : r.customer
    const method = completed(r)
      ? (r.record_method_raw ?? r.method_raw)
      : r.method_raw
    return (
      '영업출고 · ' +
      rowLabel({
        ...r,
        customer,
        method: method || r.method,
        method_raw: method,
      })
    )
  }
  return (
    <>
      <div className="title-row">
        <h1>일일 마감</h1>
        <Refresh onClick={result.reload} />
      </div>
      <div className="work-toolbar">
        <DayField
          day={day}
          setDay={(v) => {
            setDay(v)
            setSuccess('')
          }}
        />
        <label>
          수불 유형
          <select value={cat} onChange={(e) => setCat(e.target.value)}>
            <option value="">전체 유형</option>
            {(
              [
                'production_in',
                'production_out',
                'sale',
                'return',
                'as',
              ] as const
            ).map((k) => (
              <option key={k} value={k}>
                {categoryLabels[k]}
              </option>
            ))}
          </select>
        </label>
      </div>
      <ErrorText text={task.error} />
      {success && (
        <p className="callout" role="status">
          {success}
        </p>
      )}
      {!d ? (
        <Loading error={result.error} retry={result.reload} />
      ) : (
        <>
          {blocked && (
            <section className="attention-list">
              <h3>
                <AlertCircle size={16} />
                확인 필요
              </h3>
              {unresolved.map((i) => (
                <button
                  key={i.id}
                  className="issue-row"
                  onClick={() => setSource({ id: i.id, issue: i })}
                >
                  <span>
                    <b>{i.customer || '문서 관계'}</b>
                    <small>
                      {i.issue ||
                        '이 지시가 어느 출고 건에 속하는지 확인하세요.'}
                    </small>
                  </span>
                  <ChevronRight size={16} />
                </button>
              ))}
              {waiting
                .filter((r) => problems.has(r.id))
                .map((r) => (
                  <div className="problem-row" key={r.id}>
                    <button className="issue-row" onClick={() => openRow(r)}>
                      <span>
                        <b>{standardName(r)}</b>
                        <small>{problems.get(r.id)}</small>
                      </span>
                      <ChevronRight size={16} />
                    </button>
                    {admin && (
                      <button
                        className="record-action"
                        onClick={() => setHold(r)}
                      >
                        보류
                      </button>
                    )}
                  </div>
                ))}
            </section>
          )}
          {(held.length > 0 || issues.some((i) => i.deferred)) && (
            <details className="expand held-list">
              <summary>
                보류 {held.length + issues.filter((i) => i.deferred).length}건
              </summary>
              {held.map((r) => (
                <button
                  className="issue-row"
                  key={r.id}
                  onClick={() => openRow(r)}
                >
                  {standardName(r)} · {r.reason || '관련 문서 보류'}
                </button>
              ))}
              {issues
                .filter((i) => i.deferred)
                .map((i) => (
                  <button
                    className="issue-row"
                    key={i.id}
                    onClick={() => setSource({ id: i.id, issue: i })}
                  >
                    {i.customer || '문서 관계'} · {i.issue}
                  </button>
                ))}
            </details>
          )}
          <div className="day-list">
            {groups.map((g) => (
              <article className="day-item" key={g[0].id}>
                <h3>{standardName(g[0])}</h3>
                {g.map((r) => (
                  <div className="day-trade" key={r.id}>
                    <span>
                      {label(r)}
                      {completed(r) && (
                        <small>
                          {' '}
                          · {r.record_rev ? '기록 변경' : '승인됨'}
                        </small>
                      )}
                    </span>
                    <b>{amount(r)}</b>
                    <button
                      className="record-action"
                      onClick={() => openRow(r)}
                      aria-label={
                        standardName(r) +
                        ' ' +
                        label(r) +
                        ' ' +
                        (admin ? '수정' : '상세')
                      }
                    >
                      {admin ? '수정' : '상세'}
                    </button>
                  </div>
                ))}
              </article>
            ))}
          </div>
          {!groups.length && !blocked && !held.length && (
            <Empty
              title={
                cat ? '선택한 유형의 거래가 없습니다' : '표시할 거래가 없습니다'
              }
            />
          )}
          {admin && waiting.length > 0 && (
            <div className="day-approve">
              {cat && (
                <p className="help">
                  승인은 선택한 날짜의 모든 수불 유형에 적용됩니다.
                </p>
              )}
              <button
                className="primary"
                disabled={task.busy || blocked || !count}
                onClick={() => void approve()}
              >
                {day} 일일 마감 승인 · {count}건
              </button>
            </div>
          )}
          {!!d.batches.length && (
            <details className="expand">
              <summary>확정된 마감 {d.batches.length}회</summary>
              {d.batches.map((b) => (
                <button
                  key={b.id}
                  className="issue-row"
                  onClick={() => setBatch(b.id)}
                >
                  {b.sequence}차 · {timeKo(b.approved_at)}
                </button>
              ))}
            </details>
          )}
        </>
      )}
      {edit && (
        <Review
          row={edit}
          all={rows}
          close={() => setEdit(null)}
          saved={result.reload}
        />
      )}
      {hold && (
        <Disposition
          row={hold}
          hold
          close={() => setHold(null)}
          saved={result.reload}
        />
      )}
      {record && (
        <RecordEdit
          target={dayTarget(record)}
          close={() => setRecord(null)}
          saved={result.reload}
        />
      )}
      {source && (
        <Evidence
          id={source.id}
          issue={source.issue}
          admin={admin}
          saved={result.reload}
          close={() => setSource(null)}
        />
      )}
      {batch && <BatchDetails id={batch} close={() => setBatch('')} />}
    </>
  )
}
export { Picking } from './Picking'
