import { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import type { User } from '@supabase/supabase-js'
import {
  Boxes,
  History as HistoryIcon,
  ChevronRight,
  UserRound,
  LogOut,
  ShieldCheck,
  LockKeyhole,
  ListOrdered,
  ClipboardCheck,
  Truck,
  Files,
  ListChecks,
} from 'lucide-react'
import { db, rpc, message, type Item } from './db'
import { Brand, SearchBox, Status, Refresh, Empty, useDebounce } from './ui'
import { Detail } from './Detail'
import { Staff } from './Staff'
import { Daily, Picking } from './workflow/Day'
import { Intake } from './workflow/Intake'
import { Ledger } from './workflow/Ledger'
import { today } from './workflow/model'
import { useData, Loading } from './workflow/shared'
import './style.css'
import './workflow/workflow.css'

function Login() {
  const [pin, setPin] = useState(''),
    [error, setError] = useState(''),
    [busy, setBusy] = useState(false)
  async function login(e: React.FormEvent) {
    e.preventDefault()
    if (busy || !db) return
    setBusy(true)
    setError('')
    try {
      const response = await fetch('/api/pin', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pin }),
      })
      const body = await response.json()
      if (!response.ok) {
        setError(body.error || '로그인할 수 없습니다.')
        return
      }
      const session = await db.auth.setSession(body)
      if (session.error)
        setError('세션을 열지 못했습니다. 다시 로그인해 주세요.')
    } catch {
      setError('로그인 서버에 연결할 수 없습니다. 다시 시도해 주세요.')
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="login-page">
      <main className="login-panel">
        <Brand />
        <div className="login-form">
          <div className="login-symbol">
            <LockKeyhole size={23} />
          </div>
          <h1>PIN 로그인</h1>
          <p>발급받은 PIN으로 창고 재고를 확인하세요.</p>
          <form onSubmit={login}>
            <label>
              PIN 번호
              <input
                className="pin-input"
                type="password"
                inputMode="numeric"
                pattern="[0-9]{8}"
                minLength={8}
                maxLength={8}
                autoComplete="current-password"
                placeholder="숫자 8자리"
                required
                value={pin}
                onChange={(e) => setPin(e.target.value.replace(/[^0-9]/g, ''))}
              />
            </label>
            {(!db || error) && (
              <p role="alert" className="error">
                {error ||
                  'Supabase 연결 설정이 필요합니다. 사이트 관리자에게 문의해 주세요.'}
              </p>
            )}
            <button
              className="primary"
              disabled={!db || pin.length !== 8 || busy}
            >
              {busy ? '로그인 중…' : '로그인'}
            </button>
          </form>
          <p className="login-help">
            처음 이용하는 직원은 관리자에게 조회용 PIN을 요청하세요.
          </p>
        </div>
      </main>
      <aside className="login-photo" aria-hidden="true" />
    </div>
  )
}
const natural = new Intl.Collator('ko', { numeric: true })
function Inventory({
  version,
  open,
  ready,
}: {
  version: number
  open: (id: string) => void
  ready: boolean
}) {
  const [search, setSearch] = useState('')
  const q = useDebounce(search)
  const [sort, setSort] = useState('excel')
  const result = useData<Item[]>('wm4_catalog', { p_query: q }, version)
  const rows = [...(result.data ?? [])].sort((a, b) => {
    let order = 0
    if (sort === 'name') order = natural.compare(a.display_name, b.display_name)
    if (sort === 'few' || sort === 'many')
      order =
        a.qty == null
          ? Number(b.qty != null)
          : b.qty == null
            ? -1
            : (a.qty - b.qty) * (sort === 'few' ? 1 : -1)
    if (sort === 'rack') {
      const first = (r: Item) => [...r.racks].sort(natural.compare)[0]
      const x = first(a),
        y = first(b)
      order = x && y ? natural.compare(x, y) : Number(!x) - Number(!y)
    }
    return order || a.ordinal - b.ordinal
  })
  return (
    <>
      <div className="title-row">
        <h1>재고 조회</h1>
        <Refresh onClick={result.reload} />
      </div>
      <SearchBox
        value={search}
        onChange={setSearch}
        placeholder="품번, 품목명 또는 랙 위치 검색"
      />
      <div className="list-meta">
        <span>
          {q ? '검색 결과' : '전체 품목'}{' '}
          <b>{!result.data ? '…' : rows.length.toLocaleString('ko-KR')}</b>
        </span>
        <span>
          <ListOrdered size={15} />
          <select
            aria-label="재고 정렬"
            className="catalog-sort"
            value={sort}
            onChange={(e) => setSort(e.target.value)}
          >
            <option value="excel">엑셀 순서</option>
            <option value="name">품목명순</option>
            <option value="few">현재고 적은순</option>
            <option value="many">현재고 많은순</option>
            <option value="rack">랙 위치순</option>
          </select>
        </span>
      </div>
      <div className="stock-list">
        <div className="table-head">
          <span>품목명</span>
          <span>현재고</span>
        </div>
        {rows.map((r) => (
          <button key={r.id} className="stock-row" onClick={() => open(r.id)}>
            <span className="item-name">{r.display_name}</span>
            <span className={'qty ' + (r.qty === null ? 'unknown' : '')}>
              {r.qty === null ? (
                '미확인'
              ) : (
                <>
                  {r.qty.toLocaleString('ko-KR')}
                  <small>대</small>
                </>
              )}
            </span>
            <ChevronRight size={16} className="row-chevron" />
          </button>
        ))}
      </div>
      {result.data && !rows.length && (
        <Empty
          title={
            q
              ? '검색 결과가 없습니다'
              : ready
                ? '등록된 품목이 없습니다'
                : '시작 재고를 준비하고 있습니다'
          }
          text={q ? '다른 품번이나 랙 위치를 입력해 보세요.' : undefined}
        />
      )}
      {!result.data && <Loading error={result.error} retry={result.reload} />}
    </>
  )
}
function Home({ user }: { user: User }) {
  const [role, setRole] = useState(''),
    [label, setLabel] = useState(''),
    [ready, setReady] = useState(false),
    [error, setError] = useState(''),
    [check, setCheck] = useState(0)
  const [section, setSection] = useState('stock'),
    [selected, setSelected] = useState(''),
    [ver, setVer] = useState(0),
    [signError, setSignError] = useState('')
  useEffect(() => {
    let live = true
    setError('')
    rpc<{ role: string; ready: boolean; name: string }>('wm_profile')
      .then((p) => {
        if (live) {
          setRole(p.role)
          setLabel(p.name)
          setReady(p.ready)
        }
      })
      .catch((e) => {
        if (live) setError(message(e))
      })
    return () => {
      live = false
    }
  }, [user.id, check])
  const [day, setDay] = useState(today),
    [koreaDay, setKoreaDay] = useState(today)
  const [openDays, setOpenDays] = useState<string[]>([]),
    [menuRevision, setMenuRevision] = useState(0)
  const refreshDays = () => setMenuRevision((n) => n + 1)
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>
    function syncDate() {
      clearTimeout(timer)
      const now = Date.now()
      setKoreaDay(today())
      timer = setTimeout(
        syncDate,
        86400000 - ((now + 9 * 3600000) % 86400000) + 50,
      )
    }
    function onFocus() {
      syncDate()
      refreshDays()
    }
    syncDate()
    window.addEventListener('focus', onFocus)
    return () => {
      clearTimeout(timer)
      window.removeEventListener('focus', onFocus)
    }
  }, [])
  useEffect(() => {
    let active = true
    if (role === 'admin')
      rpc<string[]>('wm2_open_days')
        .then((d) => {
          if (active) setOpenDays(d)
        })
        .catch((e) => {
          if (active) setSignError(message(e))
        })
    return () => {
      active = false
    }
  }, [role, koreaDay, menuRevision, section, ver])
  const menu = [
    ['stock', '재고 조회', Boxes],
    ['picking', '피킹리스트', ListChecks],
    [
      'daily',
      role === 'admin' && openDays.length
        ? '일일 마감 · 미마감 ' + openDays.length + '일'
        : '일일 마감',
      ClipboardCheck,
    ],
    ['history', '입출고 기록', HistoryIcon],
    ['sales', '영업출고 조회', Truck],
    ...(role === 'admin'
      ? [
          ['intake', '분석 자료 등록', Files],
          ['staff', '직원 권한', ShieldCheck],
        ]
      : []),
  ]
  const go = (id: string) => {
    if (id === 'daily' && openDays.length && !openDays.includes(day))
      setDay(openDays.includes(koreaDay) ? koreaDay : openDays[0])
    setSection(id)
    window.scrollTo(0, 0)
  }
  async function logout() {
    const r = await db!.auth.signOut({ scope: 'local' })
    if (r.error) setSignError('로그아웃하지 못했습니다. 다시 시도해 주세요.')
  }
  return (
    <div className="shell">
      <a className="skip" href="#main">
        본문으로 이동
      </a>
      <aside className="sidebar">
        <div className="brand-row">
          <Brand />
          <button
            className="mobile-logout icon"
            onClick={logout}
            aria-label="로그아웃"
          >
            <LogOut size={19} />
          </button>
        </div>
        {role && (
          <nav aria-label="주 메뉴">
            {menu.map(([id, title, Icon]) => {
              const I = Icon as typeof Boxes
              return (
                <button
                  key={String(id)}
                  className={section === id ? 'current' : ''}
                  aria-current={section === id ? 'page' : undefined}
                  onClick={() => {
                    go(String(id))
                  }}
                >
                  <I size={19} />
                  {String(title)}
                </button>
              )
            })}
          </nav>
        )}
        {role && (
          <div className="mobile-worknav">
            <select
              aria-label="업무 메뉴"
              value={section}
              onChange={(e) => go(e.target.value)}
            >
              {menu.map(([id, title]) => (
                <option key={String(id)} value={String(id)}>
                  {String(title)}
                </option>
              ))}
            </select>
          </div>
        )}
        <div className="account">
          <div className="avatar">
            <UserRound size={18} />
          </div>
          <div>
            <b>
              {role === 'admin'
                ? '관리자'
                : role === 'staff'
                  ? '직원 · 조회 전용'
                  : '사용자'}
            </b>
            <span>{label}</span>
          </div>
          <button
            className="icon"
            title="로그아웃"
            aria-label="로그아웃"
            onClick={logout}
          >
            <LogOut size={17} />
          </button>
        </div>
      </aside>
      <main className="content" id="main">
        {signError && <Status>{signError}</Status>}
        {error ? (
          <Status>
            {error}{' '}
            <button className="textbtn" onClick={() => setCheck((x) => x + 1)}>
              다시 확인
            </button>
          </Status>
        ) : !role ? (
          <Status>계정 권한을 확인하는 중…</Status>
        ) : section === 'stock' ? (
          <Inventory version={ver} ready={ready} open={setSelected} />
        ) : section === 'staff' && role === 'admin' ? (
          <Staff />
        ) : section === 'daily' ? (
          <Daily
            koreaDay={koreaDay}
            openDays={openDays}
            changed={refreshDays}
            day={day}
            setDay={setDay}
            admin={role === 'admin'}
          />
        ) : section === 'picking' ? (
          <Picking koreaDay={koreaDay} admin={role === 'admin'} />
        ) : section === 'intake' && role === 'admin' ? (
          <Intake changed={refreshDays} day={day} setDay={setDay} />
        ) : (
          <Ledger
            key={section}
            version={ver}
            sales={section === 'sales'}
            admin={role === 'admin'}
          />
        )}
      </main>
      {selected && (
        <Detail
          key={selected}
          id={selected}
          admin={role === 'admin'}
          user={user.id}
          close={() => setSelected('')}
          saved={() => setVer((v) => v + 1)}
        />
      )}
    </div>
  )
}
function App() {
  const [user, setUser] = useState<User | null | undefined>(
    db ? undefined : null,
  )
  useEffect(() => {
    if (!db) return
    const { data } = db.auth.onAuthStateChange((_event, s) =>
      setUser(s?.user ?? null),
    )
    return () => data.subscription.unsubscribe()
  }, [])
  return user === undefined ? (
    <main className="boot">
      <Brand />
      <Status>로그인 상태를 확인하는 중…</Status>
    </main>
  ) : user ? (
    <Home key={user.id} user={user} />
  ) : (
    <Login />
  )
}
createRoot(document.getElementById('root')!).render(<App />)
