# 기능 PRD: 진단 기록 업로드 + URL 마스킹 (diag-upload)

작성 2026-11-20. 이 기능의 요구사항 정본은 이 문서다. `HANDOFF.json` 의 `current_stream.tasks`(D-1~D-5)는
이 기능을 다루지 않는다 — 그쪽의 `permanent.mines` 와 코드 규칙만 그대로 적용한다.

## 왜
- 11/15 예배에서 서버는 02:09 에 1006(detected_by=client_disconnect)으로 끊김을 기록했고 이후 529건이 유실됐다.
  원인 후보(앱이 끊김을 모름 / 재시도 예산 소진 / 백그라운드)는 서버 기록만으로 가를 수 없다.
- 앱 진단 로그(`lib/diagnostics.dart`)는 기기 안에만 있다. 서버 DB 로 올려서 예배 후에 본다.
- 서버 쪽(테이블·엔드포인트·조회)은 neemba 저장소에서 구현·테스트 완료, 배포 전이다.
- **URL 마스킹은 업로드와 같은 배포에 반드시 들어가야 한다** (계약 조건). 업로드만 먼저 나가면 안 된다.

## 서버 계약 원문 (neemba `docs/client-diagnostics-contract.md`, 승인본)

엔드포인트: `POST https://neemba.app/api/diagnostics/client-logs` · `Content-Type: application/json` · 인증 없음.

요청 본문:
```json
{
  "installId": "3f1c2a9e-7b4d-4e2a-9c1f-0a2b3c4d5e6f",
  "appVersion": "1.4.2+37",
  "entries": [
    {"seq": 1041, "line": "2026-11-15T02:09:00.123Z ws_close code=1006 reason=<empty>"},
    {"seq": 1042, "line": "2026-11-15T02:09:00.988504Z ws_retry attempt=1"}
  ]
}
```
- installId(필수): 최초 실행 시 만든 UUID 문자열. 대소문자 무관(서버는 소문자 저장).
- appVersion(선택): 64자 이하.
- entries(필수, 1개 이상): seq 는 0 이상의 JSON 정수, 설치 ID 안에서 단조 증가. line 은 기기 기록 한 줄 원문, 빈 문자열 불가.
- 배치 안 순서 무관. 같은 seq 가 두 번 있으면 첫 번째만 저장.
- 앱이 업로드 전에 URL 마스킹을 적용한다(sessionId 가 든 전체 URL 이 줄에 남지 않게). 서버는 검사하지 않는다.
- 줄 머리는 `<ISO8601 시각(타임존 필수)> <event> ...` 권장. 서버는 앞 두 토큰만 파싱하고, 실패해도 원문은 저장.

상한 (개수와 바이트는 각각 적용):
- 요청 본문(직렬화된 UTF-8 바이트) 2,097,152 (2 MiB) 초과 → 413
- entries 개수 10,000 초과 → 413
- line 4,000자 초과 → 잘라서 저장, 응답 truncated 에 집계
- **앱 분할 규칙(두 조건 모두): 한 요청의 entries 5,000개 이하, 직렬화 본문 1 MiB 이하.** 하나라도 넘으면 나눈다.
  기기 보관량(256KB×2)이 한 요청에 들어간다는 보장이 없으므로 분할은 필수.
- U+0000·짝 없는 서로게이트는 서버가 치환해 저장(거부 안 함).

응답 (앱은 상태 코드만 보고 판단한다. 413·429 본문은 nginx HTML 일 수 있다):
- 200: 저장됨(중복 포함). 본문 `{"ackedMaxSeq": <요청 entries 최대 seq>, "inserted": n, "duplicates": n, "truncated": n}`.
  이 배치의 seq 를 모두 업로드 완료로 표시하고 ackedMaxSeq 로 커서를 갱신.
- 413: 너무 큼. 같은 배치를 재전송하지 말고 더 작게 나눠 보낸다.
- 422: 형식 오류. 재전송하지 않는다. 앱 버그로 보고 해당 배치는 버린다(업로드 완료로 표시).
- 429: 레이트 제한(IP당 분당 60회, 버스트 40). 다음 업로드 시점에 재시도, 미전송분 유지.
- 502/503/504/타임아웃·네트워크 오류: 저장 여부 불확실. 다음 시점에 같은 배치 재전송, 미전송분 유지.
  서버가 (installId, seq) 로 멱등 처리하므로 중복 행은 생기지 않는다.

서버는 k=v 필드를 파싱하지 않고, seq 빈 구간을 메우지 않으며, 클라이언트 IP 를 저장하지 않는다.

## 현재 코드 사실 (2026-11-20 기준, 설계 시 재확인할 것)
- 직렬화: `<UTC ISO8601> <event> k=v ...` 한 줄, JSON 아님. `lib/diagnostics.dart` `_format`·`_scrub`.
  값은 공백 1칸으로 접고 200자(frames 1200자)에서 자른다.
