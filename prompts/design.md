# 단계: 설계

기능: $FEATURE — 실시간 음성 번역 Flutter 앱(Neemba MVP)의 P0 실장애 수정 설계

## 출력 (이 파일 하나만 쓴다)
`$WORK/DESIGN.md`

## 입력 (읽기만, 절대 수정 금지)
- `$ROOT/HANDOFF.json` — 감사 세션의 핸드오프 문서. `current_stream.tasks`에 P0 5건의 증상·근본 원인·수정 방향·검증 절차가 있고, `permanent.mines`에 지뢰 목록이 있다. 설계의 근거 자료다.
- `$ROOT/lib/` 아래 해당 소스 파일들 (ws_client.dart, mic_translation_tab.dart, rtmp_translation_tab.dart, mic_client.dart 등)

## 확정된 사용자 결정 (설계에 반영할 것)
- P0-2: 탭 전환 시 세션은 **종료·정리**한다. AutomaticKeepAliveClientMixin으로 유지하는 방향은 채택하지 않는다.

## 주의
- HANDOFF.json의 줄번호(lines_hint)는 감사 시점 기준이다. 반드시 파일을 직접 읽고 현재 위치를 재확인해서 DESIGN.md에는 현재 기준 위치를 기록한다.
- 범위는 P0 5건뿐이다. HANDOFF.json `out_of_scope`의 P1~P4 항목을 설계에 넣지 않는다.
- `permanent.mines`의 지뢰(IOWebSocketChannel.connect 동기 반환, AsyncValue.guard 예외 흡수, keepAlive 부재로 인한 dispose, riverpod 프리릴리스)를 설계가 밟지 않는지 항목별로 확인한다.
- 성공 경로는 실기기 검증이 끝난 상태다. 설계는 실패 경로만 고치고 성공 경로 동작을 바꾸지 않는 방향이어야 한다.

## 검증 기준은 두 층으로 나눠 쓴다
1. **자동 검증** — `flutter test`로 확인 가능한 것. 수정 로직 중 순수하게 뽑을 수 있는 부분(예: 재시도 카운터·백오프 계산)은 테스트 가능한 형태로 설계한다.
2. **실기기 수동 검증** — HANDOFF.json 각 task의 `verify` 필드를 체크리스트로 옮겨 적는다. 자동화 대상이 아니며, 사람이 기기에서 수행한다.

## DESIGN.md 필수 섹션
- STATUS 라인 (첫 줄)
- 변경 대상 파일 목록 (경로 명시, 신규/수정 표시)
- P0 task별 수정 설계 (현재 기준 위치, 바꾸는 흐름, 지뢰 회피 근거)
- 공개 인터페이스 변경 여부 (원칙적으로 없어야 함 — 있으면 이유)
- 검증 기준 (위 두 층 구분)
- 하지 않는 것 (범위 밖 명시)

## 금지
- 코드를 쓰지 않는다. 시그니처와 스펙까지만.
- 설계에 필요한 정보가 없으면 추측하지 말고 STATUS: BLOCKED.
