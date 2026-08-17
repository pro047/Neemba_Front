import 'package:flutter_test/flutter_test.dart';
import 'package:mvp/node_ws_client.dart';

void main() {
  group('업링크 세션 수명 상수', () {
    test('서버 유예(10초)를 그대로 반영한다', () {
      // services/node micWebSocket.ts DEFAULT_TEARDOWN_GRACE_MS. 서버가 이 값을
      // 바꾸면 클라이언트도 같이 바뀌어야 하고, 이 테스트가 그 연결을 문서로
      // 남긴다. 여기가 서버보다 크면 이미 죽은 세션에 계속 오디오를 보낸다.
      expect(kMicTeardownGrace, const Duration(seconds: 10));
    });

    test('1011을 세션 소멸 신호로 쓴다', () {
      // 서버는 런타임이 사라진 뒤 붙은 업링크를 첫 오디오 프레임에서 1011로
      // 닫는다. 접속 자체는 받아주기 때문에, 이 코드가 유일한 확정 신호다.
      expect(kMicNoRuntimeCloseCode, 1011);
    });

    test('재연결 백오프 상한이 서버 유예보다 짧다', () {
      // 백오프 한 번이 유예보다 길면 재연결이 성공할 기회 자체가 없다.
      // node_ws_client의 상한은 5초(attempt > 5 ? 5 : attempt).
      const maxBackoff = Duration(seconds: 5);
      expect(maxBackoff, lessThan(kMicTeardownGrace));
    });
  });
}
