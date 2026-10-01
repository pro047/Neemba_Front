### 프로젝트
실시간 음성 번역 Flutter 앱 (Neemba MVP). 번역 화면은 MIC 탭(`lib/mic_translation_tab.dart`)과
URL/RTMP 탭(`lib/rtmp_translation_tab.dart`) 두 개다. TTS 서비스와 프로바이더가 탭별로 나뉘어 있다.
한쪽을 고치는 설계는 다른 쪽에 같은 코드가 있는지 확인한다.

### 입력 문서
- `HANDOFF.json` (저장소 루트) — 감사 세션 핸드오프, 요구사항 정본.
  - `current_stream.tasks` 중 이번 기능에 해당하는 항목의 `why`/`what` 이 근거 자료다.
    `current_stream.principle` · `out_of_scope` · `shared_verify` 도 함께 본다.
  - `permanent.mines` 에 지뢰 목록이 있다. 설계가 각 지뢰를 밟지 않는지 항목별로 확인한다.
  - 정본이지만 무오류가 아니다 — `meta.note` 대로 줄번호·개수는 기록 시점 기준이다.
    파일을 직접 읽고 현재 위치를 재확인해서 DESIGN.md 에는 현재 기준 위치를 적는다.
  - `follow_ups` 는 이번 범위가 아니다.

### 범위 밖
- Gradle/AGP/Kotlin 상향은 설계에 넣지 않는다 (`permanent.mines` — 출시 후 일괄 상향).

### 코드 규칙
- `lib/` 아래에서는 로그에 `logD` 와 `diag` 만 쓰고 `print`·`debugPrint` 를 넣지 않는다
  (`lib/log.dart` 안의 구현은 예외). 릴리스 로그를 더럽히지 않기 위해서다.
- `flutter_riverpod` 은 `3.0.0-dev.17` 프리릴리스다. 정식판 문서가 아니라 이 저장소의 기존 사용 패턴을 근거로 쓴다.

### 테스트 관련 사실
- 기존 테스트 중 `test/mic_translation_tab_dispose_test.dart` · `test/rtmp_translation_tab_dispose_test.dart`
  는 탭 dispose 가드다. 탭 구조를 바꾸면 이 계약이 깨질 수 있다 — 지우지 말고 새 계약에 맞게
  고치도록 `TEST_FILES` 에 넣는다.
- 현재 테스트 건수를 직접 실행해서 세고 기준선으로 적는다. 기준선보다 줄어들면 무언가를 지운 것이다.
- `permanent.mines`: 새 테스트는 수정 없이 실패하는 이유를 설계가 한 줄로 적는다.
- 실기기 수동 검증은 `current_stream.shared_verify` 에서 해당 항목을 [사람 확인 필요] 체크리스트로 옮긴다.

### Flutter SDK
Flutter SDK 소스는 읽기 전용으로 열려 있다 (`packages/flutter/lib`). 프레임워크 API 의 실제
계약(예: `ScrollMetrics` 의 정의)은 추측하지 말고 SDK 소스에서 확인해 `코드확인` 으로 적는다.
