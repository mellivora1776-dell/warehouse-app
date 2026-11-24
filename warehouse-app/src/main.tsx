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
import {
  Brand,
  SearchBox,
  Status,
  Refresh,
  Empty,
  PageEnd,
  usePage,
  useDebounce,
} from './ui'
import { Detail } from './Detail'
import { Staff } from './Staff'
import { Daily, Picking } from './workflow/Day'
import { Intake } from './workflow/Intake'
import { Ledger } from './workflow/Ledger'
import { today } from './workflow/model'
import { Sheet } from './workflow/shared'
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
  const p = usePage<Item>(
    'wm_items',
    { p_query: q },
    'p_after',
    (x) => x.ordinal,
    version,
  )
  return (
    <>
      <div className="title-row">
        <h1>재고 조회</h1>
        <Refresh onClick={p.reload} />
      </div>
      <SearchBox
        value={search}
        onChange={setSearch}
        placeholder="품번, 품목명 또는 랙 위치 검색"
      />
      <div className="list-meta">
        <span>
          {q ? '검색 결과' : '전체 품목'}{' '}
          <b>
            {p.loading && !p.rows.length
              ? '…'
              : p.total.toLocaleString('ko-KR')}
          </b>
        </span>
        <span>
          <ListOrdered size={15} />
          엑셀 순서
        </span>
      </div>
      <div className="stock-list">
        <div className="table-head">
          <span>품목명</span>
          <span>현재고</span>
        </div>
        {p.rows.map((r) => (
          <button key={r.id} className="stock-row" onClick={() => open(r.id)}>
            <span className="item-name">
              {r.name}
              {(r.spec || (r.sku && r.sku !== r.name)) && (
                <small className="sku-caption">
                  {[r.sku !== r.name ? r.sku : null, r.spec]
                    .filter(Boolean)
                    .join(' · ')}
                </small>
              )}
            </span>
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
      {!p.loading && !p.error && !p.rows.length && (
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
      <PageEnd page={p} />
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
    [openDays, setOpenDays] = useState<string[]>([])
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
  }, [role])
  const menu = [
    ['stock', '재고 조회', Boxes],
    ['picking', '피킹리스트', ListChecks],
    ['daily', '일일 마감', ClipboardCheck],
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
                    setSection(String(id))
                    window.scrollTo(0, 0)
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
          <Daily day={day} setDay={setDay} admin={role === 'admin'} />
        ) : section === 'picking' ? (
          <Picking day={day} setDay={setDay} admin={role === 'admin'} />
        ) : section === 'intake' && role === 'admin' ? (
          <Intake day={day} setDay={setDay} />
        ) : (
          <Ledger
            key={section}
            version={ver}
            sales={section === 'sales'}
            admin={role === 'admin'}
          />
        )}
      </main>
      {openDays.length > 0 && role === 'admin' && (
        <Sheet title="미마감 내역" close={() => setOpenDays([])}>
          <h2>검토할 날짜</h2>
          {openDays.map((d) => (
            <button
              key={d}
              className="issue-row"
              onClick={() => {
                setDay(d)
                go('daily')
                setOpenDays([])
              }}
            >
              {d}
              <ChevronRight size={16} />
            </button>
          ))}
          <button className="quiet close-later" onClick={() => setOpenDays([])}>
            나중에 확인
          </button>
        </Sheet>
      )}
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
