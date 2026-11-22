export const operation = {
  in: '입고',
  out: '출고',
  count: '실사 조정',
  opening: '시작 재고',
}
export const quantity = (n) =>
  n === null ? '미확인' : n.toLocaleString('ko-KR') + '대'
export function preview(qty, kind, input) {
  if (qty === null && kind !== 'count')
    return { error: '먼저 실사에서 직접 센 최종 수량을 입력해 주세요.' }
  if (input === '') return { empty: true }
  if (!/^\d+$/.test(input)) return { error: '정수로 입력해 주세요.' }
  const n = Number(input)
  if (n < (kind === 'count' ? 0 : 1))
    return { error: '입출고 수량은 1대 이상이어야 합니다.' }
  if (kind === 'out' && n > qty)
    return {
      error: `현재고 ${quantity(qty)} · ${quantity(n - qty)} 부족합니다.`,
    }
  const after = kind === 'count' ? n : kind === 'in' ? qty + n : qty - n
  if (after > 2147483647 || n > 2147483647)
    return { error: '수량은 2,147,483,647대까지 입력할 수 있습니다.' }
  return { after, amount: n }
}
