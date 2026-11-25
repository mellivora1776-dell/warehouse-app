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
            const p = planned(g.filter((r) => r.decision === 'ready'))
            return (
              <div className="projection" key={g[0].id}>
                <b>{g[0].name || g[0].raw_name}</b>
                <span>
                  승인 당시 {qty(g[0].qty)} → 승인 후{' '}
                  {qty(g[0].qty == null ? null : g[0].qty + p.net)}
                </span>
              </div>
            )
          })}
          {d.reviewed.rows.map((r) => (
            <div className="compare-line" key={r.id}>
              <b>{r.name || r.raw_name}</b>
              <div>
                {rowLabel(r)} · {qty(r.final_qty)} ·{' '}
                {r.entry_id ? '이전 차수 확정' : decisions[r.decision]}
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
  const task = useTask(() => {
    setConfirm(false)
    result.reload()
  })
  const [cat, setCat] = useState(''),
    [edit, setEdit] = useState<Row | null>(null),
    [source, setSource] = useState<{ id: string; issue?: Issue } | null>(null),
    [confirm, setConfirm] = useState(false),
    [batch, setBatch] = useState(''),
    [success, setSuccess] = useState('')
  const rows = d?.rows ?? [],
    issues = d?.issues ?? [],
    batches = d?.batches ?? [],
    ready = rows.filter((r) => !completed(r) && r.decision === 'ready')
  const pending = rows.filter(
      (r) => !completed(r) && r.decision === 'pending',
    ).length,
    openIssues = issues.filter((i) => !i.deferred).length
  const groups = grouped(rows)

  const blockers = groups.flatMap((g) => {
    const reasons: string[] = [...new Set(g.map(attention).filter(Boolean))]
    const forecast = planned(g),
      approving = planned(g.filter((r) => r.decision === 'ready'))
    if (
      g[0].stock_managed !== false &&
      g[0].qty != null &&
      g[0].qty + Math.min(forecast.net, approving.net) < 0
    )
      reasons.push('재고 부족')
    return reasons.length
      ? [{ row: g.find((r) => attention(r)) || g[0], reasons }]
      : []
  })
  const remaining =
    rows.some((r) => !completed(r) && r.decision !== 'exclude') || !!openIssues
  const blocked = !!pending || !!openIssues || !!blockers.length
  const scope = 'close:' + day
  async function approve() {
    if (!d) return
    await task.run(async () => {
      const b = await rpc<{ sequence: number }>('wm2_close', {
        p_day: day,
        p_stamp: d.stamp,
        p_request: requestId(scope, d.stamp),
      })
      doneRequest(scope)
      setConfirm(false)
      setSuccess(day + ' ' + b.sequence + '차 마감을 저장했습니다.')
      result.reload()
    })
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
          setDay={(date) => {
            setDay(date)
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
              <option value={k} key={k}>
                {categoryLabels[k]}
              </option>
            ))}
          </select>
        </label>
      </div>
      {!confirm && <ErrorText text={task.error} />}{' '}
      {success && (
        <p role="status" className="callout">
          {success}
        </p>
      )}
      {!d ? (
        <Loading error={result.error} retry={result.reload} />
      ) : (
        <>
          <div className="section-title">
            <h3>
              {batches.length
                ? remaining
                  ? '추가 검토'
                  : '마감 완료'
                : rows.length || issues.length
                  ? '검토 중'
                  : '등록 내역 없음'}
            </h3>
            <span>{pending > 0 ? '승인 전 거래 ' + pending + '건' : day}</span>
          </div>
          {(issues.length > 0 || blockers.length > 0) && (
            <section className="attention-list">
              <h3>
                <AlertCircle size={16} /> 확인 필요
              </h3>
              {issues.map((i) => (
                <button
                  className="issue-row"
                  key={i.id}
                  onClick={() => setSource({ id: i.id, issue: i })}
                >
                  <span>
                    <b>{i.customer || '문서 관계'}</b>
                    <small>
                      {i.deferred ? '보류 · ' : ''}
                      {i.issue}
                    </small>
                  </span>
                  <ChevronRight size={16} />
                </button>
              ))}
              {blockers.map(({ row, reasons }) => (
                <button
                  className="issue-row"
                  key={row.id}
                  onClick={() =>
                    admin ? setEdit(row) : setSource({ id: row.document_id })
                  }
                >
                  <span>
                    <b>{standardName(row)}</b>
                    <small>{reasons.join(' · ')}</small>
                  </span>
                  <ChevronRight size={16} />
                </button>
              ))}
            </section>
          )}
          <div className="close-list">
            {groups
              .filter((g) => !cat || g.some((r) => r.category === cat))
              .map((g) => {
                const r = g[0],
                  p = planned(g),
                  posted = g
                    .filter((x) => x.entry_id != null)
                    .sort((a, b) => a.entry_id! - b.entry_id!),
                  historical =
                    !!posted.length &&
                    g.every((x) => completed(x) || x.decision === 'exclude'),
                  base = historical ? posted[0].posted_before : r.qty,
                  next = historical
                    ? posted[posted.length - 1].posted_after
                    : r.qty == null
                      ? null
                      : r.qty + p.net,
                  spec = r.item_spec || r.standard_spec || r.spec
                if (historical) {
                  for (const x of posted) {
                    if (x.direction > 0) p.incoming += stockCount(x) ?? 0
                    else p.outgoing += stockCount(x) ?? 0
                  }
                }
                return (
                  <details className="close-item" key={r.item_id || r.id}>
                    <summary>
                      <div className="close-name">
                        <strong>{standardName(r)}</strong>
                        {r.variant === 'order' && <small>주문품</small>}
                        <ChevronRight size={16} />
                      </div>
                      {spec && spec !== standardName(r) && (
                        <div className="minor-spec">{spec}</div>
                      )}
                      {r.stock_managed === false ? (
                        <small className="nonstock">
                          {g.some((x) => x.pick_required)
                            ? '피킹 전용 · 준비 ' +
                              qty(
                                g.reduce((n, x) => n + (pickCount(x) ?? 0), 0),
                              ) +
                              ' · 재고 차감 없음'
                            : '입고 보고 · 재고 증가 없음'}
                        </small>
                      ) : (
                        <div className="close-numbers">
                          {[
                            ['기존', base ?? '미확인'],
                            ['입고', '+' + p.incoming],
                            ['출고', '−' + p.outgoing],
                            [
                              historical ? '확정 마감' : '예상 마감',
                              next ?? '미확인',
                            ],
                          ].map(([label, num]) => (
                            <span key={label}>
                              <small>{label}</small>
                              <b
                                className={
                                  label === '예상 마감' &&
                                  next != null &&
                                  next < 0
                                    ? 'negative'
                                    : ''
                                }
                              >
                                {num}
                              </b>
                            </span>
                          ))}
                        </div>
                      )}
                    </summary>
                    <div className="close-trades">
                      {g
                        .filter((x) => !cat || x.category === cat)
                        .map((x) => (
                          <div className="trade" key={x.id}>
                            <div className="trade-main">
                              <div>
                                <b>{rowLabel(x)}</b>
                                <small>
                                  {completed(x)
                                    ? '승인 완료'
                                    : decisions[x.decision]}
                                  {(x.edition ?? 0) > 1 ? ' · 수정본' : ''}{' '}
                                  {x.reason}
                                </small>
                              </div>
                              <strong>
                                {x.stock_managed === false
                                  ? '준비 ' + qty(pickCount(x))
                                  : (x.direction > 0 ? '+' : '−') +
                                    (stockCount(x) ?? '?') +
                                    '개'}
                              </strong>
                            </div>
                            <small className="small-meta">
                              원문 {x.raw_name} {x.spec} · {qty(x.read_qty)}
                              {x.packing ? ' · ' + x.packing : ''}
                              {x.remarks ? ' · ' + x.remarks : ''}
                            </small>
                            <div className="row-actions">
                              <button
                                className="textbtn"
                                onClick={() => setSource({ id: x.document_id })}
                              >
                                근거·버전
                              </button>
                              {admin &&
                                !completed(x) &&
                                x.decision === 'pending' &&
                                !attention(x) && (
                                  <button
                                    className="textbtn"
                                    disabled={task.busy}
                                    onClick={() =>
                                      void task.run(async () => {
                                        await rpc('wm2_review', {
                                          p_line: x.id,
                                          p_rev: x.rev,
                                          p_item: x.item_id,
                                          p_qty: x.final_qty,
                                          p_method: x.method,
                                          p_customer: x.customer,
                                          p_decision: 'ready',
                                          p_reason: x.reason,
                                        })
                                        result.reload()
                                      })
                                    }
                                  >
                                    검토 완료
                                  </button>
                                )}
                              {admin && !completed(x) && (
                                <button
                                  className="quiet"
                                  onClick={() => setEdit(x)}
                                >
                                  거래 검토
                                </button>
                              )}
                            </div>
                          </div>
                        ))}
                    </div>
                  </details>
                )
              })}
          </div>
          {!rows.length && !issues.length && (
            <Empty title="이 날짜에 검토할 거래가 없습니다" />
          )}
          {batches.length > 0 && (
            <section className="past-batches">
              <h3>확정된 마감</h3>
              {batches.map((b: Batch) => (
                <button
                  className="issue-row"
                  key={b.id}
                  onClick={() => setBatch(b.id)}
                >
                  <span>
                    <b>
                      {b.sequence}차 마감 · 반영 {b.lines}건
                    </b>
                    <small>
                      {b.actor} · {timeKo(b.approved_at)}
                    </small>
                  </span>
                  <ChevronRight size={16} />
                </button>
              ))}
            </section>
          )}
          {admin && (rows.length > 0 || issues.length > 0) && (
            <div className="close-foot">
              <p>
                {day} 전체 유형 · 승인 대상 {ready.length}건. 필터와 관계없이
                보류·제외를 뺀 거래를 확정합니다.
              </p>
              <button
                className="primary"
                disabled={
                  task.busy ||
                  blocked ||
                  (!ready.length && !remaining && !!batches.length)
                }
                onClick={() => setConfirm(true)}
              >
                일일 마감 승인
              </button>
            </div>
          )}
        </>
      )}
      {confirm && d && (
        <Sheet title="일일 마감 승인 확인" close={() => setConfirm(false)}>
          <h2>{day} 전체 유형</h2>
          <p>
            확인한 거래 {ready.length}건을 마감합니다. 재고 관리 대상의 수량만
            반영합니다.
          </p>
          <ErrorText text={task.error} />
          <button className="primary" disabled={task.busy} onClick={approve}>
            {task.busy ? '승인 처리 중…' : '확인하고 마감 확정'}
          </button>
        </Sheet>
      )}
      {edit && (
        <Review
          row={edit}
          all={rows}
          close={() => setEdit(null)}
          saved={result.reload}
        />
      )}
      {source && (
        <Evidence
          {...source}
          admin={admin}
          close={() => setSource(null)}
          saved={result.reload}
        />
      )}
      {batch && <BatchDetails id={batch} close={() => setBatch('')} />}
    </>
  )
}
export { Picking } from './Picking'
