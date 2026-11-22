import { createClient } from '@supabase/supabase-js'
export type Kind = 'in' | 'out' | 'count'
export type Item = {
  id: string
  name: string
  qty: number | null
  ordinal: number
}
export type Detail = Pick<Item, 'id' | 'name' | 'qty'> & {
  revision: number
  racks: string[]
}
export type Entry = {
  id: number
  created_at: string
  name: string
  item_id: string
  kind: Kind | 'opening'
  amount: number | null
  before_qty: number | null
  after_qty: number | null
  actor_name: string
  memo: string
  source: string
}
export type Page<T> = { rows: T[]; more: boolean; total?: number }
export type Change = {
  p_item: string
  p_kind: Kind
  p_amount: number
  p_memo: string
  p_revision: number
  p_request: string
}
const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
export const db = url && key ? createClient(url, key) : null
export class DbError extends Error {
  constructor(
    public code: string,
    public serverMessage: string,
    public detail: string | null = null,
  ) {
    super(serverMessage)
  }
}
export async function rpc<T>(
  name: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  if (!db) throw new Error('Supabase 연결 설정을 확인해 주세요.')
  const { data, error } = await db.rpc(name, args)
  if (error) throw new DbError(error.code, error.message, error.details)
  return data as T
}
export function message(err: unknown): string {
  if (err instanceof DbError) {
    const msg: Record<string, string> = {
      WM_APPROVAL:
        '승인 대기 중인 계정입니다. 관리자에게 조회 권한을 요청해 주세요.',
      WM_READ_ONLY: '조회 전용 계정입니다.',
      WM_STALE:
        '다른 기기에서 수량을 변경했습니다. 최신 수량을 확인하고 다시 입력해 주세요.',
      WM_UNKNOWN: '먼저 실사 수량을 등록해 주세요.',
      WM_LIMIT: '저장할 수 있는 최대 수량을 넘었습니다.',
      WM_INVALID: '입력한 수량이나 메모를 확인해 주세요.',
      WM_NOT_FOUND: '현재 목록에서 품목을 찾을 수 없습니다.',
      WM_REQUEST_MISMATCH:
        '저장 요청이 이전 기록과 다릅니다. 변경 기록을 확인해 주세요.',
    }
    if (err.serverMessage === 'WM_SHORT') {
      try {
        const d = JSON.parse(err.detail || '')
        return `현재고 ${d.current}대 · ${d.short}대 부족합니다.`
      } catch {
        return '현재고가 부족합니다.'
      }
    }
    if (msg[err.serverMessage]) return msg[err.serverMessage]
  }
  return '데이터를 확인할 수 없습니다. 연결 상태를 확인하고 다시 시도해 주세요.'
}
