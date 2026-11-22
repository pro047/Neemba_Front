### 테스트 환경
- 테스트는 `test/` 아래 `<대상>_test.dart` 로 쓴다 (`flutter test` 가 이 위치·이름만 돈다).
  위젯 테스트는 `flutter_test` 의 `testWidgets` 를 쓴다 — 기존 `test/*_dispose_test.dart` 가 예시다.
- 테스트 작성 지뢰는 `HANDOFF.json` 의 `permanent.mines` 에 있다 (위젯 테스트에서 audioplayers·
  flutter_tts 플랫폼 채널 막기, `flutter_dotenv` 는 `dotenv.loadFromString(envString:)` 등). 쓰기 전에 읽는다.
- 설계의 실기기 수동 검증 층은 테스트로 만들지 말고 VERIFY.md 의 사람 체크리스트로 옮긴다.
- 셸은 `flutter analyze` 와 `flutter test` 를 따로 돌린다. 새 테스트 파일도 analyze 경고가 없어야 한다.
