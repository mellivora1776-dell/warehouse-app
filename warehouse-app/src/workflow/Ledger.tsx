import { useState } from 'react'
import { ChevronRight, SlidersHorizontal } from 'lucide-react'
import { Empty, PageEnd, Refresh, SearchBox, useDebounce, usePage } from '../ui'
import { Sheet } from './shared'
import {
  categoryLabels,
  methods,
  origins,
  qty,
  methodLabel,
  timeKo,
  today,
  type Movement,
} from './model'
import { Evidence } from './Evidence'
import { ManualForm } from './ManualForm'
import { BatchDetails } from './Day'

function signed(m: Movement) {
  if (m.kind === 'opening') return qty(m.after_qty)
  if (m.signed_qty == null)
    return m.kind === 'count' ? qty(m.after_qty) : '미확인'
  return (
    (m.signed_qty > 0 ? '+' : '') + m.signed_qty.toLocaleString('ko-KR') + '개'
  )
}
function description(m: Movement) {
  return m.category === 'sale'
    ? [m.customer, methodLabel(m)].filter(Boolean).join(' · ')
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
  const [view, setView] = useState(''),
    [notice, setNotice] = useState('')
  return (
    <Sheet title="확정 수불 상세" close={close}>
      <div className="document-head">
        <span>
          {m.work_day} · {categoryLabels[m.category]}
        </span>
        <h2>{m.name}</h2>
        <p>
          {[m.sku !== m.name ? m.sku : '', m.spec].filter(Boolean).join(' · ')}
        </p>
      </div>
      <dl className="facts">
        <dt>수불 내역</dt>
        <dd>
          {description(m)}
          {m.corrects_entry ? ' · 정정' : ''}
        </dd>
        <dt>수량</dt>
        <dd>{signed(m)}</dd>
        <dt>변경 전 → 후</dt>
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
        {admin && m.batch_id && (
          <button className="quiet" onClick={() => setView('correct')}>
            별도 정정 거래
          </button>
        )}
      </div>
      {notice && (
        <p className="callout" role="status">
          {notice}
        </p>
      )}
      {view === 'correct' && (
        <Sheet title="별도 정정 거래" close={() => setView('')}>
          <ManualForm
            item={{ id: m.item_id, name: m.name }}
            flow="correction"
            original={m}
            onSaved={() => {
              setView('')
              setNotice('정정 거래가 일일 마감 검토 대상으로 등록됐습니다.')
            }}
          />
        </Sheet>
      )}
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
  const page = usePage<Movement>(
    'wm2_log',
    {
      p_filters: {
        item: itemId,
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
    version,
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
                <strong>{sales ? description(m) : m.name}</strong>
                <span>{sales ? m.name : description(m)}</span>
                {sales && m.spec && <small>{m.spec}</small>}
              </span>
              <b>
                {sales && m.signed_qty != null
                  ? (m.signed_qty > 0 ? '복원 ' : '') +
                    qty(Math.abs(m.signed_qty))
                  : signed(m)}
              </b>
              <ChevronRight size={15} />
            </button>
          ))}
          {!page.loading && !page.error && !page.rows.length && (
            <Empty title="조회 조건에 맞는 확정 기록이 없습니다" />
          )}
          <PageEnd page={page} />
        </>
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
