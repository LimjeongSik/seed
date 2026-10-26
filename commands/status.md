---
description: seed 실행의 현재 사이클 · 단계 · 백로그 · 최근 테스트 판정을 보여줍니다. "seed 어디까지 됐어?", "서비스 개발 진행 상황", "지금 몇 사이클째야?" 같은 질문에 사용
---

`.seed/`를 읽어 현재 상태를 짧게 보고한다. 파일을 고치지 않는다.

- `state.json`: 상태, 사이클 / 최대 사이클, 단계, 기다리는 에이전트, 마지막 요약
- `log.md`: 최근 5줄
- `product/backlog.md`: 우선순위별 todo / doing / done 개수
- `product/done.md`와 가장 최근 `cycles/NN/report.md`: DoD 통과 수 / 전체, 열린 P0 · P1 · P2 개수, 완성 판정

`.seed/state.json`이 없으면 "진행 중인 실행이 없다"고 알린다.
