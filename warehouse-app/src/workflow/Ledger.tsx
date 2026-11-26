import { useState } from 'react'
import { ChevronRight, SlidersHorizontal } from 'lucide-react'
import { Empty, PageEnd, Refresh, SearchBox, useDebounce, usePage } from '../ui'
import { Sheet, useData, Loading } from './shared'
import {
  categoryLabels,
  methods,
  origins,
  qty,
  methodLabel,
  timeKo,
  today,
  type Movement,
  type Row,
  standardName,
  rowLabel,
} from './model'
import { Evidence } from './Evidence'
import {
  RecordEdit,
  AmendmentHistory,
  movementTarget,
  Disposition,
} from './RecordEdit'
import { Review } from './Review'
import { BatchDetails } from './Day'

function signed(m: Movement) {
  if (m.record_deleted) return '기록 삭제'
  if (m.kind === 'opening' || m.kind === 'count') return qty(m.record_qty)
  const n = m.record_signed_qty
  return n == null ? '미확인' : (n > 0 ? '+' : '') + qty(n)
}
function description(m: Movement) {
  return m.category === 'sale'
    ? [m.record_customer, m.record_method_raw || m.record_method]
        .filter(Boolean)
        .join(' · ')
    : categoryLabels[m.category]
}
function MovementDetail({
  m,
  admin,
  close,
}: {
  m: Movement
  admin: boolean
  close: () => void
}) {
  const [view, setView] = useState('')
  return (
    <Sheet title="확정 수불 상세" close={close}>
      <div className="document-head">
        <span>
          {m.work_day} · {categoryLabels[m.category]}
        </span>
        <h2>{m.display_name}</h2>
      </div>
      <dl className="facts">
        <dt>수불 내역</dt>
        <dd>
          {description(m)}
          {m.corrects_entry ? ' · 정정' : ''}
        </dd>
        <dt>수량</dt>
        <dd>{signed(m)}</dd>
        <dt>원승인 당시 재고</dt>
        <dd>
          {qty(m.before_qty)} → {qty(m.after_qty)}
        </dd>
        <dt>{m.batch_id ? '승인자' : '입력자'}</dt>
        <dd>{m.actor_name}</dd>
        <dt>{m.batch_id ? '승인 시각' : '기록 시각'}</dt>
        <dd>{timeKo(m.approved_at ?? m.created_at)}</dd>
        <dt>입력 경로</dt>
        <dd>{origins[m.origin] ?? m.origin}</dd>
        {m.document_id && (
          <>
            <dt>문서 버전</dt>
            <dd>
              {m.external_id} · v{m.version}
            </dd>
            <dt>원문 / 확정</dt>
            <dd>
              {qty(m.read_qty)} / {qty(m.final_qty)}
            </dd>
          </>
        )}
        {m.corrects_entry && (
          <>
            <dt>원승인</dt>
            <dd>수불 #{m.corrects_entry}</dd>
          </>
        )}
        {m.memo && (
          <>
            <dt>메모</dt>
            <dd>{m.memo}</dd>
          </>
        )}
      </dl>
      <div className="row-actions">
        {m.document_id && (
          <button className="quiet" onClick={() => setView('doc')}>
            거래 근거·버전
          </button>
        )}
        {m.related_document && (
          <button className="quiet" onClick={() => setView('revision')}>
            관련 수정본
          </button>
        )}
        {m.batch_id && (
          <button className="quiet" onClick={() => setView('batch')}>
            {m.sequence}차 마감 검토표
          </button>
        )}
      </div>
      {m.record_rev > 0 && <AmendmentHistory target={movementTarget(m)} />}
      {view === 'batch' && m.batch_id && (
        <BatchDetails id={m.batch_id} close={() => setView('')} />
      )}
      {(view === 'doc' || view === 'revision') && (
        <Evidence
          id={(view === 'doc' ? m.document_id : m.related_document)!}
          close={() => setView('')}
          admin={admin}
        />
      )}
    </Sheet>
  )
}
export function Ledger({
  admin,
  version = 0,
  itemId,
  sales = false,
}: {
  admin: boolean
  version?: number
  itemId?: string
  sales?: boolean
}) {
  const [query, setQuery] = useState(''),
    [cat, setCat] = useState(''),
    [from, setFrom] = useState(sales ? today() : ''),
    [to, setTo] = useState(sales ? today() : ''),
    [customer, setCustomer] = useState(''),
    [method, setMethod] = useState(''),
    [sort, setSort] = useState('desc'),
    [selected, setSelected] = useState<Movement | null>(null)
  const search = useDebounce(query),
    client = useDebounce(customer),
    invalid = Boolean(from && to && from > to)
  const [refresh, setRefresh] = useState(0),
    [edit, setEdit] = useState<{ m: Movement; deleting: boolean } | null>(null)
  const page = usePage<Movement>(
    'wm2_log',
    {
      p_filters: {
        item: itemId,
        sales,
        category: sales ? 'sale' : cat,
        from,
        to,
        sort,
        query: search,
        customer: client,
        method,
      },
    },
    'p_after',
    (r) => r.id,
    version + refresh,
  )
  const filters = (
    <>
      <div className="work-toolbar">
        <label>
          시작일
          <input
            type="date"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
          />
        </label>
        <label>
          종료일
          <input
            type="date"
            value={to}
            onChange={(e) => setTo(e.target.value)}
          />
        </label>
      </div>
      <div className="work-toolbar">
        {sales ? (
          <>
            <label>
              거래처
              <input
                value={customer}
                onChange={(e) => setCustomer(e.target.value)}
                placeholder="거래처명"
              />
            </label>
            <label>
              출고 방식
              <select
                value={method}
                onChange={(e) => setMethod(e.target.value)}
              >
                <option value="">전체 방식</option>
                {methods.map((m) => (
                  <option key={m}>{m}</option>
                ))}
              </select>
            </label>
          </>
        ) : (
          <label>
            수불 유형
            <select value={cat} onChange={(e) => setCat(e.target.value)}>
              <option value="">전체 유형</option>
              {Object.entries(categoryLabels).map(([k, v]) => (
                <option value={k} key={k}>
                  {v}
                </option>
              ))}
            </select>
          </label>
        )}
        <label>
          날짜순
          <select value={sort} onChange={(e) => setSort(e.target.value)}>
            <option value="desc">최신순</option>
            <option value="asc">오래된순</option>
          </select>
        </label>
      </div>
    </>
  )
  return (
    <>
      {!itemId && (
        <>
          <div className="title-row">
            <h1>{sales ? '영업출고 조회' : '입출고 기록'}</h1>
            <Refresh onClick={page.reload} />
          </div>
          {sales && (
            <label className="single-date">
              영업출고 일자
              <input
                type="date"
                value={from === to ? from : ''}
                onChange={(e) => {
                  setFrom(e.target.value)
                  setTo(e.target.value)
                }}
              />
            </label>
          )}
          <SearchBox
            value={query}
            onChange={setQuery}
            placeholder="품목명 또는 SKU 검색"
          />
        </>
      )}
      {itemId && (
        <PendingRecords
          itemId={itemId}
          admin={admin}
          version={version + refresh}
          reload={() => setRefresh((v) => v + 1)}
        />
      )}
      <details className="expand ledger-filters" open={sales || undefined}>
        <summary>
          <SlidersHorizontal size={15} /> 기간·조회 조건
        </summary>
        {filters}
      </details>
      {invalid ? (
        <p className="error">종료일을 시작일 이후로 지정해 주세요.</p>
      ) : (
        <>
          <div className="detail-heading">
            <span>{sales ? '거래처 · 방식 / 품목' : '날짜 · 수불 내역'}</span>
            <span>{sales ? '출고수량' : '수량'}</span>
          </div>
          {page.rows.map((m) => (
            <div key={m.id} className="ledger-line">
              <button
                key={m.id}
                className="movement-row"
                onClick={() => setSelected(m)}
              >
                <span>
                  <small>
                    {m.work_day}
                    {m.corrects_entry ? ' · 정정' : ''}
                    {m.origin === 'manual' && m.document_id ? ' · 수기' : ''}
                  </small>
                  <strong>{sales ? description(m) : m.display_name}</strong>
                  <span>
                    {sales ? m.display_name : description(m)}
                    {m.record_rev > 0 && ' · 기록 변경'}
                  </span>
                </span>
                <b>
                  {sales && m.record_signed_qty != null
                    ? (m.record_signed_qty > 0 ? '복원 ' : '') +
                      qty(Math.abs(m.record_signed_qty))
                    : signed(m)}
                </b>
                <ChevronRight size={15} />
              </button>
              {admin && m.kind !== 'opening' && (
                <div className="record-actions">
                  <button
                    className="record-action"
                    onClick={() => setEdit({ m, deleting: false })}
                  >
                    {m.record_deleted ? '기록 복구' : '수정'}
                  </button>
                  {!m.record_deleted && (
                    <button
                      className="record-action"
                      onClick={() => setEdit({ m, deleting: true })}
                    >
                      삭제
                    </button>
                  )}
                </div>
              )}
            </div>
          ))}
          {!page.loading && !page.error && !page.rows.length && (
            <Empty title="조회 조건에 맞는 확정 기록이 없습니다" />
          )}
          <PageEnd page={page} />
        </>
      )}
      {edit && (
        <RecordEdit
          target={movementTarget(edit.m)}
          deleting={edit.deleting}
          close={() => setEdit(null)}
          saved={() => setRefresh((v) => v + 1)}
        />
      )}
      {selected && (
        <MovementDetail
          m={selected}
          admin={admin}
          close={() => setSelected(null)}
        />
      )}
    </>
  )
}

