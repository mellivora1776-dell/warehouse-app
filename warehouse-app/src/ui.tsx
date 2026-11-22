import { useEffect, useRef, useState } from 'react'
import { ChevronDown, Search, X, RefreshCw, PackageOpen } from 'lucide-react'
import { rpc, message, type Page, type Entry } from './db'
import { operation, quantity } from './calc.mjs'

export function Brand() {
  return (
    <div className="brand">
      <img width="36" height="36" src="/mark.svg" alt="" />
      <span>재고 마스터</span>
    </div>
  )
}
export function SearchBox({
  value,
  onChange,
  placeholder,
}: {
  value: string
  onChange: (s: string) => void
  placeholder: string
}) {
  return (
    <div className="search">
      <Search size={20} />
      <input
        type="search"
        aria-label={placeholder}
        placeholder={placeholder}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
      {value && (
        <button
          className="icon"
          aria-label="검색어 지우기"
          onClick={() => onChange('')}
        >
          <X size={17} />
        </button>
      )}
    </div>
  )
}
export function useDebounce(value: string) {
  const [q, set] = useState(value)
  useEffect(() => {
    const t = setTimeout(() => set(value), 180)
    return () => clearTimeout(t)
  }, [value])
  return q
}
export function usePage<T>(
  name: string,
  args: Record<string, unknown>,
  cursorKey: string,
  getCursor: (t: T) => number,
  version: number,
) {
  const [rows, setRows] = useState<T[]>([]),
    [more, setMore] = useState(false),
    [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true),
    [error, setError] = useState('')
  const gen = useRef(0),
    busy = useRef(false),
    cursor = useRef<number | null>(null)
  const signature = JSON.stringify(args)
  async function read(append: boolean) {
    if (append && busy.current) return
    const g = ++gen.current
    busy.current = true
    setLoading(true)
    setError('')
    if (!append) {
      setRows([])
      setMore(false)
      setTotal(0)
      cursor.current = null
    }
    try {
      const data = await rpc<Page<T>>(name, {
        ...args,
        ...(append ? { [cursorKey]: cursor.current } : {}),
      })
      if (g !== gen.current) return
      setRows((prev) => (append ? [...prev, ...data.rows] : data.rows))
      setMore(data.more)
      setTotal(data.total ?? 0)
      if (data.rows.length) cursor.current = getCursor(data.rows.at(-1)!)
    } catch (e) {
      if (g === gen.current) setError(message(e))
    } finally {
      if (g === gen.current) {
        busy.current = false
        setLoading(false)
      }
    }
  }
  useEffect(() => {
    void read(false)
    return () => {
      gen.current++
    }
  }, [name, signature, version])
  return {
    rows,
    more,
    total,
    loading,
    error,
    next: () => read(true),
    reload: () => read(false),
  }
}
export function Status({ children }: { children: React.ReactNode }) {
  return (
    <div className="status" role="status">
      {children}
    </div>
  )
}
export function Empty({ title, text }: { title: string; text?: string }) {
  return (
    <div className="empty">
      <PackageOpen size={30} strokeWidth={1.4} />
      <strong>{title}</strong>
      {text && <span>{text}</span>}
    </div>
  )
}
export function Refresh({ onClick }: { onClick: () => void }) {
  return (
    <button className="quiet refresh" onClick={onClick}>
      <RefreshCw size={15} />
      새로고침
    </button>
  )
}
export function PageEnd({
  page,
}: {
  page: {
    error: string
    loading: boolean
    more: boolean
    rows: unknown[]
    next: () => void
    reload: () => void
  }
}) {
  return (
    <>
      {page.loading && <Status>불러오는 중…</Status>}
      {page.error && (
        <Status>
          {page.error}{' '}
          <button
            className="textbtn"
            onClick={page.rows.length ? page.next : page.reload}
          >
            다시 시도
          </button>
        </Status>
      )}
      {!page.error && !page.loading && page.more && (
        <button className="more quiet" onClick={page.next}>
          더 보기 <ChevronDown size={16} />
        </button>
      )}
    </>
  )
}
const dateFormat = new Intl.DateTimeFormat('ko-KR', {
  timeZone: 'Asia/Seoul',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hourCycle: 'h23',
})
export function History({
  itemId,
  query = '',
  kind = '',
  version,
}: {
  itemId?: string
  query?: string
  kind?: string
  version: number
}) {
  const p = usePage<Entry>(
    'wm_history',
    { p_item: itemId ?? null, p_query: query, p_kind: kind },
    'p_before',
    (x) => x.id,
    version,
  )
  return (
    <>
      <div className="entries">
        {p.rows.map((r) => (
          <article key={r.id} className="entry">
            <div className="entry-top">
              <span className="entry-kind">{operation[r.kind]}</span>
              <time dateTime={r.created_at}>
                {dateFormat.format(new Date(r.created_at))}
              </time>
            </div>
            {!itemId && <strong className="entry-name">{r.name}</strong>}
            <div className="entry-amount">
              {r.kind === 'opening'
                ? '시작 수량'
                : r.kind === 'count'
                  ? '실사 수량'
                  : operation[r.kind]}{' '}
              <b>{quantity(r.amount)}</b>
              {r.kind !== 'opening' && (
                <span className="transition">
                  {quantity(r.before_qty)} → {quantity(r.after_qty)}
                </span>
              )}
            </div>
            <div className="byline">
              {r.actor_name} · {r.source === 'manual' ? '수동' : '엑셀'}
            </div>
            {r.memo && <p className="memo">{r.memo}</p>}
          </article>
        ))}
      </div>
      {!p.loading && !p.error && !p.rows.length && (
        <Empty title="표시할 기록이 없습니다" />
      )}
      <PageEnd page={p} />
    </>
  )
}
