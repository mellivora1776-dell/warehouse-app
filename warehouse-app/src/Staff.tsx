import { useEffect, useState } from 'react'
import { rpc, message } from './db'
import { Status } from './ui'

export function Staff() {
  const [rows, setRows] = useState<{ id: string; name: string }[]>([]),
    [name, setName] = useState(''),
    [pin, setPin] = useState(''),
    [error, setError] = useState(''),
    [busy, setBusy] = useState(false)
  async function load() {
    try {
      setRows(await rpc('wm_staff_list'))
    } catch (e) {
      setError(message(e))
    }
  }
  useEffect(() => {
    void load()
  }, [])
  async function issue(e: React.FormEvent) {
    e.preventDefault()
    if (busy || !name.trim()) return
    setBusy(true)
    setError('')
    setPin('')
    try {
      setPin(await rpc('wm_issue_staff', { p_name: name.trim() }))
      setName('')
      await load()
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }
  async function revoke(id: string, name: string) {
    if (busy || !window.confirm(name + '의 조회 권한을 해제할까요?')) return
    setBusy(true)
    setError('')
    try {
      await rpc('wm_revoke_staff', { p_id: id })
      setPin('')
      await load()
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <>
      <div className="title-row">
        <h1>직원 권한</h1>
      </div>
      <form className="staff-form" onSubmit={issue}>
        <label>
          직원 이름
          <input
            required
            value={name}
            maxLength={60}
            onChange={(e) => setName(e.target.value)}
            placeholder="직원 이름 또는 구분명"
          />
        </label>
        <button className="primary" disabled={busy || !name.trim()}>
          조회용 PIN 발급
        </button>
      </form>
      {pin && (
        <Status>
          새 직원 PIN <b className="issued-pin">{pin}</b>직원에게 전달해 주세요.
          이 번호는 발급할 때 한 번 표시됩니다.{' '}
          <button className="textbtn" onClick={() => setPin('')}>
            닫기
          </button>
        </Status>
      )}
      {error && (
        <Status>
          {error}{' '}
          <button className="textbtn" onClick={load}>
            다시 확인
          </button>
        </Status>
      )}
      <div className="section-title">
        <h3>조회 권한이 있는 직원</h3>
      </div>
      {rows.length ? (
        rows.map((r) => (
          <div className="staff-row" key={r.id}>
            <b>{r.name}</b>
            <button
              disabled={busy}
              className="quiet"
              onClick={() => revoke(r.id, r.name)}
            >
              권한 해제
            </button>
          </div>
        ))
      ) : (
        <Status>등록된 직원이 없습니다.</Status>
      )}
    </>
  )
}
