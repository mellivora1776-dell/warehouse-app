# 재고 마스터

직원은 PIN으로 로그인해 재고, 위치, 변경 기록을 조회합니다. 관리자는 품목 상세에서 입출고 후보를 등록하고 직접 센 실사를 확정합니다. **직원 권한**에서 조회용 PIN을 발급하거나 해제할 수 있습니다. 각 PIN은 8자리이며 앞자리 0도 입력합니다.

## v2 사용 순서

1. **자료 등록** — 일반 ChatGPT 대화 또는 프로젝트에 [분석 지침](https://warehouse-app-wine.vercel.app/warehouse-instructions.txt)을 추가합니다. 이 대화에 쓰기 가능한 Supabase SQL 도구가 연결돼 있으면 “이 지시서를 재고 마스터에 등록해줘”라고 요청합니다. 도구를 쓸 수 없으면 ChatGPT가 만든 JSON을 사이트의 **분석 자료 등록**에 붙여넣습니다. 파일 이름과 원문만 전달된 경우에는 관리자가 해당 문서 버전에 실제 원본을 추가할 수 있습니다.
2. **피킹리스트** — 선택한 날짜 전체를 랙 순으로 보고 개별 지시를 체크합니다. 거래처별·건별 보기와 피킹 전용 준비 수량도 지원합니다. 모든 랙은 찾기 위한 위치입니다. 수정 지시서가 들어오면 변경되거나 빠진 기피킹 품목을 확인합니다.
3. **일일 마감** — 날짜를 선택하고 품목 카드에서 확인이 필요한 거래부터 해결하거나 보류합니다. 연결된 정상 거래는 별도의 행별 검토 저장 없이 승인 대상이 됩니다. 수량, 거래처, 방식을 고치거나 보류·제외 사유를 남깁니다. SKU가 불명확하면 기존 품목을 찾거나 새 SKU와 사양을 확정합니다. 사용자가 이미 확정한 주문품은 접수 때 연결됩니다. 첫 거래 전 보유량만 모르는 품목은 해당 수량을 확인해 입력하거나 보류합니다.
4. **승인** — 품목별 거래를 확인한 뒤 하루를 한 번 승인합니다. 확인이 필요한 거래는 해결하거나 보류합니다. 승인 중 바뀐 자료는 다시 검토합니다. 늦게 발견한 거래는 같은 날짜의 다음 차수에서 승인합니다. 승인 후 지시가 바뀌면 근거 화면에서 지시와 실제 확정 수량을 대조하고 거래 기록의 수량을 수정하거나 삭제할 수 있습니다. 원승인과 현재고는 그대로 유지합니다.
5. **조회** — 재고 목록·품목 상세·입출고 기록·영업출고 조회에서 확정 결과를 확인합니다. 주문품이 0개이면 기본 목록에서 숨겨지며 검색과 이력 조회에는 남습니다.

수기 생산입고·생산출고·영업출고·반품·AS도 일일 마감에서 승인합니다. AS의 증가·감소는 실제 처리 방향에 따라 입고 또는 출고 화면에서 선택합니다. 직접 센 실사만 즉시 확정합니다. 직원은 재고, 처리 상태 및 확정 이력을 조회할 수 있습니다. 피킹 체크, 문서 원본, 거래 수정, 승인과 정정은 관리자 전용입니다.

## ChatGPT 연결

- 일반 ChatGPT에서 쓸 수 있는 도구는 대화/프로젝트의 앱 설정과 워크스페이스 권한에 따릅니다. 이미 관리용 Supabase SQL 도구가 연결된 경우 프로젝트 **ohkbqggcgersoscodimt**에서 `warehouse_master.preview_chatgpt`로 사전 검증한 뒤 `warehouse_master.import_chatgpt`로 미승인 자료를 접수합니다. 이 함수는 UTF-8 JSON의 표준 Base64 문자열을 받습니다. 관리자 PIN이나 서비스 키를 대화에 넣을 필요가 없습니다. 관리용 Supabase 연결의 전체 권한은 해당 연결 설정에 따릅니다.
- SQL 쓰기 도구가 없는 대화에서는 사이트에 JSON을 붙여넣거나 JSON 파일을 선택하세요. 원문, 사양, 실제 파일에서 확인된 근거를 보존합니다. 거래처와 날짜만 같고 건 식별이 불분명하면 전송 전에 확인합니다.
- 등록 전용 HTTP 연동에는 `POST /api/preflight`, `POST /api/intake`와 [OpenAPI 명세](https://warehouse-app-wine.vercel.app/warehouse-action.json)가 있습니다. 관리자 화면에서 발급한 Bearer 키는 접수 권한만 가지며 교체·해제할 수 있습니다. 서버가 발급 직후 한 번 키를 표시하고 DB에는 해시를 보관합니다. 전용 GPT를 사용하는 경우에만 이 명세를 GPT 작업으로 가져옵니다.
- 사이트에는 AI 인식 API 호출이나 AI 키가 없습니다. 분석은 사용자의 ChatGPT 환경에서 이루어집니다. 원본 파일은 관리자만 접근하는 Supabase Storage에 저장하며 실제 업로드와 연결이 확인된 경우 60초짜리 읽기 링크를 발급합니다.

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

## 기존 v1에서 v2로 전환

앱의 자동 배포는 DB를 시드하거나 마이그레이션하지 않습니다. 운영 전환 때 `supabase/04_workflow_v2.sql`을 v1 위에 **한 번만** 적용합니다. 기존 품목·수량·이력은 그대로 두고, 문서·버전, 검토 거래, 피킹, 추가 품목 사양, 마감·승인 연결, 감사 이력과 등록 키를 비공개 스키마에 추가합니다. 공개 RPC는 역할을 검증합니다. 기존 수량 계산 함수는 비공개 `warehouse_master.apply_stock_change`로 이동하며 마감과 직접 실사에서 함께 사용합니다. 기존 `public.wm_change`로 수기 입출고를 시도하면 마감 안내를 반환합니다.

각 날짜의 마감은 최신 검토 상태와 품목 버전을 다시 확인하고 품목 잠금을 취한 단일 트랜잭션으로 반영합니다. 문서 버전, 수불 행, 재시도 요청과 마감 차수에 각각 식별자가 있습니다. 이미 승인한 기록의 변경은 원승인을 참조하는 표시용 정정 이력으로 남습니다. 현재고 조정은 담당자가 별도로 실사를 입력할 때 반영합니다. 과거 차수의 검토표는 승인 당시 상태를 보존합니다.

기존 환경변수로 실행합니다. `SUPABASE_SERVICE_ROLE_KEY`는 PIN 발급 세션과 비공개 파일 서버에만 사용합니다. 원본용 버킷은 `warehouse-documents-v2`입니다. 롤백이 필요하면 신규 접수와 승인을 멈춘 뒤 이전 화면과 DB 진입점의 호환성을 확인합니다. v1 시작 재고 적재/활성화 스크립트는 v2 업그레이드에 사용하지 않습니다.

## 분석 규격 2와 접수 전 검증

기존 v2에 `supabase/05_analysis.sql`을 한 번 적용합니다. 이 마이그레이션은 검증 규칙, 행별 피킹·재고 처리 정보, 재고 반영 없는 마감 확인을 추가합니다. 기존 문서나 품목의 값을 다시 적재하지 않습니다. 별칭 재사용은 관리자의 명시적인 거래 검토로 기록합니다.

일반 ChatGPT에서는 공식 분석 지침의 preview_chatgpt → import_chatgpt 순서를 따릅니다. 전용 GPT의 작업은 POST /api/preflight → POST /api/intake입니다. 사이트의 JSON 입력도 같은 DB 판단을 사용합니다. 신규 접수는 검증 결과의 stamp를 preview_stamp에 넣고 verified와 stored_lines를 대조합니다. 기존 규격 1을 사용하는 호출은 계속 처리합니다.

프로젝트의 분석 판단 순서와 현장 예시는 [.agents/skills/warehouse-analysis/SKILL.md](../.agents/skills/warehouse-analysis/SKILL.md)에 있습니다. 사이트 등록 지침에는 같은 본문을 배포합니다.

## 검증

`npm test`로 수량 미리보기 검증을 실행합니다. v2 DB 시나리오는 Docker 기반 `npm run test:workflow`로 실행합니다. 매번 전용 PostgreSQL 컨테이너와 가상 170개 품목을 만들고 끝나면 삭제합니다. 문서 중복·수정본, 승인 트랜잭션 중간 실패, 동시 승인, 직원 접근 거부, 주문품·정정·반품·AS를 검증합니다.

브라우저 검증은 `WM_QA_CONFIG=/비공개경로/qa.json npm run test:browser`입니다. Node 24, 로컬 Chromium, 루프백의 v2 PostgreSQL/PostgREST·Supabase Auth·Storage와 24자보다 긴 이름의 ‘검증용’ 품목이 필요합니다. 설정 JSON에는 로컬 `anon`, `service`, `pins.admin`, `pins.staff`를 넣습니다. 포트는 `authPort`, `restPort`, `storagePort`로 지정합니다. 이 검증은 해당 가상 품목의 실사, 문서 등록, 원본 검증과 실제 마감을 수행합니다.

브라우저 실행 시 `WM_QA_ANALYSIS_PNG_DIR`을 지정하면 390px 피킹·마감 화면도 검증하고 캡처합니다. 이 격리용 자료는 `2F-D-11`의 KJ3AB-750 모터와 현재고 0의 KJB3-2600을 사용합니다.

v1 인수 검증에는 별도 PostgreSQL, Supabase Auth, PostgREST 환경과 검증 전용 데이터를 사용했습니다. 관리자의 320px 화면과 직원의 1280px 화면을 분리한 브라우저 세션으로 출고 10→7, 두 번 저장, 실사 7→5, 새로고침, 이력 필터와 가로 넘침을 확인했습니다.

로그인 사진은 [Unsplash 창고 사진](https://images.unsplash.com/photo-1586528116311-ad8dd3c8310d)입니다.

기존 v2 환경에는 05_analysis.sql 이후 supabase/06_records.sql을 한 번 적용합니다. 이 마이그레이션은 품목·재고·기존 전표를 갱신하지 않습니다.

확정 주문품 접수는 06_records.sql 이후 supabase/07_confirmed_orders.sql을 한 번 적용합니다. 사용자 확인 근거와 모터·완성품 구분, 모델·전체 주문 사양을 함께 전송하면 사전 검증이 생성 예정 또는 재사용할 SKU를 표시합니다. 등록 시 문서와 품목 연결을 함께 저장합니다. 새 품목의 수량은 미확인으로 시작하며, 일일 마감에서 첫 거래 직전의 확인 수량과 해당 날짜의 승인 거래를 함께 반영합니다. 기존 미승인 자료의 연결 보완은 배포와 분리된 명시적 작업입니다.
