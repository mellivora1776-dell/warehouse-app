import { useState } from 'react'
import { MapPin } from 'lucide-react'
import { rpc } from '../db'
import { Refresh } from '../ui'
import { DayField, Loading, ErrorText, useData, useTask } from './shared'
import {
  grouped,
  standardName,
  pickCount,
  rowLabel,
  qty,
  methodLabel,
  type Row,
} from './model'

type Calendar = {
  rows: Row[]
  removed: { work_day: string; name: string; qty: number }[]
}
const collator = new Intl.Collator('ko', { numeric: true })
const racksFor = (r: Row) => [...(r.racks || [])].sort(collator.compare)
const dateLabel = (d: string) =>
  Number(d.slice(5, 7)) + '월 ' + Number(d.slice(8)) + '일'

function delivery(r: Row) {
  const notes = [
    ...new Set(
      [r.remarks, r.method_raw, r.packing]
        .flatMap((t) => t?.split(/\s*·\s*/) || [])
        .map((t) => t.trim())
        .filter(Boolean),
    ),
  ]
  const time =
    notes
      .map((s) =>
        s.match(
          /(?:오전|오후)\s*\d{1,2}(?:시(?:\s*\d{1,2}분)?|:\d{2})|\b\d{1,2}:\d{2}\b/,
        ),
      )
      .find(Boolean)?.[0] || ''
  const method =
    r.method === '퀵·용차' && r.method_raw?.includes('용차')
      ? '퀵(용차 배송)'
      : methodLabel(r) || ''
  const label =
    r.category === 'sale'
      ? [r.customer, [time, method].filter(Boolean).join(' ')]
          .filter(Boolean)
          .join(' · ')
      : rowLabel(r)
  const memo = [
    ...new Set(
      notes
        .map((s) => s.replace(time, '').trim())
        .filter(
          (s) => s && s !== method && s !== r.method && !label.includes(s),
        ),
    ),
  ]
  if (r.pick_changed) memo.push('기존 피킹 변경')
  return { label, memo: memo.join(' · ') }
}

type PickIntent = { id: string; rev: number; done: boolean }
function PickItems({
  rows,
  byName,
  heading,
  admin,
  busy,
  toggle,
  intent,
}: {
  intent: PickIntent | null
  rows: Row[]
  byName: boolean
  heading?: string
  admin: boolean
  busy: boolean
  toggle: (r: Row) => void
}) {
  function control(r: Row, i: number, label: string) {
    const name = standardName(r)
    return admin ? (
      <input
        type="checkbox"
        aria-label={
          name +
          ' 피킹 완료 · ' +
          label +
          ' · 지시 ' +
          (i + 1) +
          ' · ' +
          qty(pickCount(r))
        }
        disabled={
          busy ||
          (intent?.id === r.id && intent.rev === r.rev) ||
          (!r.item_id && r.resolution !== 'pick_only') ||
          !pickCount(r)
        }
        checked={
          intent?.id === r.id && intent.rev === r.rev ? intent.done : r.picked
        }
        onChange={() => toggle(r)}
      />
    ) : (
      <small>{r.picked ? '완료' : '대기'}</small>
    )
  }
  const items = grouped(rows).sort(
    (a, b) =>
      (byName
        ? 0
        : collator.compare(
            racksFor(a[0])[0] || '￿',
            racksFor(b[0])[0] || '￿',
          )) || collator.compare(standardName(a[0]), standardName(b[0])),
  )
  return (
    <section className="pick-section">
      {heading && <h3 className="pick-client">{heading}</h3>}
      {items.map((g) => {
        const f = g[0],
          racks = racksFor(f),
          name = standardName(f),
          total = g.every((r) => pickCount(r) != null)
            ? g.reduce((n, r) => n + (pickCount(r) || 0), 0)
            : null
        const single = g.length === 1 ? delivery(f) : null
        return (
          <article className="pick-item" key={f.item_id || f.id}>
            {racks.length > 0 && (
              <div className="rack-line">
                <MapPin size={14} />
                {racks.join(' · ')}
              </div>
            )}
            {single ? (
              <div className="single-pick">
                <div>
                  <h3>{name}</h3>
                  {heading !== single.label && <small>{single.label}</small>}
                  {single.memo && <small>{single.memo}</small>}
                </div>
                <strong>{qty(total)}</strong>
                <label className="single-check">
                  {control(f, 0, single.label)}
                </label>
              </div>
            ) : (
              <div className="pick-heading">
                <h3>{name}</h3>
                <strong>
                  {g.length > 1 ? '총 ' : ''}
                  {qty(total)}
                </strong>
              </div>
            )}
            {!single &&
              g.map((r, i) => {
                const { label, memo } = delivery(r)
                return (
                  <div className="pick-instruction" key={r.id}>
                    <label className="pick-check">
                      <span>
                        {heading === label
                          ? g.length > 1
                            ? '지시 ' + (i + 1)
                            : '피킹 완료'
                          : label +
                            (g.length > 1 && r.category !== 'sale'
                              ? ' · 지시 ' + (i + 1)
                              : '')}
                        {memo && <small>{memo}</small>}
                      </span>
                      {g.length > 1 && <b>{qty(pickCount(r))}</b>}
                      {control(r, i, label)}
                    </label>
                  </div>
                )
              })}
          </article>
        )
      })}
    </section>
  )
}