- 시각: `toUtc().toIso8601String()` — 소수부 3자리 또는 6자리(실측: `2026-11-18T10:18:15.988504Z`, `2026-11-15T02:09:00.123Z`).
- 회전: 기존 `diagnostics.1.log` 삭제 → `diagnostics.log` 를 `.1` 로 rename → 새 파일 append (`_rotate`). 바이트 오프셋 커서는 회전에서 깨진다.
- 쓰기는 `_writes` 체인 하나로 직렬화된다. 버퍼 200줄 초과 시 오래된 것부터 버리고 `diag.dropped lines=N` 을 끼운다.
- 기록 고유 번호·설치 ID 는 현재 없다. 인증 헤더도 없다(REST 헤더는 Content-Type 뿐).
- `describeError`/`recordError` 는 `WebSocketException` 메시지를 그대로 남긴다. dart:io 의 메시지에 sessionId 쿼리가 든 전체 URL 이 들어갈 수 있다(추정 — 설계·테스트에서 실측할 것).
- `lib/log.dart` 에 `maskId`(앞 8자 + …)와 `maskUrl`(URL 의 sessionId 쿼리만 치환)이 있다.
- 업로드 주소 기준: `ApiConfig.httpUrl`(`.env`/`.env.prod` 의 HOST=`https://neemba.app`, `.env.dev` 는 localhost). dotenv 로드는 `main.dart` 에서 `_installDiagnostics()` 뒤에 일어난다.
- 재연결 성공 지점: `lib/ws_client.dart` 의 `ws.reconnect.ok` diag (커밋 7b7d226). 세션 시작 성공 지점: `lib/rest_client.dart` `rtmp.start.ok`, `lib/mic_client.dart` `mic.start.ok`.

## 승인된 설계 결정 (사용자 승인 2026-11-20 — 바꾸려면 사람 승인 필요)
1. **seq 는 디스크 각 줄 맨 앞 토큰으로 기록한다.** 디스크: `1041 2026-11-15T02:09:00.123Z ws.disconnect code=1006 ...`.
   업로드 시 맨 앞 정수 토큰을 떼어 `{"seq":1041,"line":"2026-...Z ws.disconnect ..."}` 로 만든다(line 은 시각으로 시작).
   seq 는 `record()` 시점에 부여한다 — 버퍼에서 버려진 기록도 seq 빈 구간으로 드러나야 한다.
2. **installId 와 업로드 커서(ackedMaxSeq)는 진단 폴더의 작은 JSON 상태 파일 하나에 저장한다.**
   installId 는 최초 실행 때 `Random.secure()` 로 만든 UUID v4. 시작 시 다음 seq = max(디스크 최대 seq, 저장된 커서) + 1.
   상태 파일 쓰기도 임시 파일 → rename 으로 교체한다.
3. **appVersion 은 보내지 않는다** (선택 필드, 패키지 추가 회피).
4. **URL 마스킹은 기록 시점에 적용한다.** `_format`(또는 동등 지점)에서 모든 값의 `sessionId=<값>` 을 `maskId` 결과로 바꿔
   디스크에도 전체 sessionId 가 남지 않게 한다. 실제 dart:io `WebSocketException` 메시지를 테스트에서 실측해 입력으로 쓴다.
5. **업로드 주소는 `${ApiConfig.httpUrl}/api/diagnostics/client-logs`.**
6. **업로드 시점 셋: ① 재연결 성공 직후 ② 앱 실행 시(dotenv 로드 후) ③ 세션 시작 성공 시(URL·MIC 둘 다).**
   진행 중이면 새 요청은 건너뛴다(single-flight). 커서 이후 줄을 seq 오름차순, 5,000줄·1 MiB 이하 배치로 순서대로 보낸다.
   응답 처리는 계약표대로: 200 커서 갱신 / 422 배치 버림 처리 후 커서 진행 / 413 반으로 나눠 재시도(1줄짜리 413 은 버림 처리)
   / 429·5xx·타임아웃·네트워크 오류는 이번 업로드 중단, 커서 유지. 요청에 타임아웃을 건다.
   업로드 읽기는 회전과 경합하지 않게 `_writes` 체인을 거친다. 업로드는 앱을 죽이지 않는다(실패는 삼키고 diag 만).
7. **(a) 기존 기록 마이그레이션 — seq 없는 줄에 seq 를 붙여 업로드에 포함한다.**
   시작 시 `diagnostics.1.log` → `diagnostics.log` 순으로 읽어 첫 토큰이 정수가 아닌 줄에 오래된 순으로 seq 를 부여하고,
   **같은 패스에서 결정 4 의 마스킹도 적용한다**(옛 기록에 이미 전체 sessionId 가 있을 수 있다).
   결과는 임시 파일에 쓴 뒤 rename 으로 교체한다 — 중간에 실패해도 원본이 남아야 한다(11/15 기록 보존이 이 결정의 목적).

## 범위 밖
- 리뷰 항목 A(이미 완료)·B·D·E (연결 상태 표시, 탭 생명주기, TTS 등), 2번 재시도 예산, 6번 백그라운드.
- appVersion 수집, 인증, 서버 쪽 변경.
- Gradle/AGP/Kotlin 상향.

## 완료 조건
- 단위 테스트 통과:
  - seq 부여와 앱 재시작 후 다음 seq 복원
  - 회전이 일어난 뒤에도 커서 이후 줄만 업로드
  - 배치 분할 경계(5,000줄 / 1 MiB)
  - 응답 코드별 커서 처리(200·413·422·429·5xx·타임아웃)
  - 마이그레이션(seq 부여, 마스킹, 중간 실패 시 원본 보존)
  - sessionId 마스킹 — 실측한 dart:io `WebSocketException` 원문을 입력으로
- `flutter analyze`, `flutter test` 종료 코드 0, 기존 테스트 건수(64) 감소 없음
- [사람 확인 필요] 마스킹된 실제 줄 표본을 neemba 세션에 보내 서버 파싱과 대조
