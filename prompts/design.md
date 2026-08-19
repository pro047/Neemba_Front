# 단계: 설계

기능: $FEATURE — 실시간 음성 번역 Flutter 앱(Neemba MVP)의 P1 위생 정리 (P1-6, P1-7)

## 출력 (이 파일 하나만 쓴다)
`$WORK/DESIGN.md`

## 입력 (읽기만, 절대 수정 금지)
- `$ROOT/HANDOFF.json` — 감사 세션 핸드오프. `current_stream.tasks` 중 **id 가 P1-6, P1-7 인 두 건만** 이번 범위다. 각 task 의 `why`/`what`/`gotchas`/`verify` 가 근거 자료다. `permanent.mines` 에 지뢰 목록이 있다.
- `$ROOT/lib/mic_translation_tab.dart` — P1-6 의 수정 대상
- `$ROOT/lib/rtmp_translation_tab.dart` — P1-6 이 따라갈 참조 패턴 (Expanded + ScrollController)
- `$ROOT/lib/` 아래 `screenFlowProvider` · `wsClientProvider` 정의 — P1-7 의 대상
- `$ROOT/test/mic_translation_tab_dispose_test.dart`, `$ROOT/test/rtmp_translation_tab_dispose_test.dart` — P0 에서 만든 가드. P1-7 이 이걸 깨뜨릴 수 있다

## 이 스트림의 원칙 (P0 와 다르다)

사용자에게 보이는 동작은 **그대로여야 한다.** P0 는 고장난 실패 경로를 고치는 일이었고,
이건 동작을 유지한 채 구조만 정리하는 일이다. 화면 구성이나 조작 흐름이 바뀌면
그건 개선이 아니라 범위 이탈이다 — 설계 단계에서 그렇게 될 지점을 미리 짚는다.

## 설계가 결론을 내야 할 판단 3건

HANDOFF.json 이 "판단할 것" 으로 남겨둔 항목이다. 결론과 **근거**를 DESIGN.md 에 적는다.
판단을 다음 단계로 미루지 않는다 — 구현 단계는 설계를 그대로 따르기만 한다.

1. **P1-6** — URL 탭의 자동 스크롤 로직(`_handleScroll`, `_shouldAutoScroll`)을 함께 가져올지,
   리스트 구조만 가져올지. 가져오면 MIC 탭의 스크롤 동작이 바뀌는데 그게 "보이는 동작 변경"에
   해당하는지 판단한다.
2. **P1-7** — `screenFlowProvider` 분리 후, P0 의 우회책("소유한 세션이 있을 때만 건드린다")을
   제거할지 방어로 남길지.
3. **P1-7** — `wsClientProvider` 도 같은 공유 문제가 있다. 이번에 같이 분리할지,
   task 원문대로 `screenFlowProvider` 만 건드릴지.

## 주의

- HANDOFF.json 의 줄번호·개수는 기록 시점(2026-08-17) 기준이다. **파일을 직접 읽고 현재 위치를
  재확인해서** DESIGN.md 에는 현재 기준 위치를 적는다.
- `permanent.mines` 의 지뢰(riverpod 3.0.0-dev 프리릴리스, keepAlive 부재로 인한 dispose 등)를
  설계가 밟지 않는지 항목별로 확인한다.
- `out_of_scope`: 기능 추가·UI 개편, P2 이하(`follow_ups`), Gradle/AGP/Kotlin 상향. 설계에 넣지 않는다.
- **P0 에서 만든 dispose 테스트를 지우지 않는다.** P1-7 로 계약이 달라지면 테스트를 새 계약에
  맞게 다시 쓴다 — 삭제는 범위 이탈이다.

## 검증 기준은 두 층으로 나눠 쓴다

1. **자동 검증** — `flutter analyze` 클린, `flutter test` 통과.
   현재 테스트가 **몇 건인지 직접 실행해서 세고** 그 숫자를 기준선으로 적는다.
   HANDOFF.json 에는 35건과 27건이 둘 다 나오는데 서로 다른 시점의 값이다 — 인용하지 말고 확인한다.
   기준선보다 줄어들면 무언가를 지운 것이다.
2. **실기기 수동 검증** — 각 task 의 `verify` 와 `current_stream.shared_verify` 를 체크리스트로
   옮겨 적는다. 자동화 대상이 아니며 사람이 기기에서 수행한다.

## DESIGN.md 필수 섹션
- STATUS 라인 (첫 줄)
- 변경 대상 파일 목록 (경로 명시, 신규/수정 표시)
- task 별 수정 설계 (현재 기준 위치, 바꾸는 흐름, 지뢰 회피 근거)
- 위 "판단 3건" 의 결론과 근거
- 공개 인터페이스 변경 여부 (원칙적으로 없어야 함 — 있으면 이유)
- 검증 기준 (위 두 층 구분)
- 하지 않는 것 (범위 밖 명시)
- `ALLOWED_FILES:` 블록 (아래 형식 엄수 — 셸이 이걸 파싱한다)

## ALLOWED_FILES 블록 (형식 엄수 — 셸이 파싱한다)

"변경 대상 파일 목록" 표와 **별도로** 아래 블록을 정확히 이 모양으로 넣는다.
표는 사람이 읽고 이 블록은 셸이 읽는다. 둘의 내용은 일치해야 한다.

ALLOWED_FILES:
- lib/mic_translation_tab.dart
- lib/rtmp_translation_tab.dart
- test/mic_translation_tab_dispose_test.dart

규칙:
- 저장소 루트 기준 상대 경로. `./` 접두사 금지.
- 한 줄에 하나, `- ` 로 시작. 블록은 빈 줄로 끝난다. 주석·설명을 섞지 않는다.
- 구현이 새로 만들 파일, **검증 단계가 만들 테스트 파일까지 미리 다 넣는다.**
  여기 없는 파일이 변경되면 파이프라인이 그 자리에서 죽는다. 재시도가 아니라 종료다.
- 목록이 길어지는 게 부담이면 설계 범위가 넓은 것이다. 목록을 줄이지 말고 범위를 줄여라.

## 금지
- 코드를 쓰지 않는다. 시그니처와 스펙까지만.
- 설계에 필요한 정보가 없으면 추측하지 말고 STATUS: BLOCKED.
