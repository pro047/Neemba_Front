# 기능 PRD: 세션 중 화면 꺼짐 방지 + 화면 복귀 시 재연결 (screen-awake)

작성 2026-11-28. 마일스톤 M1. 요구사항 정본은 이 문서다. foreground service(화면을 끈 채 듣기)는 M2 별도 기능이며 이 기능의 범위 밖이다.
`HANDOFF.json` 의 `permanent.mines` 와 코드 규칙은 그대로 적용한다.

## 왜
- 청취자(Android, 1명)는 예배 중 자막을 읽으려고 화면을 손으로 건드려 켜 둔다. 놓치면 화면이 잠기고 번역이 끊긴다.
- [실측 2026-11-28, 테스트 기기 SM-A716S·Android 13·절전 모드 ON·충전 해제, 프로덕션] 화면 꺼짐 15:09:39 → 18초 뒤 ws close 1001 →
  이후 4분간 재시도 10회 전부 `Failed host lookup`(OS 네트워크 차단) → 화면 켠 15:13:43 의 16초 뒤 `ws.reconnect.ok attempts=11`.
  재시도 간격은 backoff+close 타임아웃 계산값과 일치 — Dart 타이머는 멈추지 않았다(isFrozen=false 15회). 원인은 네트워크 차단이다.
- 따라서 화면이 약 5분 넘게 꺼져 있으면 RTMP 재시도 12회(kWsMaxRetriesRtmp)가 소진되어 ws.giveup → 영구 정지한다.

## 현재 코드 사실 (2026-11-28, develop d413fac 기준 — 설계 시 재확인할 것)
- 앱 생명주기 관찰자 없음: `WidgetsBindingObserver`·`didChangeAppLifecycleState` 사용처 0건 (lib/ grep).
- 화면 유지 수단 없음: 패키지·네이티브 모두 없다. `android/app/src/main/kotlin/app/neemba/translation/MainActivity.kt` 는 RECORD_AUDIO 요청만 한다.
- RTMP 재시도 소진 시: `lib/ws_client.dart` 의 budget-exhausted 분기가 `ws.giveup` 기록 후 onPermanentFailure 호출 →
  `lib/rtmp_translation_tab.dart` 의 onPermanentFailure 가 '연결 복구 실패. 다시 시작해 주세요.' 스낵바 + `screenFlowController.reset()`.
- MIC 탭 onPermanentFailure 는 `_handleMicStartFailure` 로 세션을 정리한다 (`lib/mic_translation_tab.dart`).
- 서버 사실: 다운링크(/ws) 끊김에는 시간 기반 만료가 없다 — RTMP 세션은 오래 끊겨도 같은 sessionId 로 재접속 가능.
  MIC 는 업링크가 10초 넘게 끊기면 서버가 세션을 통째로 지우고, 만료 세션에 다시 붙으면 접속은 받아준 뒤 첫 프레임에서 1011 로 끊는다.

## 승인된 결정 (사용자 승인 2026-11-28 — 바꾸려면 사람 승인 필요)
1. 화면 유지는 **패키지 추가 없이 네이티브 코드**로 한다: MainActivity 의 MethodChannel 로 `FLAG_KEEP_SCREEN_ON` 을 켜고 끈다. pubspec 의존성 추가 금지.
2. 켜는 시점: 세션이 연결 시작된 때 (RTMP·MIC 두 탭 모두). 끄는 시점: Stop, 탭 dispose, 세션 실패·giveup 등 **세션이 끝나는 모든 경로**. 하나라도 빠지면 화면이 계속 켜져 배터리가 샌다.
3. RTMP: 화면이 꺼져 있던(앱이 resumed 가 아니던) 동안 끊겼더라도, 앱이 다시 resumed 되면 **사용자 조작 없이 같은 세션으로 재연결**한다. 꺼져 있던 시간과 무관해야 한다.
4. MIC: 재연결로 살리지 않는다(서버가 세션을 지운다). 끊긴 상태로 resumed 되면 세션이 끝났음을 사용자에게 알리고 정리한다.

## 설계가 정할 것 (`[결정]` 으로 올릴 것)
- 결정 3을 이루는 방식: (a) 앱이 resumed 가 아닐 때는 재시도 예산을 쓰지 않고 멈췄다가 resumed 에서 새 예산으로 재개, (b) giveup 은 그대로 두되 UI 를 reset 하지 않고 세션을 보존했다가 resumed 에서 재무장, 또는 다른 안. 기존 세대 가드(_generation)와의 상호작용을 반드시 다룰 것.
- MethodChannel 이름·메서드 시그니처, 테스트에서 채널을 대체하는 방법.

## 범위 밖
- foreground service, 알림, 매니페스트 권한 변경 (M2).
- 재시도 예산 숫자 변경, 상태 표시줄(3번 항목) 개편, 스낵바 문구 변경.
- iOS.

## 완료 조건
- 자동: `flutter analyze`·`flutter test` 종료 코드 0, 기존 테스트 삭제·skip·기대값 변경 없음. 새 테스트로 고정할 것:
  - 두 탭에서 세션 시작/Stop/dispose/giveup 마다 화면 유지 켜짐·꺼짐 호출이 짝이 맞는다 (꺼짐 누락 0).
  - RTMP: 비-resumed 동안 끊김 → resumed 후 재연결 시도가 일어난다. 비-resumed 시간이 예산 소진 시간(약 5분)보다 길어도 마찬가지.
  - MIC: 끊긴 채 resumed → 재연결하지 않고 세션 정리.
- 실기기(파이프라인 밖, 런처 세션이 테스트 기기에서 확인): screen_off_timeout 15초로 줄인 상태에서 세션 중 2분 화면 유지, Stop 후 15초 내 꺼짐.
  전원 버튼으로 6분 잠금 후 켜면 RTMP `ws.reconnect.ok`.
