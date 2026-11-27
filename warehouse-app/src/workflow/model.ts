export const categoryLabels = {
  production_in: '생산입고',
  production_out: '생산출고',
  sale: '영업출고',
  return: '반품',
  as: 'AS',
  in: '이전 입고',
  out: '이전 출고',
  count: '실사',
  opening: '시작 재고',
} as const
export type Category = keyof typeof categoryLabels
export const methods = [
  '직납',
  '화물',
  '방문',
  '퀵',
  '퀵·용차',
  '용차',
] as const
export const decisions = {
  pending: '미검토',
  ready: '승인 대상',
  hold: '보류',
  exclude: '제외',
} as const
export const statuses: Record<string, string> = {
  unlinked: '건 식별 필요',
  current: '현재 지시서',
  previous: '이전 버전',
  reconcile: '원승인 대조 필요',
  dismissed: '제외',
  reconciled: '대조 완료',
}
export const origins: Record<string, string> = {
  manual: '수기',
  chatgpt: 'ChatGPT 분석',
  correction: '정정',
  excel: '엑셀',
}
export type Decision = keyof typeof decisions
export type Row = {
  id: string
  document_id: string
  pos: number
  line_key: string
  raw_name: string
  raw_sku: string
  spec: string
  read_qty: number | null
  final_qty: number | null
  item_id: string | null
  method: string | null
  customer: string
  decision: Decision
  reason: string
  picked: boolean
  pick_changed: boolean
  rev: number
  external_id: string
  case_id: string | null
  case_key: string | null
  work_day: string
  category: Category
  direction: number
  origin: string
  edition: number | null
  version: number
  doc_status: string
  corrects_entry: number | null
  related_document: string | null
  name: string | null
  qty: number | null
  racks: string[] | null
  revision: number | null
  sku: string | null
  item_spec: string | null
  entry_id: number | null
  batch_id: string | null
  confidence?: number | null
  read_reason?: string | null
  resolution?:
    | 'matched'
    | 'unlinked'
    | 'order_candidate'
    | 'pick_only'
    | 'reference'
    | 'conflict'
  stock_managed?: boolean
  pick_required?: boolean
  stock_qty?: number | null
  pick_qty?: number | null
  standard_name?: string
  standard_spec?: string
  match_basis?: string
  variant?: string
  variant_key?: string
  product_kind?: string
  context?: string
  requester?: string
  remarks?: string
  packing?: string
  method_raw?: string | null
  posted_before?: number | null
  posted_after?: number | null
  display_name?: string
  opening_question?: string | null
  opening_balance?: number | null
  opening_review?: number | null
  check_reason?: string
  related_hold?: boolean
  record_rev?: number
  record_deleted?: boolean
  record_qty?: number | null
  record_customer?: string
  record_method_raw?: string | null
  analysis_reason?: string
}
export type Issue = {
  id: string
  external_id: string
  status: string
  issue: string
  deferred: boolean
  customer: string
  version: number
  work_day: string
  case_id: string | null
  suspected_case: string | null
}
export type Batch = {
  id: string
  sequence: number
  approved_at: string
  actor: string
  lines: number
}
export type DayData = {
  rows: Row[]
  issues: Issue[]
  batches: Batch[]
  stamp: string
  removed: {
    doc: string
    external_id: string
    name: string
    qty: number | null
  }[]
}
export type SKU = {
  display_name: string
  id: string
  name: string
  qty: number | null
  racks: string[]
  sku: string
  spec: string
  made_to_order: boolean
}
export type Movement = {
  id: number
  item_id: string
  name: string
  sku: string
  spec: string
  kind: string
  amount: number | null
  before_qty: number | null
  after_qty: number | null
  actor_name: string
  memo: string
  created_at: string
  work_day: string
  category: Category
  origin: string
  customer: string | null
  method: string | null
  read_qty: number | null
  final_qty: number | null
  external_id: string | null
  document_id: string | null
  edition: number | null
  version: number | null
  batch_id: string | null
  sequence: number | null
  approved_at: string | null
  corrects_entry: number | null
  related_document: string | null
  method_raw?: string | null
  display_name: string
  record_rev: number
  record_deleted: boolean
  record_qty: number | null
  record_signed_qty: number | null
  record_customer: string | null
  record_method: string | null
  record_method_raw: string | null
  signed_qty: number | null
}
export type DocVersion = {
  id: string
  customer: string
  external_id: string
  version: number
  edition: number | null
  status: string
  work_day: string
  document_type: string
  origin: string
  submitted_by: string
  created_at: string
  source_time?: string
  source?: { text?: string; kind?: string; name?: string }
  has_file: boolean
  lines: Row[]
}
export type DocInfo = {
  selected: string
  versions: DocVersion[]
  audit: {
    id: number
    line_id: string | null
    action: string
    actor: string
    happened_at: string
    before_value: any
    after_value: any
  }[]
  suggestions: {
    id: string
    external_id: string
    customer: string
    work_day: string
  }[]
  settled: Movement[]
}
export function today() {
  return new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Seoul' }).format(
    new Date(),
  )
}
export function timeKo(value: string) {
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).format(new Date(value))
}
export const qty = (q: number | null | undefined) =>
  q == null ? '미확인' : q.toLocaleString('ko-KR') + '개'
