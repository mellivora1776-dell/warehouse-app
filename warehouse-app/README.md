# 재고 마스터

직원은 PIN으로 로그인해 재고, 위치, 변경 기록을 조회합니다. 관리자는 품목 상세에서 입고·출고·실사를 저장하고 **직원 권한**에서 조회용 PIN을 발급하거나 해제할 수 있습니다. 각 PIN은 8자리이며 앞자리 0도 입력합니다.

## 실행과 배포

Node.js 24에서 `npm ci`, `npm run build`를 실행합니다. Vercel 프로젝트의 앱 디렉터리는 `warehouse-app`입니다. 브라우저는 `VITE_SUPABASE_URL`과 `VITE_SUPABASE_PUBLISHABLE_KEY`를 사용합니다. Vercel Function `api/pin.js`에는 서버 전용 `SUPABASE_SERVICE_ROLE_KEY`가 필요합니다. 이 키를 VITE 변수에 넣지 마세요. 로컬 전체 앱은 Vercel CLI의 `vercel dev`로 실행합니다.

## 운영

- PIN은 Supabase의 비공개 스키마에서 검증합니다. 로그인 서버가 Supabase Auth 세션을 발급합니다. 사용자의 이메일, 본인확인, 메일 발송은 필요하지 않습니다.
- 직원 PIN은 관리자가 발급 직후 한 번 확인해 해당 직원에게 전달합니다. **권한 해제**를 누르면 이미 로그인한 직원도 다음 조회부터 거부됩니다.
- 분실한 직원 PIN은 해제 후 새로 발급합니다. 관리자 PIN 복구는 프로젝트 소유자가 SQL Editor에서 아래 쿼리를 실행합니다. 사용 중인 관리자 세션도 종료하려면 대시보드에서 해당 Auth 사용자의 세션을 취소하세요.

```sql
do $$ begin
  if (select count(*) from warehouse_master.members where role='admin') <> 1 then
    raise exception '단일 관리자 계정을 확인해 주세요.';
  end if;
end $$;
with generated as materialized (
 select lpad(((('x'||encode(extensions.gen_random_bytes(4),'hex'))::bit(32)::bigint)%100000000)::text,8,'0') as pin
)
update warehouse_master.members m set pin_digest=warehouse_master.pin_digest(g.pin)
from generated g where role='admin' returning g.pin;
```

## 새 데이터베이스에 처음 설정할 때

1. Supabase SQL Editor에서 `supabase/01_schema.sql`, `02_import.sql`, `03_pin.sql` 순서로 한 번 실행합니다. 운영 프로젝트에는 이미 적용된 스크립트를 재실행할 필요가 없습니다.
2. 관리자의 비공개 작업 폴더에서 `python -m pip install -r tools/requirements.txt` 후 `python tools/workbook.py "품목별_재고현황.xlsx" --output /비공개경로/opening`을 실행합니다. 품목별 시트의 표시 이름·정렬·합계 수식을 읽고, 수식의 품명 참조를 따라 랙별배치표의 수량·모든 위치를 독립 대조합니다. 서로 불일치하면 중단합니다.
3. 생성한 `.stage.sql`을 SQL Editor에서 실행해 비활성 상태로 적재합니다. `.audit.json`과 적재된 품목 순서·수량·위치를 대조합니다. 확인 후 `select warehouse_master.activate('검증한 파일의 SHA-256');`으로 전환합니다. 같은 파일의 재활성화는 수량을 초기화하지 않습니다.
4. 새 데이터베이스에서는 `select warehouse_master.issue('관리자','admin');`으로 첫 PIN을 발급합니다. 관리자 한 명만 등록할 수 있습니다. 운영 PIN, 엑셀, 적재 SQL과 대조 결과는 공개 저장소에 올리지 않습니다.

입고·출고·실사는 `wm_change` 하나로 처리합니다. 행 잠금, 요청 UUID, 품목 버전으로 재시도와 동시 입력을 처리하며 수량 변경과 이력 추가는 한 트랜잭션입니다. 시작 수량은 `opening/excel`, 관리자가 등록한 기록은 `manual`입니다. 랙 위치는 품목을 찾기 위한 정보이며 랙별 잔량을 계산하지 않습니다.

## 검증

`npm test`로 수량 미리보기 검증을 실행합니다. 인수 검증에는 별도 PostgreSQL, Supabase Auth, PostgREST 환경과 검증 전용 데이터를 사용했습니다. 관리자의 320px 화면과 직원의 1280px 화면을 분리한 브라우저 세션으로 출고 10→7, 두 번 저장, 실사 7→5, 새로고침, 이력 필터와 가로 넘침을 확인했습니다.

로그인 사진은 [Unsplash 창고 사진](https://images.unsplash.com/photo-1586528116311-ad8dd3c8310d)입니다.
