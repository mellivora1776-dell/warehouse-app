"""Read the final warehouse workbook and independently reconcile both inventory sheets."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
from openpyxl import load_workbook


def require(valid, message):
    if not valid:
        raise ValueError(message)


def total(values, where):
    require(all(q is None or type(q) is int and 0 <= q <= 2147483647 for q in values), f'{where} 수량 오류')
    known = [q for q in values if q is not None]
    require(not known or len(known) == len(values), f'{where} 일부 수량이 미확인입니다. 원본 확인이 필요합니다.')
    return sum(known) if known else None


def extract(path):
    wb = load_workbook(path, data_only=False)
    cached = load_workbook(path, data_only=True)
    ws = wb['품목별 재고']
    racks = wb['랙별배치표']
    require(list(next(ws.values)) == ['품목명', '재고수량'], '품목별 재고 열이 변경됐습니다.')
    require(list(next(racks.values)) == ['정렬번호', '랙 위치', '품목명', '재고수량'], '랙별배치표 열이 변경됐습니다.')
    source = defaultdict(list)
    for row, (_, rack, name, qty) in enumerate(list(racks.values)[1:], 2):
        if name is None:
            require(qty is None, f'랙별배치표 {row}행에 품목 없는 수량이 있습니다.')
            continue
        source[name].append((rack, qty))
    items, keys, expected = [], set(), {}
    current = None
    for row, (name, formula) in enumerate(list(ws.values)[1:], 2):
        # The summary's own SUMIFS criterion is the source key, including
        # alternate display spelling. Never match on a normalized product code.
        refs = set(re.findall(r'\$C\$2:\$C\$1000,"([^"]+)"', formula or ''))
        require(len(refs) == 1 and refs <= source.keys(), f'품목별 재고 B{row} 품목 참조 오류')
        key = next(iter(refs))
        qty = cached[ws.title].cell(row, 2).value
        if name.startswith('\u3000'):
            location = name[1:]
            require(current == key and location in expected, f'{row}행 위치 참조 오류')
            require(qty == expected.pop(location), f'{row}행 랙 수량 불일치')
            items[-1]['racks'].append(location)
            continue
        require(not expected and key not in keys, f'{row}행 앞의 위치 누락 또는 품목 중복')
        keys.add(key)
        current = key
        details = source[key]
        require(qty == total([n for _, n in details], name), f'{row}행 합계 불일치')
        locations = defaultdict(list)
        for rack, n in details:
            if rack is not None:
                locations[rack].append(n)
        expected = {rack: total(values, rack) for rack, values in locations.items()}
        items.append({'name': name, 'qty': qty, 'racks': []})
    require(not expected and keys == source.keys(), '표시 목록과 배치표 간 누락이 있습니다.')
    return items


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('xlsx', type=Path)
    parser.add_argument('--output', type=Path, help='비공개 작업 디렉터리의 파일 접두사')
    args = parser.parse_args()
    records = extract(args.xlsx)
    digest = hashlib.sha256(args.xlsx.read_bytes()).hexdigest()
    print(f"품목 {len(records)} / 0 재고 {sum(r['qty']==0 for r in records)} / 미확인 {sum(r['qty'] is None for r in records)} / 위치 미등록 {sum(not r['racks'] for r in records)} / 다중 랙 {sum(len(r['racks'])>1 for r in records)}")
    print('SHA-256', digest)
    if args.output:
        data = json.dumps(records, ensure_ascii=False)
        def quote(s):
            return "'" + s.replace("'", "''") + "'"
        sql = "begin;\nset local standard_conforming_strings=on;\nselect warehouse_master.stage(" + ','.join(map(quote, [digest, args.xlsx.name, data])) + "::jsonb);\ncommit;"
        args.output.with_suffix('.stage.sql').write_text(sql, encoding='utf-8')
        args.output.with_suffix('.audit.json').write_text(data, encoding='utf-8')
