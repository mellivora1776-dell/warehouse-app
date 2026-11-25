# 창고 입출고 분석

입출고 자료, 피킹, 마감, 접수 API를 다룰 때 [.agents/skills/warehouse-analysis/SKILL.md](.agents/skills/warehouse-analysis/SKILL.md)의 판단 순서를 적용한다. 운영 사이트의 `warehouse-app/public/warehouse-instructions.txt`에는 이 스킬의 front matter를 제외한 동일 본문을 배포한다.

앱 작업 경로는 `warehouse-app/`이다. `npm run test:workflow`는 격리된 PostgreSQL에서 기존 수불과 분석 규격을 함께 검증한다. 화면 비교 이미지는 시험 데이터로 촬영한다.
