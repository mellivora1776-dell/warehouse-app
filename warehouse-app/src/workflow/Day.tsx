import { useState } from 'react'
import { ChevronRight, MapPin, Check, ClipboardList } from 'lucide-react'
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
    ready = rows.filter((r) => !r.entry_id && r.decision === 'ready')
  const pending = rows.filter(
      (r) => !r.entry_id && r.decision === 'pending',
    ).length,
    openIssues = issues.filter((i) => !i.deferred).length
  const groups = grouped(rows)
  const shortage = groups.some((group) => {
    const delta = planned(group.filter((r) => r.decision === 'ready'))
    return (
      group.some((r) => !r.entry_id && r.decision === 'ready') &&
      (group[0].qty == null || group[0].qty + delta.net < 0)
    )
  })
  const remaining =
    rows.some((r) => !r.entry_id && r.decision !== 'exclude') || !!issues.length
  const scope = 'close:' + day
  const switchDay = (date: string) => {
    setSuccess('')
    setDay(date)
  }
  async function approve() {
    if (!d) return
    await task.run(async () => {
      const complete = await rpc<{ sequence: number }>('wm2_close', {
        p_day: day,
        p_stamp: d.stamp,
        p_request: requestId(scope, d.stamp),
      })
      doneRequest(scope)
      setConfirm(false)
      setSuccess(day + ' ' + complete.sequence + '차 마감을 저장했습니다.')
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
        <DayField day={day} setDay={switchDay} />
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
      {!confirm && <ErrorText text={task.error} />}
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
            <span>{day} · 한국 시간</span>
          </div>
          {(pending > 0 || openIssues > 0 || shortage) && (
            <div className="check-notice" role="status">
              {[
                pending ? '거래 ' + pending + '건 미검토' : '',
                openIssues ? '문서 ' + openIssues + '건 확인 필요' : '',
                shortage
                  ? '승인 대상에 재고 부족 또는 미확인 품목이 있습니다'
                  : '',
              ]
                .filter(Boolean)
                .join(' · ')}
            </div>
          )}
          {issues.map((i) => (
            <button
              className="issue-row"
              key={i.id}
              onClick={() => setSource({ id: i.id, issue: i })}
            >
              <span>
                <b>
                  {i.deferred ? '보류 · ' : ''}
                  {i.external_id}
                </b>
                <small>{i.issue}</small>
              </span>
              <ChevronRight size={17} />
            </button>
          ))}
          {groups
            .filter((g) => !cat || g.some((r) => r.category === cat))
            .map((g) => {
              const first = g[0],
                s = planned(g)
              const posted = g.filter((r) => r.entry_id),
                hasPlan = g.some((r) => !r.entry_id && r.decision !== 'exclude')
              const postedIn = posted.reduce(
                  (n, r) => n + (r.direction > 0 ? (r.final_qty ?? 0) : 0),
                  0,
                ),
                postedOut = posted.reduce(
                  (n, r) => n + (r.direction < 0 ? (r.final_qty ?? 0) : 0),
                  0,
                )
              const remainingQty = first.qty == null ? null : first.qty + s.net
              return (
                <article
                  className="product-card"
                  key={first.item_id ?? first.id}
                >
                  <header>
                    <div>
                      <h3>{first.name || first.raw_name}</h3>
                      {(first.item_spec || first.spec) && (
                        <small>{first.item_spec || first.spec}</small>
                      )}
                    </div>
                    <span>
                      {first.item_id
                        ? '현재고 ' + qty(first.qty)
                        : 'SKU 연결 필요'}
                    </span>
                  </header>
                  <div className="detail-heading">
                    <span>입출고 상세</span>
                    <span>수량</span>
                  </div>
                  {g
                    .filter((r) => !cat || r.category === cat)
                    .map((r) => (
                      <div className="trade" key={r.id}>
                        <div className="trade-main">
                          <div>
                            <b>{rowLabel(r)}</b>
                            <small>
                              {r.external_id} ·{' '}
                              {r.entry_id ? '승인 완료' : decisions[r.decision]}
                              {r.edition && r.edition > 1 ? ' · 수정본' : ''}
                            </small>
                            {r.reason && <small>{r.reason}</small>}
                          </div>
                          <strong>
                            {r.direction > 0 ? '+' : '−'}
                            {r.final_qty ?? '?'}
                          </strong>
                        </div>
                        <div className="row-actions">
                          {r.final_qty !== r.read_qty && (
                            <small>원문 {qty(r.read_qty)}</small>
                          )}
                          <button
                            className="textbtn"
                            onClick={() => setSource({ id: r.document_id })}
                          >
                            근거·버전
                          </button>
                          {admin && !r.entry_id && (
                            <button
                              className="quiet"
                              onClick={() => setEdit(r)}
                            >
                              거래 검토
                            </button>
                          )}
                        </div>
                      </div>
                    ))}
                  {posted.length > 0 && (
                    <p className="small-meta">
                      이 날짜 확정 · 입고 {qty(postedIn)} / 출고{' '}
                      {qty(postedOut)}
                    </p>
                  )}
                  {hasPlan && (
                    <footer className="projection">
                      <span>
                        품목 예정 합계 · 입고 {qty(s.incoming)} / 출고{' '}
                        {qty(s.outgoing)}
                      </span>
                      <b
                        className={
                          remainingQty != null && remainingQty < 0
                            ? 'negative'
                            : ''
                        }
                      >
                        예상 현재고 {qty(remainingQty)}
                      </b>
                    </footer>
                  )}
                </article>
              )
            })}
          {!rows.length && !issues.length && (
            <Empty title="이 날짜에 검토할 거래가 없습니다" />
          )}
          {!!batches.length && (
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
                승인은 선택한 날짜의 모든 유형에 적용됩니다. 보류·제외는
                합계에서 빠집니다.
              </p>
              <button
                className="primary"
                disabled={
                  task.busy ||
                  !!pending ||
                  !!openIssues ||
                  shortage ||
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
          <h2>{day}</h2>
          <p className="confirm-text">
            실제 입출고가 완료된 승인 대상 {ready.length}건을 반영합니다. 이후
            변경은 정정 거래로 남습니다.
          </p>
          <ErrorText text={task.error} />
          <button disabled={task.busy} className="primary" onClick={approve}>
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
export function Picking({ day, setDay, admin }: Props) {
  const result = useData<DayData>('wm2_day', { p_day: day }),
    task = useTask(result.reload)
  const [sort, setSort] = useState('rack'),
    [source, setSource] = useState('')
  const [pendingPick, setPendingPick] = useState<{
    id: string
    done: boolean
  } | null>(null)
  const outbound = (result.data?.rows ?? []).filter(
    (r) =>
      !r.entry_id &&
      r.doc_status === 'current' &&
      r.direction < 0 &&
      ['sale', 'production_out'].includes(r.category) &&
      !['hold', 'exclude'].includes(r.decision),
  )
  const documents = new Map<string, Row[]>()
  for (const r of outbound) {
    const rows = documents.get(r.document_id) ?? []
    rows.push(r)
    documents.set(r.document_id, rows)
  }
  const collator = new Intl.Collator('ko', { numeric: true })
  const rackKey = (r: Row) =>
    [...(r.racks ?? [])].sort(collator.compare)[0] || '￿'
  return (
    <>
      <div className="title-row">
        <h1>피킹리스트</h1>
        <Refresh onClick={result.reload} />
      </div>
      <div className="work-toolbar">
        <DayField day={day} setDay={setDay} label="출고 날짜" />
        <label>
          건별 정렬
          <select value={sort} onChange={(e) => setSort(e.target.value)}>
            <option value="rack">랙 위치순</option>
            <option value="name">품목명순</option>
          </select>
        </label>
      </div>
      <ErrorText text={task.error} />
      {!result.data ? (
        <Loading error={result.error} retry={result.reload} />
      ) : (
        <>
          {result.data.issues.length > 0 && (
            <p className="check-notice">
              식별 또는 대조가 필요한 문서 {result.data.issues.length}건은 일일
              마감에서 확인하세요.
            </p>
          )}
          {result.data.removed.map((r, i) => (
            <p className="check-notice" key={i}>
              {r.external_id} 수정 · 이미 피킹한 {r.name} {qty(r.qty)}가 새
              지시서에서 빠졌습니다.
            </p>
          ))}
          {Array.from(documents.entries()).map(([id, list]) => (
            <article className="product-card" key={id}>
              <header>
                <div>
                  <small>
                    {categoryLabels[list[0].category]} · {list[0].case_key}
                  </small>
                  <h3>{list[0].customer || '생산 작업'}</h3>
                  <small>
                    {list[0].external_id} · v{list[0].version}
                    {(list[0].edition ?? 0) > 1 ? ' 수정본' : ''}
                  </small>
                </div>
                <button className="textbtn" onClick={() => setSource(id)}>
                  근거·버전
                </button>
              </header>
              {list
                .sort(
                  (a, b) =>
                    (sort === 'rack'
                      ? collator.compare(rackKey(a), rackKey(b))
                      : 0) ||
                    collator.compare(
                      a.name || a.raw_name,
                      b.name || b.raw_name,
                    ),
                )
                .map((r) => (
                  <div className="pick-row" key={r.id}>
                    {admin ? (
                      <input
                        type="checkbox"
                        aria-label={(r.name || r.raw_name) + ' 피킹 완료'}
                        disabled={task.busy || !r.item_id || !r.final_qty}
                        checked={
                          pendingPick?.id === r.id ? pendingPick.done : r.picked
                        }
                        onChange={(e) => {
                          const done = e.target.checked
                          setPendingPick({ id: r.id, done })
                          void task
                            .run(async () => {
                              await rpc('wm2_pick', {
                                p_line: r.id,
                                p_rev: r.rev,
                                p_done: done,
                              })
                              result.reload()
                            })
                            .finally(() => setPendingPick(null))
                        }}
                      />
                    ) : r.picked ? (
                      <Check size={18} />
                    ) : (
                      <ClipboardList size={18} />
                    )}
                    <div>
                      <b>{r.name || r.raw_name}</b>
                      {(r.item_spec || r.spec) && (
                        <small>{r.item_spec || r.spec}</small>
                      )}
                      <small>
                        <MapPin size={13} />{' '}
                        {r.racks?.join(' · ') || '위치 미등록'}
                      </small>
                      <small>
                        {r.method ||
                          (r.category === 'sale'
                            ? '방식 미확인'
                            : '내부 반출')}{' '}
                        · {r.picked ? '피킹 완료' : '피킹 대기'}
                      </small>
                      {r.pick_changed && (
                        <strong className="warn">
                          이전 피킹 내용 변경 · 다시 확인
                        </strong>
                      )}
                      {(r.qty == null ||
                        r.final_qty == null ||
                        r.qty < r.final_qty) && (
                        <small className="negative">
                          {r.qty == null
                            ? '현재고 미확인'
                            : r.final_qty == null
                              ? '출고 수량 미확인'
                              : '현재고 ' +
                                qty(r.qty) +
                                ' · ' +
                                qty(r.final_qty - r.qty) +
                                ' 부족'}
                        </small>
                      )}
                    </div>
                    <strong>{qty(r.final_qty)}</strong>
                  </div>
                ))}
            </article>
          ))}
          {!documents.size && <Empty title="피킹할 출고 지시가 없습니다" />}
        </>
      )}
      {source && (
        <Evidence id={source} admin={admin} close={() => setSource('')} />
      )}
    </>
  )
}
