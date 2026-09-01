# 단계: 설계

기능: $FEATURE — 실시간 음성 번역 Flutter 앱(Neemba MVP)의 D-5:
자동 스크롤 latch 결함 수정 + 자막 리스트 위젯 분리

## 출력 (이 파일 하나만 쓴다)
`$WORK/DESIGN.md`

## 입력 (읽기만, 절대 수정 금지)
- `$ROOT/HANDOFF.json` — 감사 세션 핸드오프. `current_stream.tasks` 중 **id 가 D-5 인 한 건만** 이번 범위다.
  `why`/`what`/`why_first` 가 근거 자료다. `permanent.mines` 에 지뢰 목록이 있다.
- `$ROOT/lib/mic_translation_tab.dart` — 수정 대상. `_shouldAutoScroll` · `_scrollToBottomIfNeeded` · `_handleScroll` · 자막 `ListView.builder`
- `$ROOT/lib/rtmp_translation_tab.dart` — 같은 로직이 복제돼 있는 두 번째 대상
- `$ROOT/test/mic_translation_tab_dispose_test.dart`, `$ROOT/test/rtmp_translation_tab_dispose_test.dart` — P0 에서 만든 dispose 가드. 위젯 분리가 이걸 깨뜨릴 수 있다
- `$WORK/JUDGE.md` — **있을 때만.** 이전 설계본이 판단 검증에서 되돌아왔다는 뜻이다.
  `REFUTED` 를 받은 주장은 근거째로 폐기하고 다시 세운다 — 같은 결론을 다시 쓰려면
  그 반박을 반증하는 **새 근거**가 있어야 한다. `UNVERIFIED` 는 확인하거나, 확인하지
  못하면 등급을 그대로 적는다. "그대로 진행해도 되는 것" 으로 분류된 항목은 재검증
  없이 재사용해도 된다.
- `$WORK/DESIGN.md` — **JUDGE.md 가 있을 때만.** 판정 대상이 된 이전 설계본이다.
  JUDGE.md 의 절 번호 인용을 해석하려면 필요하다. 이번 단계가 덮어쓸 파일이므로
  읽고 나서 새로 쓴다.

## 문제 정의

`_handleScroll` 은 `ScrollController` 리스너다. 그래서 **사용자 드래그와 프로그램 스크롤
(`animateTo`)을 구분하지 못한다.** 코드 리뷰(2026-08-22 high)의 주장은 이렇다 —
`position.maxScrollExtent` 는 non-shrinkWrap `ListView.builder` 에서 레이아웃된 자식으로부터
**추정**되는 값이라 가변 높이 `ListTile` 이 캐시에서 빠지면 흔들린다. `animateTo(옛 max)` 가
끝난 뒤 추정치가 커져 있으면 `pixels` 가 48px 임계보다 모자라 `_shouldAutoScroll=false` 가 되고,
그 뒤 자막이 안 따라간다.

`_shouldAutoScroll` 은 **latch** 다 — 한 번 false 가 되면 사용자가 바닥으로 되돌아오거나
Clear Text 를 누르기 전까지 스스로 true 로 안 돌아온다. 그래서 순간 오판이 아니라
"번역이 멈춘 것처럼 보이는" 영구 상태로 굳는다. 이것이 이 결함의 무게다.

**이 주장은 아직 재현되지 않았다(근거 등급: 추정).** 설계는 이 전제 자체를 먼저 검토한다.

## 설계가 결론을 내야 할 판단 4건

결론과 **근거 등급**(실측 / 코드확인 / 추정)을 DESIGN.md 에 적는다.
판단을 다음 단계로 미루지 않는다 — 구현 단계는 설계를 그대로 따르기만 한다.

1. **핸드오프가 제안한 해법이 실제로 결함을 고치는가.**
   D-5 의 `what` 은 "`extentAfter`·`atEdge` 를 쓰는 쪽으로 바꾼다" 이다. 그런데
   `ScrollMetrics.extentAfter` 의 정의와 `atEdge` 의 정의를 Flutter SDK 소스에서 직접 확인하고,
   현재 식(`pixels >= maxScrollExtent - 48`)과 비교해 **결함이 실제로 사라지는지** 판정한다.
   고쳐지지 않는다면 핸드오프의 제안을 따르지 말고 그 사실을 근거와 함께 적는다.
   핸드오프는 정본이지만 무오류가 아니다 — `meta.note` 가 그렇게 경고한다.
2. **latch 를 무엇으로 판정할 것인가.** `ScrollController` 리스너를 유지할지,
   `NotificationListener<ScrollNotification>` 으로 바꿔 사용자 조작만 골라낼지.
   후자라면 드래그 판별 수단(`dragDetails` · `UserScrollNotification` 등)이 프로그램 스크롤과
   실제로 구분되는지 SDK 소스로 확인한다. 플링(관성)으로 바닥에 도달했을 때
   latch 가 다시 켜지는지도 설계가 답해야 한다.
3. **위젯 분리의 범위.** 자막 리스트를 별도 위젯으로 뽑을 때 스크롤 상태
   (`ScrollController` · latch · 바닥 추적)를 위젯이 통째로 소유할지, 탭에 남길지.
   위젯 테스트로 latch 를 검증하려면 무엇이 위젯 안에 있어야 하는지로 판단한다.
