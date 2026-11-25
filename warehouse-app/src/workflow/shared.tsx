import { useEffect, useRef, useState, type ReactNode } from 'react'
import { X } from 'lucide-react'
import { db, rpc, message, DbError } from '../db'
import { SearchBox, useDebounce } from '../ui'
import { type SKU } from './model'

export function useData<T>(
  name: string,
  args: Record<string, unknown>,
  version = 0,
) {
  const [data, setData] = useState<T | null>(null),
    [error, setError] = useState(''),
    [retry, setRetry] = useState(0)
  const key = JSON.stringify(args)
  const activeQuery = useRef('')
  useEffect(() => {
    let active = true
    const identity = name + key
    if (activeQuery.current !== identity) setData(null)
    activeQuery.current = identity
    setError('')
    rpc<T>(name, JSON.parse(key))
      .then((d) => {
        if (active) setData(d)
      })
      .catch((e) => {
        if (active) setError(message(e))
      })
    return () => {
      active = false
    }
  }, [name, key, version, retry])
  return { data, error, reload: () => setRetry((n) => n + 1) }
}
export function useTask(onStale?: () => void) {
  const lock = useRef(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState('')
  async function run(fn: () => Promise<void>) {
    if (lock.current) return
    lock.current = true
    setBusy(true)
    setError('')
    try {
      await fn()
    } catch (e) {
      setError(
        e instanceof DbError
          ? message(e)
          : e instanceof Error
            ? e.message
            : '처리하지 못했습니다.',
      )
      if (e instanceof DbError && e.serverMessage === 'WM_STALE') onStale?.()
    } finally {
      lock.current = false
      setBusy(false)
    }
  }
  return { run, busy, error }
}
export function requestId(scope: string, payload: unknown) {
  const key = 'wm2-req:' + scope,
    signature = JSON.stringify(payload)
  try {
    const saved = JSON.parse(sessionStorage.getItem(key) || 'null')
    if (saved?.signature === signature) return saved.id as string
  } catch {}
  const id = crypto.randomUUID()
  sessionStorage.setItem(key, JSON.stringify({ id, signature }))
  return id
}
export function doneRequest(scope: string) {
  sessionStorage.removeItem('wm2-req:' + scope)
}
export async function evidenceRequest(url: string, init: RequestInit = {}) {
  const session = (await db!.auth.getSession()).data.session
  if (!session) throw new Error('로그인이 필요합니다.')
  const res = await fetch(url, {
    ...init,
    headers: {
      ...init.headers,
      Authorization: 'Bearer ' + session.access_token,
    },
  })
  const result = await res.json()
  if (!res.ok) throw new Error(result.error || '원본을 열 수 없습니다.')
  return result
}
export function Sheet({
  title,
  close,
  children,
}: {
  title: string
  close: () => void
  children: ReactNode
}) {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dialog = ref.current!,
      el = document.activeElement as HTMLElement,
      overflow = document.body.style.overflow
    dialog.showModal()
    document.body.style.overflow = 'hidden'
    return () => {
      dialog.close()
      document.body.style.overflow = overflow
      el?.focus()
    }
  }, [])
  return (
    <dialog
      className="drawer work-sheet"
      ref={ref}
      aria-label={title}
      onCancel={close}
    >
      <div className="drawer-bar">
        <strong>{title}</strong>
        <button className="icon" aria-label={title + ' 닫기'} onClick={close}>
          <X size={20} />
        </button>
      </div>
      <div className="drawer-body">{children}</div>
    </dialog>
  )
}
export function ErrorText({ text }: { text: string }) {
  return text ? (
    <p role="alert" className="error">
      {text}
    </p>
  ) : null
}
export function Loading({
  error,
  retry,
}: {
  error: string
  retry: () => void
}) {
  return error ? (
    <p role="alert" className="status">
      {error}{' '}
      <button className="textbtn" onClick={retry}>
        다시 시도
      </button>
    </p>
  ) : (
    <p role="status" className="help">
      불러오는 중…
    </p>
  )
}
export function DayField({
  day,
  setDay,
  label = '대상 날짜',
}: {
  day: string
  setDay: (d: string) => void
  label?: string
}) {
  return (
    <label className="day-field">
      {label}
      <input
        type="date"
        required
        value={day}
        onChange={(e) => {
          if (e.target.value) setDay(e.target.value)
        }}
      />
    </label>
  )
}
export function SkuSearch({
  select,
  initial = '',
}: {
  select: (i: SKU) => void
  initial?: string
}) {
  const [s, setS] = useState(initial)
  const q = useDebounce(s)
  const result = useData<SKU[]>('wm2_catalog', { p_search: q })
  return (
    <div className="sku-search">
      <SearchBox value={s} onChange={setS} placeholder="품목명·SKU·사양 검색" />
      {result.data ? (
        <div className="sku-results">
          {result.data.length ? (
            result.data.map((i) => (
              <button type="button" key={i.id} onClick={() => select(i)}>
                <strong>{i.name}</strong>
                <small>
                  {[i.sku !== i.name ? i.sku : '', i.spec, i.racks.join(', ')]
                    .filter(Boolean)
                    .join(' · ')}
                </small>
              </button>
            ))
          ) : (
            <p className="help">일치하는 품목이 없습니다.</p>
          )}
        </div>
      ) : (
        <Loading error={result.error} retry={result.reload} />
      )}
    </div>
  )
}

export async function uploadFile(file: File) {
  if (file.size > 3 * 1024 * 1024)
    throw new Error('파일은 3MB까지 첨부할 수 있습니다.')
  const content = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result).split(',')[1])
    reader.onerror = () => reject(new Error('파일을 읽을 수 없습니다.'))
    reader.readAsDataURL(file)
  })
  const r = await evidenceRequest('/api/evidence', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content }),
  })
  return r.sha256 as string
}
