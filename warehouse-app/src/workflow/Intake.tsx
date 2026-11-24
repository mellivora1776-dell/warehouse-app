import { useRef, useState } from 'react'
import { FileInput, ChevronRight } from 'lucide-react'
import { rpc } from '../db'
import { Empty, Refresh } from '../ui'
import {
  DayField,
  ErrorText,
  Loading,
  Sheet,
  uploadFile,
  useData,
  useTask,
} from './shared'
import { Evidence } from './Evidence'
import { statuses, type Issue } from './model'

type IntakeResult = { id: string; duplicate: boolean; status: string }
function Connection() {
  const result = useData<{ enabled: boolean }>('wm2_key', {
      p_action: 'status',
    }),
    task = useTask()
  const [key, setKey] = useState(''),
    [action, setAction] = useState('')
  async function save() {
    await task.run(async () => {
      const r = await rpc<{ token: string | null }>('wm2_key', {
        p_action: action,
      })
      setKey(r.token ?? '')
      setAction('')
      result.reload()
    })
  }
  return (
    <details className="expand">
      <summary>ChatGPT 연결 설정</summary>
      <p>
        일반 ChatGPT 대화나 프로젝트에 아래 분석 지침을 추가하세요. 그 대화에서
        이 프로젝트의 쓰기 가능한 Supabase 도구를 사용할 수 있으면 미승인 자료를
        직접 접수합니다. 도구가 없으면 ChatGPT가 출력한 JSON을 위 입력칸에
        붙여넣으세요.
      </p>
      <div className="link-row">
        <a href="/warehouse-action.json" target="_blank" rel="noreferrer">
          작업 명세 열기
        </a>
        <a href="/warehouse-instructions.txt" target="_blank" rel="noreferrer">
          ChatGPT 분석 지침
        </a>
      </div>
      <details className="expand">
        <summary>전용 GPT 또는 API용 등록 키</summary>
        <p>
          전용 GPT 편집기의 작업(Actions)에 명세를 가져오고 인증을 API 키 ·
          Bearer로 설정하세요.
        </p>
        {result.data ? (
          <>
            <p className="small-meta">
              등록 전용 키 · {result.data.enabled ? '사용 중' : '미발급'}
            </p>
            <div className="row-actions">
              <button className="quiet" onClick={() => setAction('rotate')}>
                {result.data.enabled ? '등록 키 교체' : '등록 키 발급'}
              </button>
              {result.data.enabled && (
                <button className="textbtn" onClick={() => setAction('revoke')}>
                  키 해제
                </button>
              )}
            </div>
          </>
        ) : (
          <Loading error={result.error} retry={result.reload} />
        )}
        {key && (
          <label>
            발급된 등록 키 · 이 화면에서 한 번 표시
            <input readOnly value={key} onFocus={(e) => e.target.select()} />
            <span className="help">
              GPT 작업의 인증칸에 보관하세요. 대화 메시지에 입력하지 마세요.
            </span>
            <button className="quiet" onClick={() => setKey('')}>
              키 표시 닫기
            </button>
          </label>
        )}
        {action && (
          <Sheet title="등록 키 설정" close={() => setAction('')}>
            <p>
              {action === 'revoke'
                ? '현재 키의 자료 등록 권한을 해제합니다.'
                : result.data?.enabled
                  ? '기존 키를 해제하고 새 등록 키를 발급합니다.'
                  : '미승인 자료만 등록할 수 있는 키를 발급합니다.'}
            </p>
            <ErrorText text={task.error} />
            <button className="primary" onClick={save} disabled={task.busy}>
              {action === 'revoke' ? '해제 확정' : '발급 확정'}
            </button>
          </Sheet>
        )}
      </details>
    </details>
  )
}
export function Intake({
  day,
  setDay,
}: {
  day: string
  setDay: (d: string) => void
}) {
  const result = useData<(Issue & { document_type: string })[]>(
    'wm2_documents',
    { p_day: day },
  )
  const task = useTask(),
    [raw, setRaw] = useState(''),
    [file, setFile] = useState<File | null>(null),
    [received, setReceived] = useState<IntakeResult | null>(null),
    [view, setView] = useState<Issue | null>(null)
  const [fileInputKey, setFileInputKey] = useState(0)
  const input = useRef<HTMLTextAreaElement>(null)
  async function submit(e: React.FormEvent) {
    e.preventDefault()
    await task.run(async () => {
      let doc
      try {
        doc = JSON.parse(raw)
      } catch {
        throw new Error('JSON의 따옴표, 괄호와 쉼표를 확인해 주세요.')
      }
      if (
        !doc ||
        typeof doc !== 'object' ||
        Array.isArray(doc) ||
        !Array.isArray(doc.lines)
      )
        throw new Error('문서 한 버전과 lines 배열이 필요합니다.')
      if (file) {
        const bytes = await file.arrayBuffer(),
          hash = Array.from(
            new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)),
            (v) => v.toString(16).padStart(2, '0'),
          ).join('')
        if (doc.source?.sha256 && doc.source.sha256.toLowerCase() !== hash)
          throw new Error('원본 파일이 JSON의 파일 지문과 다릅니다.')
        const sha = await uploadFile(file)
        doc.source = {
          ...doc.source,
          sha256: sha,
          name: doc.source?.name || file.name,
        }
      }
      const record = await rpc<IntakeResult>('wm2_import', { p_doc: doc })
      setReceived(record)
      setDay(doc.work_date)
      result.reload()
      setRaw('')
      setFile(null)
      setFileInputKey((k) => k + 1)
    })
  }
  return (
    <>
      <div className="title-row">
        <h1>분석 자료 등록</h1>
        <Refresh onClick={result.reload} />
      </div>
      <form className="work-form intake-form" onSubmit={submit}>
        <h2>
          <FileInput size={20} /> 문서 가져오기
        </h2>
        <label>
          분석 결과 JSON
          <textarea
            ref={input}
            className="json-input"
            rows={6}
            value={raw}
            onChange={(e) => setRaw(e.target.value)}
            required
            placeholder="ChatGPT의 분석 결과를 붙여넣으세요."
          />
        </label>
        <div className="form-pair" key={fileInputKey}>
          <label>
            JSON 파일로 불러오기
            <input
              type="file"
              accept=".json,application/json"
              onChange={(e) => {
                const f = e.target.files?.[0]
                if (f)
                  void task.run(async () => {
                    if (f.size > 250000)
                      throw new Error(
                        'JSON 파일은 250KB까지 등록할 수 있습니다.',
                      )
                    setRaw(await f.text())
                    input.current?.focus()
                  })
              }}
            />
          </label>
          <label>
            원본 파일 · 선택
            <input
              type="file"
              accept="image/jpeg,image/png,image/webp,application/pdf"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
            />
          </label>
        </div>
        <p className="help">
          문서 한 버전 전체를 등록하세요. 원본은 JPG·PNG·WebP·PDF 중 3MB까지
          첨부할 수 있습니다.
        </p>
        <ErrorText text={task.error} />
        <button className="primary" disabled={task.busy || !raw.trim()}>
          {task.busy ? '등록 중…' : '검토 자료 등록'}
        </button>
      </form>
      {received && (
        <p role="status" className="callout">
          {received.duplicate
            ? '이미 등록된 문서입니다.'
            : '검토 자료를 등록했습니다.'}{' '}
          {statuses[received.status]} · 재고 반영 전
        </p>
      )}
      <Connection />
      <div className="section-title">
        <h3>등록한 버전</h3>
        <DayField day={day} setDay={setDay} />
      </div>
      {result.data ? (
        result.data.length ? (
          result.data.map((d) => (
            <button key={d.id} className="issue-row" onClick={() => setView(d)}>
              <span>
                <b>{d.external_id}</b>
                <small>
                  {d.customer} · {d.document_type} · v{d.version} ·{' '}
                  {statuses[d.status]}
                </small>
              </span>
              <ChevronRight size={16} />
            </button>
          ))
        ) : (
          <Empty title="등록한 문서가 없습니다" />
        )
      ) : (
        <Loading error={result.error} retry={result.reload} />
      )}
      {view && (
        <Evidence
          id={view.id}
          admin
          issue={view}
          close={() => setView(null)}
          saved={result.reload}
        />
      )}
    </>
  )
}
