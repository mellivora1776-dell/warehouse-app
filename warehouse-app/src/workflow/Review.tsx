import { useState } from 'react'
import { rpc } from '../db'
import {
  type Row,
  type Decision,
  type SKU,
  decisions,
  methods,
  qty,
  planned,
  pickCount,
  stockCount,
} from './model'
import { Sheet, SkuSearch, useTask, ErrorText } from './shared'

export function Review({
  row,
  all,
  close,
  saved,
}: {
  row: Row
  all: Row[]
  close: () => void
  saved: () => void
}) {
  const [item, setItem] = useState({
      id: row.item_id,
      name: row.name,
      qty: row.qty,
    }),
    [search, setSearch] = useState(!row.item_id && row.stock_managed !== false),
    [reg, setReg] = useState(false)
  const [n, setN] = useState(
      row.final_qty == null ? '' : String(row.final_qty),
    ),
    [method, setMethod] = useState(row.method ?? ''),
    [customer, setCustomer] = useState(row.customer),
    [decision, setDecision] = useState<Decision>(
      row.decision === 'pending' ? 'ready' : row.decision,
    ),
    [reason, setReason] = useState(row.reason)
  const managed = row.stock_managed !== false,
    picking = row.pick_required ?? row.direction < 0
  const [pick, setPick] = useState(String(pickCount(row) ?? '')),
    [stock, setStock] = useState(String(stockCount(row) ?? ''))
  const [remember, setRemember] = useState(false),
    [context, setContext] = useState(row.context || '')
  const [sku, setSku] = useState(
      [row.standard_name || row.raw_name, row.standard_spec]
        .filter(Boolean)
        .join(' '),
    ),
    [name, setName] = useState(row.standard_name || row.raw_name),
    [spec, setSpec] = useState(row.standard_spec || row.spec),
    [racks, setRacks] = useState(''),
    [first, setFirst] = useState(''),
    [ordered, setOrdered] = useState(true),
    [checked, setChecked] = useState(false)
  const reconcile = row.doc_status === 'reconcile'
  const task = useTask(() => {
    saved()
    close()
  })
  const after = planned([
    ...all.filter((r) => r.id !== row.id && r.item_id === item.id),
    {
      ...row,
      final_qty: n ? Number(n) : null,
      stock_qty: stock ? Number(stock) : null,
      decision,
    },
  ])
  function select(i: SKU) {
    setItem(i)
    setSearch(false)
    setReg(false)
  }
  function complete() {
    saved()
    close()
  }
  return (
    <Sheet title="거래 검토" close={close}>
      <div className="document-head">
        <small>
          {row.external_id} · v{row.version}
        </small>
        <h2>{row.raw_name}</h2>
        {row.spec && <p>{row.spec}</p>}
      </div>
      {managed ? (
        <div className="form-block">
          <div className="mini-row">
            <div>
              <small>연결된 SKU</small>
              <b>{item.name || '연결 필요'}</b>
            </div>
            <button className="quiet" onClick={() => setSearch(!search)}>
              {search ? '검색 닫기' : '품목 찾기'}
            </button>
          </div>
          {search && (
            <>
              <SkuSearch
                initial={row.raw_sku || row.raw_name}
                select={select}
              />
              <button className="textbtn" onClick={() => setReg(!reg)}>
                {reg ? '등록 취소' : '새 SKU 등록'}
              </button>
            </>
          )}
          {item.id && item.name !== row.raw_name && !reconcile && (
            <details className="expand">
              <summary>별칭 적용 범위</summary>
              <label className="checklabel">
                <input
                  type="checkbox"
                  checked={remember}
                  onChange={(e) => setRemember(e.target.checked)}
                />
                이후 동일한 원문에도 적용
              </label>
              {remember && (
                <label>
                  적용 문맥
                  <input
                    value={context}
                    onChange={(e) => setContext(e.target.value)}
                    placeholder="모든 문맥은 빈칸"
                  />
                </label>
              )}
            </details>
          )}
        </div>
      ) : (
        <>
          <p className="callout">
            {picking
              ? '피킹 전용 · 재고 차감 없음'
              : '입고 보고 · 재고 증가 없음'}
          </p>
          <details className="expand">
            <summary>집계 제외 규칙 재사용</summary>
            <label className="checklabel">
              <input
                type="checkbox"
                checked={remember}
                onChange={(e) => setRemember(e.target.checked)}
              />
              이후 같은 현장 명칭에 적용
            </label>
            {remember && (
              <label>
                적용 문맥
                <input
                  value={context}
                  onChange={(e) => setContext(e.target.value)}
                />
              </label>
            )}
          </details>
        </>
      )}
      {reg ? (
        <form
          className="work-form review-box"
          onSubmit={(e) => {
            e.preventDefault()
            void task.run(async () => {
              await rpc('wm2_new_sku', {
                p_line: row.id,
                p_rev: row.rev,
                p_sku: sku,
                p_name: name,
                p_spec: spec,
                p_racks: racks
                  .split(',')
                  .map((s) => s.trim())
                  .filter(Boolean),
                p_ordered: ordered,
                p_first_receipt: first === 'zero',
              })
              complete()
            })
          }}
        >
          <h3>신규 품목 확정</h3>
          <label>
            SKU
            <input
              required
              value={sku}
              onChange={(e) => setSku(e.target.value)}
            />
          </label>
          <label>
            품목명
            <input
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
          </label>
          <label>
            사양
            <input
              value={spec}
              onChange={(e) => setSpec(e.target.value)}
              placeholder="전압, 재질, 회전 방향 등"
            />
          </label>
          <label>
            랙 위치
            <input
              value={racks}
              onChange={(e) => setRacks(e.target.value)}
              placeholder="여러 위치는 쉼표로 구분"
            />
          </label>
          <label className="checklabel">
            <input
              type="checkbox"
              checked={ordered}
              onChange={(e) => setOrdered(e.target.checked)}
            />
            주문품으로 관리
          </label>
          <label>
            등록 전 재고
            <select
              required
              value={first}
              onChange={(e) => setFirst(e.target.value)}
            >
              <option value="">이전 재고 확인</option>
              <option value="zero">이전 재고 0개 확인</option>
              <option value="unknown">이전 재고 미확인</option>
            </select>
          </label>
          <p className="help">
            {first === 'unknown'
              ? '마감 전에 직접 센 수량을 입력하세요.'
              : '자료의 입고 수량은 일일 마감 승인 때 반영됩니다.'}
          </p>
          <label className="checklabel">
            <input
              required
              type="checkbox"
              checked={checked}
              onChange={(e) => setChecked(e.target.checked)}
            />
            유사 품목과 사양을 대조했습니다
          </label>
          <ErrorText text={task.error} />
          <button className="primary" disabled={task.busy || !checked}>
            새 SKU 등록 및 연결
          </button>
        </form>
      ) : (
        <form
          className="work-form"
          onSubmit={(e) => {
            e.preventDefault()
            void task.run(async () => {
              if (reconcile) {
                await rpc('wm2_link_revision', {
                  p_line: row.id,
                  p_rev: row.rev,
                  p_item: item.id,
                })
                complete()
                return
              }
              await rpc('wm3_review', {
                p_pick_qty: picking ? (pick ? Number(pick) : null) : 0,
                p_stock_qty: managed ? (stock ? Number(stock) : null) : 0,
                p_remember: remember,
                p_context: context,
                p_line: row.id,
                p_rev: row.rev,
                p_item: item.id,
                p_qty: n ? Number(n) : null,
                p_method: method || null,
                p_customer: customer,
                p_decision: decision,
                p_reason: reason,
              })
              complete()
            })
          }}
        >
          {!reconcile && (
            <>
              <div className="form-pair">
                <label>
                  검토 수량
                  <input
                    type="number"
                    min="1"
                    max="2147483647"
                    step="1"
                    required={decision === 'ready'}
                    value={n}
                    onChange={(e) => {
                      const value = e.target.value
                      if (picking && pick === n) setPick(value)
                      if (managed && stock === n) setStock(value)
                      setN(value)
                    }}
                  />
                </label>
                <div className="metric">
                  <span>원문 수량</span>
                  <b>{qty(row.read_qty)}</b>
                </div>
              </div>
              {(picking || managed) && (
                <details className="expand">
                  <summary>피킹·재고 반영 수량</summary>
                  <div className="form-pair">
                    {picking && (
                      <label>
                        피킹 준비 수량
                        <input
                          type="number"
                          min="1"
                          step="1"
                          value={pick}
                          onChange={(e) => setPick(e.target.value)}
                        />
                      </label>
                    )}
                    {managed && (
                      <label>
                        재고 반영 수량
                        <input
                          type="number"
                          min="1"
                          step="1"
                          value={stock}
                          onChange={(e) => setStock(e.target.value)}
                        />
                      </label>
                    )}
                  </div>
                </details>
              )}
              {row.category === 'sale' && (
                <div className="form-pair">
                  <label>
                    거래처
                    <input
                      required={decision === 'ready'}
                      value={customer}
                      onChange={(e) => setCustomer(e.target.value)}
                    />
                  </label>
                  <label>
                    방식
                    <select
                      required={decision === 'ready'}
                      value={method}
                      onChange={(e) => setMethod(e.target.value)}
                    >
                      <option value="">미확인</option>
                      {methods.map((m) => (
                        <option key={m}>{m}</option>
                      ))}
                    </select>
                  </label>
                </div>
              )}
              <label>
                검토 상태
                <select
                  value={decision}
                  onChange={(e) => setDecision(e.target.value as Decision)}
                >
                  {Object.entries(decisions).map(([v, l]) => (
                    <option key={v} value={v}>
                      {l}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                {decision === 'hold' || decision === 'exclude'
                  ? '처리 사유'
                  : '검토 메모'}
                <textarea
                  required={['hold', 'exclude'].includes(decision)}
                  maxLength={1500}
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                />
              </label>
              {item.id && (
                <div className="projection" aria-live="polite">
                  <span>
                    품목 합계 · 입고 {qty(after.incoming)} / 출고{' '}
                    {qty(after.outgoing)}
                  </span>
                  <b>
                    현재 {qty(item.qty)} → 예상{' '}
                    {qty(item.qty == null ? null : item.qty + after.net)}
                  </b>
                </div>
              )}
            </>
          )}
          <ErrorText text={task.error} />
          <button
            className="primary"
            disabled={task.busy || (reconcile && !item.id)}
          >
            {reconcile ? 'SKU 연결 확정' : '검토 저장'}
          </button>
        </form>
      )}
    </Sheet>
  )
}
