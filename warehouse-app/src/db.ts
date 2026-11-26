import { createClient } from '@supabase/supabase-js'
export type Kind = 'in' | 'out' | 'count'
export type Item = {
  id: string
  name: string
  qty: number | null
  sku?: string | null
  spec?: string | null
  display_name: string
  racks: string[]
  ordinal: number
}
export type Detail = Pick<
  Item,
  'id' | 'name' | 'qty' | 'sku' | 'spec' | 'display_name'
> & {
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
    Object.assign(msg, {
      WM3_PREFLIGHT_CHANGED:
        '마스터 또는 문서 상태가 바뀌었습니다. 다시 사전 검증해 주세요.',
      WM3_RECEIPT_MISMATCH: '사전 검증과 실제 결과가 달라 등록을 중단했습니다.',
      WM3_BLOCKED:
        '입력 내용이 현장 규칙과 충돌합니다. 사전 검증 결과를 확인하세요.',
      WM3_CANCEL_FIRST: '대체할 문서의 취소 상태를 확인하세요.',
      WM3_CORRECTION_ONLY:
        '이미 승인된 건입니다. 변경 기록에서 원승인과 대조하세요.',
      WM4_RECORD_ONLY:
        '품목 변경 기록에서 수정하세요. 현재고 조정은 실사에서 처리합니다.',
      WM4_REPLACED:
        '이 취소 건에는 유효한 대체 문서가 있습니다. 기존 건의 최신 버전을 확인하세요.',
      WM3_VARIANT: '기본·주문 구분, 모터·완성품과 사양을 확인하세요.',
      WM3_ALIAS_CONFLICT: '같은 문맥에 다른 별칭이 이미 있습니다.',
      WM2_FILE_USED: '이 파일은 이미 다른 문서에 연결되어 있습니다.',
      WM2_USE_CLOSE: '입출고는 일일 마감에서 승인해 주세요.',
      WM2_DOCUMENT_CONFLICT:
        '같은 문서 ID로 다른 내용이 등록돼 있습니다. 수정본에는 새 문서 ID와 이전 문서 ID를 입력해 주세요.',
      WM2_MANUAL_ONLY: '반품과 AS는 관리자 수기 전표로 등록해 주세요.',
      WM2_EMPTY: '새로 마감할 거래 또는 검토 내용이 없습니다.',
      WM2_DIRECTION: '재고가 늘었는지 줄었는지 선택해 주세요.',
      WM2_REVIEW_FIRST:
        '미검토 거래와 수정본 후보를 확인하거나 보류·제외해 주세요.',
      WM2_LINE: '행 식별자, 원문 품명, 수량이나 신뢰도를 확인해 주세요.',
      WM2_METHOD:
        '영업출고 방식은 직납·화물·방문·퀵·용차 중에서 선택해 주세요.',
      WM2_FORMAT: '문서 형식, 날짜, 버전, 파일 지문을 확인해 주세요.',
      WM2_INCOMPLETE: 'SKU, 수량, 영업출고 거래처와 방식을 확인해 주세요.',
      WM2_REASON: '보류·제외 또는 정정 사유를 입력해 주세요.',
      WM2_SKU_EXISTS:
        '같은 SKU 또는 이름과 사양이 등록돼 있습니다. 기존 품목을 검색해 연결해 주세요.',
      WM_STALE:
        '다른 작업으로 자료 또는 재고가 바뀌었습니다. 최신 화면에서 다시 검토해 주세요.',
    })
    if (err.code === '23505')
      return '중복된 식별자가 있습니다. 문서와 행 ID를 확인해 주세요.'
    if (['22003', '22P02', '22007', '22008', '23514'].includes(err.code))
      return '날짜, 정수 수량 또는 입력 형식을 확인해 주세요.'
    if (msg[err.serverMessage]) return msg[err.serverMessage]
  }
  return '데이터를 확인할 수 없습니다. 연결 상태를 확인하고 다시 시도해 주세요.'
}