export const rowLabel = (
  r: Pick<Row, 'category' | 'customer' | 'method' | 'method_raw' | 'requester'>,
) =>
  r.category === 'sale'
    ? [r.customer || '거래처 미확인', methodLabel(r) || '방식 미확인'].join(
        ' · ',
      )
    : categoryLabels[r.category]
export const standardName = (r: Row) =>
  r.display_name || r.name || r.standard_name || r.raw_name
export const methodLabel = (r: {
  method: string | null
  method_raw?: string | null
}) =>
  r.method_raw?.includes('용차') && r.method === '퀵·용차'
    ? r.method_raw
    : r.method
export const pickCount = (r: Row) =>
  r.pick_qty === undefined ? r.final_qty : r.pick_qty
export const stockCount = (r: Row) =>
  r.stock_managed === false
    ? 0
    : r.stock_qty === undefined
      ? r.final_qty
      : r.stock_qty
export const completed = (r: Row) => Boolean(r.batch_id || r.entry_id)
export function attention(r: Row) {
  if (completed(r) || r.decision === 'exclude' || r.decision === 'hold')
    return ''
  if (r.check_reason !== undefined) return r.check_reason
  if (r.stock_managed !== false && !r.item_id)
    return r.resolution === 'order_candidate'
      ? '주문품 SKU 등록 필요'
      : '품목 연결 필요'
  if (
    r.final_qty == null ||
    stockCount(r) == null ||
    (r.pick_required && pickCount(r) == null)
  )
    return '수량 확인 필요'
  if (r.category === 'sale' && (!r.method || !r.customer))
    return !r.method ? '출고 방식 확인 필요' : '거래처 확인 필요'
  if (r.stock_managed !== false && r.qty == null) return '현재고 미입력'
  return ''
}
export function planned(rows: Row[]) {
  let incoming = 0,
    outgoing = 0
  for (const r of rows) {
    if (
      completed(r) ||
      r.related_hold ||
      r.decision === 'hold' ||
      r.decision === 'exclude'
    )
      continue
    if (r.direction > 0) incoming += stockCount(r) ?? 0
    else outgoing += stockCount(r) ?? 0
  }
  return { incoming, outgoing, net: incoming - outgoing }
}
export function grouped(rows: Row[]) {
  const groups = new Map<string, Row[]>()
  for (const r of rows) {
    const key =
      r.item_id ??
      JSON.stringify([
        r.resolution,
        r.variant_key || r.standard_name || r.raw_name,
        r.standard_spec || r.spec,
      ])
    const group = groups.get(key) ?? []
    group.push(r)
    groups.set(key, group)
  }
  return [...groups.values()]
}