4. **두 탭의 공통화 수준.** MIC 는 `micTtsService`, URL 은 `textToSpeechService` 로
   TTS 서비스가 다르고 `currentSpeakingIndex` 조회 경로도 다르다. 하나의 위젯이 둘 다
   받게 할지, 아니면 리스트만 공통화하고 나머지는 탭에 둘지.

## 주의

- HANDOFF.json 의 줄번호는 기록 시점 기준이다. **파일을 직접 읽고 현재 위치를 재확인해서**
  DESIGN.md 에는 현재 기준 위치를 적는다.
- **함정 하나가 이미 확인됐다** — 탭은 `texts.add(text)` 로 같은 `List` 인스턴스를 제자리
  변경한다. 위젯으로 분리한 뒤 `didUpdateWidget` 에서 `oldWidget.texts.length` 와
  `widget.texts.length` 를 비교하면 같은 객체라 **항상 같아서 영원히 안 걸린다.**
  설계가 이 지점을 어떻게 피하는지 명시한다.
- `permanent.mines` 의 지뢰(riverpod 3.0.0-dev 프리릴리스, TabBarView keepAlive 부재로 인한
  dispose, `await` 뒤 `WidgetRef` 사용 등)를 설계가 밟지 않는지 항목별로 확인한다.
- **P0 에서 만든 dispose 테스트를 지우지 않는다.** 위젯 분리로 계약이 달라지면 새 계약에
  맞게 다시 쓴다 — 삭제는 범위 이탈이다.
- `current_stream.principle`: 번역 동작 경로를 건드리는 스트림이라 회귀 위험이 크다.
  릴리스 로그를 더럽히지 않는다 — `lib/` 아래에서는 `logD` 와 `diag` 만 쓰고
  `print`·`debugPrint` 를 넣지 않는다.
- `out_of_scope`: 기능 추가·UI 개편, D-2/D-3/D-4, P2 이하(`follow_ups`),
  Gradle/AGP/Kotlin 상향. 설계에 넣지 않는다. **화면 구성과 조작 흐름은 그대로여야 한다** —
  자동 스크롤이 사용자 조작에만 반응하게 되는 것 자체는 결함 수정이지 UI 변경이 아니다.

## 검증 기준은 두 층으로 나눠 쓴다

1. **자동 검증** — `flutter analyze` 클린, `flutter test` 통과.
   현재 테스트가 **몇 건인지 직접 실행해서 세고** 그 숫자를 기준선으로 적는다.
   기준선보다 줄어들면 무언가를 지운 것이다.
   신규 위젯 테스트는 **무엇을 단언할지**까지 설계가 적는다. 최소한 이 둘은 들어간다 —
   (a) 프로그램 스크롤은 latch 를 끄지 않는다(= D-5 본 결함), (b) 사용자가 위로 끌면 latch 가 꺼진다.
   `permanent.mines`: "테스트를 새로 쓰면 수정을 빼고 실패하는지 반드시 확인할 것" —
   각 테스트가 수정 없이는 실패하는 이유를 설계가 한 줄로 적는다.
2. **실기기 수동 검증** — `current_stream.shared_verify` 를 체크리스트로 옮겨 적는다.
   자동화 대상이 아니며 사람이 기기에서 수행한다. D-5 는 기기 없이 끝까지 갈 수 있는
   항목으로 선정됐다 — 기기가 필요한 검증이 설계에서 나오면 그 이유를 적는다.

## DESIGN.md 필수 섹션
- STATUS 라인 (첫 줄)
- 변경 대상 파일 목록 (경로 명시, 신규/수정 표시)
- 수정 설계 (현재 기준 위치, 바꾸는 흐름, 지뢰 회피 근거)
- 위 "판단 4건" 의 결론과 근거 등급
- 공개 인터페이스 변경 여부 (신규 위젯의 생성자 시그니처는 여기 적는다)
- 검증 기준 (위 두 층 구분)
- 하지 않는 것 (범위 밖 명시)
- `ALLOWED_FILES:` 블록 (아래 형식 엄수 — 셸이 이걸 파싱한다)

## ALLOWED_FILES 블록 (형식 엄수 — 셸이 파싱한다)

"변경 대상 파일 목록" 표와 **별도로** 아래 블록을 정확히 이 모양으로 넣는다.
표는 사람이 읽고 이 블록은 셸이 읽는다. 둘의 내용은 일치해야 한다.

ALLOWED_FILES:
- lib/mic_translation_tab.dart
- lib/rtmp_translation_tab.dart

규칙:
- 저장소 루트 기준 상대 경로. `./` 접두사 금지.
- 한 줄에 하나, `- ` 로 시작. 블록은 빈 줄로 끝난다. 주석·설명을 섞지 않는다.
- 구현이 새로 만들 파일(분리할 위젯 파일), **검증 단계가 만들 테스트 파일까지 미리 다 넣는다.**
  여기 없는 파일이 변경되면 파이프라인이 그 자리에서 죽는다. 재시도가 아니라 종료다.
- 목록이 길어지는 게 부담이면 설계 범위가 넓은 것이다. 목록을 줄이지 말고 범위를 줄여라.

## 금지
- 코드를 쓰지 않는다. 시그니처와 스펙까지만.
- 설계에 필요한 정보가 없으면 추측하지 말고 STATUS: BLOCKED.
