import { useState } from 'react'
import { MapPin } from 'lucide-react'
import { rpc } from '../db'
import { Empty, Refresh } from '../ui'
import { DayField, Loading, ErrorText, useData, useTask } from './shared'
import {
  grouped,
  standardName,
  pickCount,
  stockCount,
  rowLabel,
  qty,
  completed,
  type DayData,
  type Row,
} from './model'
import { Evidence } from './Evidence'

const collator = new Intl.Collator('ko', { numeric: true })
const rackList = (r: Row) => [...(r.racks || [])].sort(collator.compare)
export function Picking({
  day,
  setDay,
  admin,
}: {
  day: string
  setDay: (d: string) => void
  admin: boolean
}) {
  const result = useData<DayData>('wm2_day', { p_day: day }),
    task = useTask(result.reload)
  const [view, setView] = useState('rack'),
    [source, setSource] = useState(''),
    [pending, setPending] = useState<{ id: string; done: boolean } | null>(null)
  const rows = (result.data?.rows || []).filter(
    (r) =>
      !completed(r) &&
      !r.related_hold &&
      r.doc_status === 'current' &&
      (r.pick_required ??
        (r.direction < 0 && ['sale', 'production_out'].includes(r.category))) &&
      !['hold', 'exclude'].includes(r.decision),
  )
  const sections = new Map<string, Row[]>()
  for (const r of rows) {
    const k =
      view === 'customer'
        ? r.category === 'sale'
          ? r.customer || '거래처 미확인'
          : '생산 작업'
        : view === 'case'
          ? r.case_id || r.document_id
          : 'all'
    sections.set(k, [...(sections.get(k) || []), r])
  }
  const sortedSections = [...sections.entries()].sort(([a], [b]) =>
    collator.compare(a, b),
  )
  const outstanding = new Map<string, number>()
  for (const r of rows)
    if (r.item_id)
      outstanding.set(
        r.item_id,
        (outstanding.get(r.item_id) || 0) + (stockCount(r) || 0),
      )
  function toggle(r: Row, done: boolean) {
    setPending({ id: r.id, done })
    void task
      .run(async () => {
        await rpc('wm2_pick', { p_line: r.id, p_rev: r.rev, p_done: done })
        result.reload()
      })
      .finally(() => setPending(null))
  }
  return (
    <>
      <div className="title-row">
        <h1>피킹리스트</h1>
        <Refresh onClick={result.reload} />
      </div>
      <div className="work-toolbar">
        <DayField day={day} setDay={setDay} label="출고 날짜" />
        <label>
          보기
          <select value={view} onChange={(e) => setView(e.target.value)}>
            <option value="rack">전체 랙 위치순</option>
            <option value="name">전체 품목명순</option>
            <option value="customer">거래처별</option>
            <option value="case">출고 건별</option>
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
              문서 관계 확인 {result.data.issues.length}건 · 일일 마감에서
              확인하세요.
            </p>
          )}
          {result.data.removed.map((r, i) => (
            <p className="check-notice" key={i}>
              수정 지시에서 피킹한 {r.name} {qty(r.qty)}가 빠졌습니다.
            </p>
          ))}
          {sortedSections.map(([key, list], i) => (
            <section className="pick-section" key={key}>
              {view === 'customer' && <h2>{key}</h2>}
              {view === 'case' && (
                <h2>
                  {list[0].category === 'sale'
                    ? list[0].customer || '거래처 미확인'
                    : '생산 작업'}{' '}
                  · 지시 {i + 1}
                </h2>
              )}
              {grouped(list)
                .sort(
                  (a, b) =>
                    (view !== 'name'
                      ? collator.compare(
                          rackList(a[0])[0] || '￿',
                          rackList(b[0])[0] || '￿',
                        )
                      : 0) ||
                    collator.compare(standardName(a[0]), standardName(b[0])),
                )
                .map((g) => {
                  const f = g[0],
                    racks = rackList(f),
                    name = standardName(f),
                    total = g.every((r) => pickCount(r) != null)
                      ? g.reduce((n, r) => n + (pickCount(r) || 0), 0)
                      : null
                  const shortage =
                    f.item_id &&
                    f.qty != null &&
                    (outstanding.get(f.item_id) || 0) > f.qty
                  return (
                    <article className="pick-item" key={f.item_id || f.id}>
                      <div className="rack-line">
                        <MapPin size={14} />
                        {racks.length
                          ? racks.join(' · ')
                          : f.stock_managed === false
                            ? '외부 준비'
                            : '랙 미등록'}
                      </div>
                      <div className="pick-heading">
                        <h3>{name}</h3>
                        <strong>
                          {g.length > 1 ? '총 ' : ''}
                          {qty(total)}
                        </strong>
                      </div>
                      {f.stock_managed === false ? (
                        <small className="nonstock">
                          피킹 전용 · 재고 차감 없음
                        </small>
                      ) : !f.item_id ? (
                        <small className="issue-text">품목 연결 필요</small>
                      ) : f.qty == null ? (
                        <small className="issue-text">현재고 미입력</small>
                      ) : shortage ? (
                        <small className="issue-text">
                          재고 부족 · 현재 {qty(f.qty)}
                        </small>
                      ) : null}
                      {g.map((r, idx) => (
                        <div className="pick-instruction" key={r.id}>
                          <label className="pick-check">
                            <span>
                              {rowLabel(r)}
                              {g.length > 1 && r.category !== 'sale'
                                ? ' · 지시 ' + (idx + 1)
                                : ''}
                              {(r.packing ||
                                r.remarks ||
                                r.pick_changed ||
                                (r.edition ?? 0) > 1) && (
                                <small>
                                  {[
                                    r.packing,
                                    r.remarks,
                                    r.pick_changed
                                      ? '기존 피킹 변경'
                                      : (r.edition ?? 0) > 1
                                        ? '수정본'
                                        : '',
                                  ]
                                    .filter(Boolean)
                                    .join(' · ')}
                                </small>
                              )}
                            </span>
                            {g.length > 1 && <b>{qty(pickCount(r))}</b>}
                            {admin ? (
                              <input
                                type="checkbox"
                                aria-label={
                                  name +
                                  ' 피킹 완료 · ' +
                                  rowLabel(r) +
                                  ' · 지시 ' +
                                  (idx + 1) +
                                  ' · ' +
                                  qty(pickCount(r))
                                }
                                disabled={
                                  task.busy ||
                                  (!r.item_id &&
                                    r.resolution !== 'pick_only') ||
                                  !pickCount(r)
                                }
                                checked={
                                  pending?.id === r.id ? pending.done : r.picked
                                }
                                onChange={(e) => toggle(r, e.target.checked)}
                              />
                            ) : (
                              <small>{r.picked ? '완료' : '대기'}</small>
                            )}
                          </label>
                          <button
                            className="source-link"
                            aria-label={rowLabel(r) + ' 근거·버전'}
                            onClick={() => setSource(r.document_id)}
                          >
                            근거·버전
                          </button>
                        </div>
                      ))}
                    </article>
                  )
                })}
            </section>
          ))}
          {!rows.length && <Empty title="이 날짜에 피킹할 품목이 없습니다" />}
        </>
      )}
      {source && (
        <Evidence
          id={source}
          admin={admin}
          close={() => setSource('')}
          saved={result.reload}
        />
      )}
    </>
  )
}
