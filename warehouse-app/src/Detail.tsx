import { useEffect, useRef, useState } from 'react'
import {
  ArrowDownToLine,
  ArrowUpFromLine,
  ClipboardList,
  MapPin,
  X,
} from 'lucide-react'
import {
  rpc,
  message,
  DbError,
  type Detail as ItemDetail,
  type Kind,
  type Change,
} from './db'
import { preview, quantity, operation } from './calc.mjs'
import { History, Status } from './ui'
type Props = {
  id: string
  user: string
  admin: boolean
  close: () => void
  saved: () => void
}
const inputLabel = {
  in: '입고할 수량',
  out: '출고할 수량',
  count: '직접 센 최종 수량',
}
const modes = [
  ['in', '입고', ArrowDownToLine],
  ['out', '출고', ArrowUpFromLine],
  ['count', '실사 수량 수정', ClipboardList],
] as const

export function Detail({ id, user, admin, close, saved }: Props) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [sequence, refresh] = useState(0),
    [info, setInfo] = useState<ItemDetail | null>(null),
    [error, setError] = useState(''),
    [notice, setNotice] = useState('')
  useEffect(() => {
    const node = dialog.current!,
      trigger = document.activeElement as HTMLElement
    node.showModal()
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      node.close()
      document.body.style.overflow = overflow
      trigger?.focus()
    }
  }, [])
  useEffect(() => {
    let live = true
    setError('')
    setInfo(null)
    rpc<ItemDetail>('wm_item', { p_item: id })
      .then((x) => {
        if (live) setInfo(x)
      })
      .catch((e) => {
        if (live) setError(message(e))
      })
    return () => {
      live = false
    }
  }, [id, sequence])
  function update(text: string) {
    setNotice(text)
    refresh((x) => x + 1)
    saved()
  }
  return (
    <dialog
      ref={dialog}
      className="drawer"
      aria-labelledby="detail-label"
      onCancel={close}
      onClick={(e) => {
        if (e.target === dialog.current) {
          const r = dialog.current!.getBoundingClientRect()
          if (
            e.clientX < r.left ||
            e.clientX > r.right ||
            e.clientY < r.top ||
            e.clientY > r.bottom
          )
            close()
        }
      }}
    >
      <div className="drawer-bar">
        <span id="detail-label">품목 상세</span>
        <button className="icon" onClick={close} aria-label="품목 상세 닫기">
          <X size={21} />
        </button>
      </div>
      <div className="drawer-body">
        {notice && <Status>{notice}</Status>}
        {error ? (
          <Status>
            {error}{' '}
            <button className="textbtn" onClick={() => refresh((x) => x + 1)}>
              다시 시도
            </button>
          </Status>
        ) : !info ? (
          <Status>품목을 불러오는 중…</Status>
        ) : (
          <>
            <h2 className="item-title">{info.name}</h2>
            <div className="balance">
              <span>현재고</span>
              <strong>
                {info.qty === null ? (
                  '미확인'
                ) : (
                  <>
                    {info.qty.toLocaleString('ko-KR')}
                    <small> 대</small>
                  </>
                )}
              </strong>
            </div>
            <div className="locations">
              <div className="small-label">
                <MapPin size={16} />랙 위치
              </div>
              <div className="rack-values">
                {info.racks.length
                  ? info.racks.map((r) => <span key={r}>{r}</span>)
                  : '위치 미등록'}
              </div>
            </div>
            {admin && <Editor item={info} user={user} update={update} />}
            <div className="section-title">
              <h3>변경 기록</h3>
              <span>한국 시간</span>
            </div>
            <History itemId={id} version={sequence} />
          </>
        )}
      </div>
    </dialog>
  )
}

