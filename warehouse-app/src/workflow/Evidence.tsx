import { useState } from 'react'
import { rpc } from '../db'
import { useDebounce } from '../ui'
import {
  qty,
  stockCount,
  pickCount,
  completed,
  rowLabel,
  timeKo,
  statuses,
  origins,
  decisions,
  type DocInfo,
  type Issue,
  type Movement,
  type DocVersion,
  type Row,
} from './model'
import {
  Sheet,
  Loading,
  ErrorText,
  useData,
  useTask,
  evidenceRequest,
  uploadFile,
} from './shared'
import { RecordEdit, movementTarget } from './RecordEdit'
import { Review } from './Review'

function FileLink({ id }: { id: string }) {
  const [link, setLink] = useState('')
  const task = useTask()
  return (
    <div>
      {link ? (
        <a href={link} target="_blank" rel="noreferrer">
          보관된 원본 열기
        </a>
      ) : (
        <button
          className="quiet"
          onClick={() =>
            task.run(async () => {
              const d = await evidenceRequest(
                '/api/evidence?document=' + encodeURIComponent(id),
              )
              setLink(d.url)
              setTimeout(() => setLink(''), 55000)
            })
          }
          disabled={task.busy}
        >
          원본 파일 보기
        </button>
      )}
      <ErrorText text={task.error} />
    </div>
  )
}
function CaseChoice({
  doc,
  onSelect,
}: {
  doc: DocInfo
  onSelect: (v: string) => void
}) {
  const [q, setQ] = useState(''),
    term = useDebounce(q)
  const search = useData<
    {
      id: string
      external_id: string
      external_key: string
      customer: string
      work_day: string
    }[]
  >('wm2_cases', { p_query: term })
  const choices = term ? search.data : doc.suggestions
  return (
    <>
      <label>
        기존 건 찾기
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="거래처 또는 지시서 번호"
        />
      </label>
      <label>
        대상 지시서
        <select
          defaultValue=""
          required
          onChange={(e) => onSelect(e.target.value)}
        >
          <option value="">건 선택</option>
          {choices?.map((x) => (
            <option value={x.id} key={x.id}>
              {x.work_day} · {x.customer} · {x.external_id}
            </option>
          ))}
        </select>
      </label>
      {term && search.error && <ErrorText text={search.error} />}
    </>
  )
}
function Resolve({
  info,
  issue,
  saved,
}: {
  info: DocInfo
  issue: Issue
  saved: () => void
}) {
  const [action, setAction] = useState(''),
    [reason, setReason] = useState(''),
    [target, setTarget] = useState('')
  const task = useTask()
  const choices =
    issue.status === 'unlinked'
      ? [
          ['new', '별개의 새 건'],
          ['replace', '기존 건의 수정본'],
          ['defer', '보류'],
          ['dismiss', '제외'],
        ]
      : [
          ['reconciled', '대조 완료'],
          ['defer', '보류'],
        ]
  return (
    <form
      className="work-form review-box"
      onSubmit={(e) => {
        e.preventDefault()
        void task.run(async () => {
          await rpc('wm2_resolve', {
            p_doc: issue.id,
            p_action: action,
            p_target: action === 'replace' ? target : null,
            p_reason: reason,
          })
          saved()
        })
      }}
    >
      <h3>
        {issue.status === 'unlinked'
          ? '출고·작업 건 확인'
          : '승인된 수량과 대조'}
      </h3>
      <p className="help">{issue.issue}</p>
      <label>
        확인 결과
        <select
          required
          value={action}
          onChange={(e) => setAction(e.target.value)}
        >
          <option value="">선택</option>
          {choices.map(([v, t]) => (
            <option key={v} value={v}>
              {t}
            </option>
          ))}
        </select>
      </label>
      {action === 'replace' && <CaseChoice doc={info} onSelect={setTarget} />}
      <label>
        판단 근거
        <input
          value={reason}
          required
          maxLength={1500}
          onChange={(e) => setReason(e.target.value)}
        />
      </label>
      <ErrorText text={task.error} />
      <button className="primary" disabled={task.busy}>
        판단 저장
      </button>
    </form>
  )
}
function Comparison({ versions }: { versions: DocVersion[] }) {
  const ordered = versions.filter((v) => v.status !== 'dismissed')
  if (ordered.length < 2) return null
  const ids = Array.from(
    new Set(ordered.flatMap((v) => v.lines.map((l) => l.line_key))),
  )
  return (
    <details className="expand" open>
      <summary>버전별 지시 수량</summary>
      {ids.map((k) => {
        const line = ordered
          .flatMap((v) => v.lines)
          .find((l) => l.line_key === k)!
        return (
          <div className="compare-line" key={k}>
            <b>{line.raw_name}</b>
            <div>
              {ordered.map((v) => {
                const l = v.lines.find((x) => x.line_key === k)
                return (
                  <span key={v.id}>
                    v{v.version} {l ? qty(l.read_qty) : '없음'}
                  </span>
                )
              })}
            </div>
          </div>
        )
      })}
    </details>
  )
}
export function Evidence({
  id,
  admin,
  close,
  issue,
  saved,
}: {
  id: string
  admin: boolean
  close: () => void
  issue?: Issue
  saved?: () => void
}) {
  const result = useData<DocInfo>('wm2_document', { p_doc: id })
  const data = result.data
  const [fix, setFix] = useState<Movement | null>(null),
    [mapping, setMapping] = useState<Row | null>(null)
  const upload = useTask(),
    cancelTask = useTask()
  const [cancel, setCancel] = useState(false),
    [why, setWhy] = useState('')
  const v = data?.versions.find((x) => x.id === id)
  return (
    <Sheet title="거래 근거와 버전" close={close}>
      {!data || !v ? (
        <Loading error={result.error} retry={result.reload} />
      ) : (
        <>
          <div className="document-head">
            <span>
              {v.document_type} · {statuses[v.status]}
            </span>
            <h2>{v.external_id}</h2>
            <p>
              {v.work_day} · {v.customer || '거래처 미지정'}
            </p>
          </div>
          {admin &&
            v &&
            ['unlinked', 'current'].includes(v.status) &&
            !data.settled.length &&
            !v.lines.some(completed) && (
              <details
                className="expand"
                open={cancel}
                onToggle={(e) => setCancel(e.currentTarget.open)}
              >
                <summary>이 미승인 버전 취소</summary>
                <form
                  className="work-form"
                  onSubmit={(e) => {
                    e.preventDefault()
                    void cancelTask.run(async () => {
                      await rpc('wm3_cancel', { p_doc: id, p_reason: why })
                      saved?.()
                      result.reload()
                      setCancel(false)
                    })
                  }}
                >
                  <p>
                    피킹과 마감 후보에서 빠집니다. 원문과 피킹 이력은
                    보존됩니다.
                  </p>
                  <label>
                    취소 사유
                    <input
                      value={why}
                      required
                      maxLength={1500}
                      onChange={(e) => setWhy(e.target.value)}
                    />
                  </label>
                  <ErrorText text={cancelTask.error} />
                  <button
                    className="quiet"
                    disabled={cancelTask.busy || !why.trim()}
                  >
                    미승인 문서 취소 확정
                  </button>
                </form>
              </details>
            )}
          <Comparison versions={data.versions} />
          {v.status === 'reconcile' && (
            <section className="review-box">
              <h3>승인 실적과 최종 지시 비교</h3>
              <p className="help">
                기록 수량은 원승인과 비교해 수정할 수 있습니다. 현재고 조정은
                품목 상세의 실사에서 처리하세요.
              </p>
              {Array.from(
                new Set([
                  ...data.settled.map((x) => x.item_id),
                  ...v.lines.map((x) => x.item_id).filter(Boolean),
                ]),
              ).map((item) => {
                const rows = v.lines.filter((l) => l.item_id === item),
                  posted = data.settled.filter((m) => m.item_id === item)
                const target = rows.reduce(
                    (n, r) => n + (stockCount(r) ?? 0) * r.direction,
                    0,
                  ),
                  actual = posted.reduce((n, m) => n + (m.signed_qty ?? 0), 0)
                return (
                  <div className="compare-line" key={item}>
                    <b>{rows[0]?.raw_name ?? posted[0]?.name}</b>
                    <div>
                      확정 순변동 {actual}개 · 지시 순변동{' '}
                      {rows.some((r) => stockCount(r) == null)
                        ? '미확인'
                        : target + '개'}
                    </div>
                    {!rows.some((r) => stockCount(r) == null) && (
                      <small>
                        수량 차이 {target - actual > 0 ? '+' : ''}
                        {target - actual}개
                      </small>
                    )}
                  </div>
                )
              })}
              {v.lines.some((x) => x.stock_managed !== false && !x.item_id) && (
                <p className="warn">SKU 미확정 품목은 별도로 확인해 주세요.</p>
              )}
            </section>
          )}
          {data.settled.length > 0 && (
            <details open={v.status === 'reconcile'} className="expand">
              <summary>관련 확정 수불 {data.settled.length}건</summary>
              {data.settled.map((m) => (
                <div key={m.id} className="mini-row">
                  <span>
                    #{m.id} {m.name} · {m.signed_qty}개
                  </span>
                  {admin && (
                    <button className="quiet" onClick={() => setFix(m)}>
                      기록 수정
                    </button>
                  )}
                </div>
              ))}
            </details>
          )}
          {issue && admin && ['unlinked', 'reconcile'].includes(v.status) && (
            <Resolve
              info={data}
              issue={issue}
              saved={() => {
                saved?.()
                close()
              }}
            />
          )}
          {data.versions.map((x) => (
            <details className="expand" key={x.id} open={x.id === id}>
              <summary>
                v{x.version} · {x.external_id} · {statuses[x.status]}
              </summary>
              <p className="small-meta">
                {origins[x.origin]} · {x.submitted_by} · {timeKo(x.created_at)}
              </p>
              {x.source_time && <p>원본 시각 {x.source_time}</p>}
              {admin && (
                <>
                  {x.source?.name && <p>{x.source.name}</p>}
                  {x.source?.text && <blockquote>{x.source.text}</blockquote>}
                  {x.has_file ? (
                    <FileLink id={x.id} />
                  ) : (
                    <div>
                      <p className="help">첨부된 원본 파일 없음</p>
                      <label className="file-extra">
                        이 버전에 원본 추가
                        <input
                          type="file"
                          accept="image/jpeg,image/png,image/webp,application/pdf"
                          disabled={upload.busy}
                          onChange={(e) => {
                            const f = e.target.files?.[0]
                            if (f)
                              void upload.run(async () => {
                                const sha = await uploadFile(f)
                                await rpc('wm2_attach_file', {
                                  p_doc: x.id,
                                  p_sha: sha,
                                  p_name: f.name,
                                })
                                result.reload()
                              })
                          }}
                        />
                      </label>
                      <ErrorText text={upload.error} />
                    </div>
                  )}
                </>
              )}
              {x.lines.map((l) => (
                <div key={l.id} className="compare-line">
                  <b>{l.raw_name}</b>
                  {l.spec && <small>{l.spec}</small>}
                  <div>
                    원문 {qty(l.read_qty)} · 검토 수량 {qty(l.final_qty)} ·{' '}
                    {completed(l) ? '승인 완료' : decisions[l.decision]}
                  </div>
                  <small>
                    {l.display_name || l.standard_name || l.name} ·{' '}
                    {rowLabel(l)} · 준비 {qty(pickCount(l))} / 재고{' '}
                    {qty(stockCount(l))}
                  </small>
                  {l.requester && admin && (
                    <small>지시자·보고자 · {l.requester}</small>
                  )}
                  {l.match_basis && <small>확정 근거 · {l.match_basis}</small>}
                  {(l.packing || l.remarks) && (
                    <small>
                      {[l.packing, l.remarks].filter(Boolean).join(' · ')}
                    </small>
                  )}
                  {admin &&
                    l.stock_managed !== false &&
                    x.status === 'reconcile' && (
                      <button className="quiet" onClick={() => setMapping(l)}>
                        {l.item_id ? 'SKU 확인' : 'SKU 연결'}
                      </button>
                    )}
                  {l.read_reason && <small>{l.read_reason}</small>}
                  {l.confidence != null && (
                    <small>분석 신뢰도 {Math.round(l.confidence * 100)}%</small>
                  )}
                </div>
              ))}
            </details>
          ))}
          <details className="expand">
            <summary>이 문서의 검토 이력 {data.audit.length}건</summary>
            {data.audit.map((a) => (
              <div className="compare-line" key={a.id}>
                <b>
                  {{
                    file: '원본 파일 추가',
                    link: '수정본 SKU 연결',
                    review: '거래 검토',
                    pick: '피킹 변경',
                    version: '버전 연결',
                    new_sku: 'SKU 등록',
                    new: '별개 건 확인',
                    replace: '수정본 연결',
                    defer: '보류',
                    reconciled: '대조 완료',
                    dismiss: '제외',
                    cancel: '미승인 문서 취소',
                    alias: '별칭 확정',
                  }[a.action] ?? a.action}
                </b>
                <small>
                  {a.actor} · {timeKo(a.happened_at)}
                </small>
                {a.action === 'review' && (
                  <p>
                    {qty(a.before_value?.final_qty)} →{' '}
                    {qty(a.after_value?.final_qty)} ·{' '}
                    {
                      decisions[
                        a.after_value?.decision as keyof typeof decisions
                      ]
                    }{' '}
                    {a.after_value?.reason}
                  </p>
                )}
                {a.action === 'pick' && (
                  <p>{a.after_value ? '피킹 완료' : '피킹 해제'}</p>
                )}
                {a.after_value?.reason && a.action !== 'review' && (
                  <p>{a.after_value.reason}</p>
                )}
              </div>
            ))}
          </details>
          {mapping && (
            <Review
              row={mapping}
              all={v.lines}
              close={() => setMapping(null)}
              saved={result.reload}
            />
          )}
          {fix && (
            <RecordEdit
              target={movementTarget(fix)}
              close={() => setFix(null)}
              saved={() => {
                result.reload()
                saved?.()
              }}
            />
          )}
        </>
      )}
    </Sheet>
  )
}