export function Picking({
  admin,
  koreaDay,
}: {
  admin: boolean
  koreaDay: string
}) {
  const [selected, setSelected] = useState(''),
    [view, setView] = useState('rack')
  const [intent, setIntent] = useState<PickIntent | null>(null)
  const day = selected || koreaDay
  const result = useData<Calendar>('wm6_picking', { p_day: day }),
    task = useTask(result.reload)
  const dates = new Map<string, Row[]>([[day, []]])
  for (const r of result.data?.rows || []) {
    const list = dates.get(r.work_day) || []
    list.push(r)
    dates.set(r.work_day, list)
  }
  const removed = result.data?.removed || []
  for (const r of removed) if (!dates.has(r.work_day)) dates.set(r.work_day, [])
  const ordered = [...dates.entries()].sort(([a], [b]) => a.localeCompare(b))
  function toggle(r: Row) {
    void task.run(async () => {
      setIntent({ id: r.id, rev: r.rev, done: !r.picked })
      try {
        await rpc('wm2_pick', { p_line: r.id, p_rev: r.rev, p_done: !r.picked })
        result.reload()
      } catch (e) {
        setIntent(null)
        throw e
      }
    })
  }
  return (
    <>
      <div className="title-row">
        <h1>피킹리스트</h1>
        <Refresh onClick={result.reload} />
      </div>
      <div className="work-toolbar">
        <DayField
          day={day}
          setDay={(d) => setSelected(d === koreaDay ? '' : d)}
          label="출고 날짜"
        />
        <label>
          보기
          <select value={view} onChange={(e) => setView(e.target.value)}>
            <option value="rack">전체 랙 위치순</option>
            <option value="name">전체 품목명순</option>
            <option value="customer">거래처별</option>
            <option value="case">출고 건별</option>
          </select>
        </label>
        {selected && (
          <button className="textbtn" onClick={() => setSelected('')}>
            오늘로
          </button>
        )}
      </div>
      <ErrorText text={task.error} />
      {!result.data ? (
        <Loading error={result.error} retry={result.reload} />
      ) : (
        ordered.map(([date, rows], index) => {
          const future = date > day,
            sections = new Map<string, { label?: string; rows: Row[] }>()
          for (const r of rows) {
            const label = delivery(r).label,
              sectioned = future || view === 'case' || view === 'customer'
            const key = sectioned
              ? JSON.stringify([
                  future || view === 'case' ? r.case_id || r.document_id : '',
                  label,
                ])
              : ''
            const section = sections.get(key) || {
              label: sectioned ? label : undefined,
              rows: [],
            }
            section.rows.push(r)
            sections.set(key, section)
          }
          return (
            <div className="pick-date" key={date} data-day={date}>
              {index === 1 && <h2 className="next-shipping">다음 출고 예정</h2>}
              <h2 className="shipping-day">
                {date === koreaDay
                  ? '오늘 출고'
                  : dateLabel(date) + (future ? ' 출고 예정' : ' 출고')}
                {date === koreaDay && <small>{dateLabel(date)}</small>}
              </h2>
              {removed
                .filter((x) => x.work_day === date)
                .map((x, i) => (
                  <p className="check-notice" key={i}>
                    변경 지시에서 준비한 {x.name} {qty(x.qty)}가 빠졌습니다.
                  </p>
                ))}
              {[...sections.entries()].map(([key, g]) => (
                <PickItems
                  key={key}
                  rows={g.rows}
                  heading={g.label}
                  byName={view === 'name'}
                  admin={admin}
                  busy={task.busy}
                  intent={intent}
                  toggle={toggle}
                />
              ))}
              {!rows.length && (
                <p className="pick-empty">이 날짜에 피킹할 품목이 없습니다.</p>
              )}
            </div>
          )
        })
      )}
    </>
  )
}