function Editor({
  item,
  user,
  update,
}: {
  item: ItemDetail
  user: string
  update: (msg: string) => void
}) {
  const storageKey = 'wm-pending:' + user + ':' + item.id
  const [pending, setPending] = useState<Change | null>(() => {
    try {
      return JSON.parse(sessionStorage.getItem(storageKey) || 'null')
    } catch {
      return null
    }
  })
  const [kind, setKind] = useState<Kind>(
    pending?.p_kind ?? (item.qty === null ? 'count' : 'in'),
  )
  const [input, setInput] = useState(pending ? String(pending.p_amount) : ''),
    [memo, setMemo] = useState(pending?.p_memo ?? '')
  const [busy, setBusy] = useState(false),
    [err, setErr] = useState('')
  const lock = useRef(false)
  const result = preview(item.qty, kind, input)
  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (lock.current || (!pending && result.after === undefined)) return
    lock.current = true
    setBusy(true)
    setErr('')
    const req = pending ?? {
      p_item: item.id,
      p_request: crypto.randomUUID(),
      p_revision: item.revision,
      p_kind: kind,
      p_amount: Number(input),
      p_memo: memo.trim(),
    }
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(req))
      setPending(req)
      const out = await rpc<{ after: number }>('wm_change', req)
      sessionStorage.removeItem(storageKey)
      setPending(null)
      update(
        operation[kind] +
          ' 기록을 저장했습니다. 저장 후 ' +
          quantity(out.after),
      )
    } catch (e) {
      if (
        e instanceof DbError &&
        (e.serverMessage.startsWith('WM_') || e.code === '42501')
      ) {
        sessionStorage.removeItem(storageKey)
        setPending(null)
        if (e.serverMessage === 'WM_STALE') {
          update(message(e))
          return
        }
        setErr(message(e))
      } else {
        setErr(
          '저장 여부를 확인하지 못했습니다. 같은 요청으로 다시 확인해 주세요.',
        )
      }
    } finally {
      lock.current = false
      setBusy(false)
    }
  }
  return (
    <section className="editor">
      <h3>수량 변경</h3>
      <form onSubmit={submit}>
        <div className="mode-group" aria-label="작업 종류">
          {modes.map(([k, label, Icon]) => (
            <button
              type="button"
              aria-pressed={kind === k}
              disabled={
                !!pending || busy || (k !== 'count' && item.qty === null)
              }
              className={kind === k ? 'selected' : ''}
              key={k}
              onClick={() => {
                setKind(k)
                setInput('')
                setErr('')
              }}
            >
              <Icon size={16} />
              {label}
            </button>
          ))}
        </div>
        {item.qty === null && (
          <p className="help">
            시작 수량이 미확인입니다. 처음 한 번은 직접 센 수량을 등록해 주세요.
          </p>
        )}
        <label>
          {inputLabel[kind]}
          <div className="number-field">
            <input
              type="text"
              inputMode="numeric"
              autoComplete="off"
              value={input}
              disabled={!!pending || busy}
              placeholder="수량 입력"
              onChange={(e) => setInput(e.target.value)}
            />
            <span>대</span>
          </div>
        </label>
        <label>
          메모 <span className="optional">선택</span>
          <input
            disabled={!!pending || busy}
            value={memo}
            maxLength={1000}
            placeholder="변경 사유 또는 참고 사항"
            onChange={(e) => setMemo(e.target.value)}
          />
        </label>
        {pending ? (
          <Status>
            저장 요청 {operation[pending.p_kind]} {quantity(pending.p_amount)} ·
            처리 결과 확인 중
          </Status>
        ) : (
          <div
            className={'preview ' + (result.error ? 'invalid' : '')}
            aria-live="polite"
          >
            {result.error ?? (
              <>
                현재 {quantity(item.qty)} <span>→</span> 저장 후{' '}
                <b>
                  {result.after !== undefined ? quantity(result.after) : '—'}
                </b>
              </>
            )}
          </div>
        )}
        {err && (
          <p className="error" role="alert">
            {err}
          </p>
        )}
        <button
          className="primary"
          disabled={busy || (!pending && result.after === undefined)}
        >
          {busy
            ? '저장 중…'
            : pending
              ? '같은 요청 다시 확인'
              : (kind === 'count' ? '실사 수량' : operation[kind]) + ' 저장'}
        </button>
      </form>
    </section>
  )
}