function PendingRecords({
  itemId,
  admin,
  version,
  reload,
}: {
  itemId: string
  admin: boolean
  version: number
  reload: () => void
}) {
  const data = useData<Row[]>('wm4_pending', { p_item: itemId }, version)
  const [edit, setEdit] = useState<Row | null>(null),
    [del, setDel] = useState<Row | null>(null)
  if (!data.data) return <Loading error={data.error} retry={data.reload} />
  if (!data.data.length) return null
  return (
    <section className="pending-records">
      <h4>마감 전 거래</h4>
      {data.data.map((r) => (
        <div className="day-trade" key={r.id}>
          <span>
            <small>
              {r.work_day} ·{' '}
              {r.decision === 'hold' || r.related_hold ? '보류' : '승인 대기'}
            </small>
            {rowLabel(r)}
          </span>
          <b>{qty(r.final_qty)}</b>
          {admin && (
            <div className="record-actions">
              <button className="record-action" onClick={() => setEdit(r)}>
                수정
              </button>
              <button className="record-action" onClick={() => setDel(r)}>
                삭제
              </button>
            </div>
          )}
        </div>
      ))}
      {edit && (
        <Review
          row={edit}
          all={data.data.filter((r) => r.work_day === edit.work_day)}
          close={() => setEdit(null)}
          saved={reload}
        />
      )}
      {del && (
        <Disposition row={del} close={() => setDel(null)} saved={reload} />
      )}
    </section>
  )
}
