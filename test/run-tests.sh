#!/usr/bin/env bash
# orchestrate.sh 게이트 검증 스위트
#
# 검증하는 것: 게이트가 "통과시키는가"가 아니라 "막는가"
# API 호출 0회. fake-claude 를 PATH 앞에 끼워넣는다.
#
# 사용법: ./test/run-tests.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(dirname "$HERE")"

PASS=0; FAIL=0
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

# ── 매 테스트마다 깨끗한 샌드박스 repo 를 만든다
setup() {
  SANDBOX="$(mktemp -d)"
  cd "$SANDBOX"
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p prompts test
  cp "$SRC/orchestrate.sh" .
  cp "$SRC/prompts/"*.md prompts/
  cp "$HERE/fake-claude" test/claude       # ← 이름이 'claude' 여야 가로챈다
  chmod +x orchestrate.sh test/claude
  echo x > x.txt; git add -A; git commit -qm init
  export PATH="$SANDBOX/test:$PATH"
}

teardown() { cd /; rm -rf "$SANDBOX"; }

# expect <설명> <기대exit코드> -- <env할당들...>
expect() {
  local desc=$1 want=$2; shift 3
  setup
  local got=0
  env "$@" AUTO=1 TEST_CMD="true" ./orchestrate.sh feat >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    green "  PASS  $desc (exit $got)"; PASS=$((PASS+1))
  else
    red   "  FAIL  $desc — 기대 exit $want, 실제 $got"; FAIL=$((FAIL+1))
  fi
  teardown
}

echo "=== 정상 경로 ==="
expect "전부 정상이면 0으로 끝난다" 0 -- FAKE_SCENARIO=ok

echo
echo "=== 게이트가 막아야 하는 것들 ==="
expect "STATUS 라인 없으면 죽는다 (설계)"        2 -- FAKE_SCENARIO_DESIGN=no_status
expect "STATUS 라인 없으면 죽는다 (구현)"        2 -- FAKE_SCENARIO_IMPL=no_status
expect "STATUS 라인 없으면 죽는다 (검증)"        2 -- FAKE_SCENARIO_VERIFY=no_status
expect "산출물 파일 없으면 죽는다"               2 -- FAKE_SCENARIO_DESIGN=no_file
expect "에이전트 에러면 죽는다"                  2 -- FAKE_SCENARIO_DESIGN=agent_error
expect "프로세스가 죽으면 죽는다"                2 -- FAKE_SCENARIO_DESIGN=crash
expect "BLOCKED 는 exit 3 (사람 호출)"           3 -- FAKE_SCENARIO_DESIGN=blocked
expect "구현 BLOCKED 도 exit 3"                  3 -- FAKE_SCENARIO_IMPL=blocked

echo
echo "=== 재시도 루프 ==="
# 테스트가 항상 실패하면 MAX_RETRY 만큼 돌고 죽어야 한다
setup
got=0
env FAKE_SCENARIO=ok AUTO=1 MAX_RETRY=2 TEST_CMD="false" \
  ./orchestrate.sh feat >/dev/null 2>&1 || got=$?
attempts=$(grep -c '^## attempt' .pipeline/feat/FAIL_LOG.md 2>/dev/null | head -1)
attempts=${attempts:-0}
if [ "$got" -eq 2 ] && [ "$attempts" -eq 2 ]; then
  green "  PASS  테스트 계속 실패 → 2회 기록 후 포기 (exit 2)"; PASS=$((PASS+1))
else
  red   "  FAIL  재시도 루프 — exit=$got, FAIL_LOG 기록=$attempts (기대: 2, 2)"; FAIL=$((FAIL+1))
fi
teardown

echo
echo "=== 설계 재사용 ==="
# 이미 DONE 인 DESIGN.md 가 있으면 설계 단계를 아예 호출하지 않아야 한다
setup
mkdir -p .pipeline/feat
printf 'STATUS: DONE\n\n(사람이 이미 검토한 설계)\n' > .pipeline/feat/DESIGN.md
env FAKE_SCENARIO=ok AUTO=1 TEST_CMD="true" ./orchestrate.sh feat >/dev/null 2>&1
if [ ! -f .pipeline/feat/design.result.json ] \
   && grep -q '사람이 이미 검토한 설계' .pipeline/feat/DESIGN.md \
   && [ -f .pipeline/feat/IMPL.md ]; then
  green "  PASS  기존 DESIGN.md 는 재사용되고 덮어쓰이지 않는다"; PASS=$((PASS+1))
else
  red   "  FAIL  설계 재사용 실패 — design 단계가 다시 돌았거나 산출물이 덮어써짐"; FAIL=$((FAIL+1))
fi
teardown

setup
mkdir -p .pipeline/feat
printf 'STATUS: DONE\n\n(사람이 이미 검토한 설계)\n' > .pipeline/feat/DESIGN.md
env FAKE_SCENARIO=ok AUTO=1 FRESH_DESIGN=1 TEST_CMD="true" ./orchestrate.sh feat >/dev/null 2>&1
if [ -f .pipeline/feat/design.result.json ]; then
  green "  PASS  FRESH_DESIGN=1 이면 설계를 다시 뽑는다"; PASS=$((PASS+1))
else
  red   "  FAIL  FRESH_DESIGN=1 인데 설계 단계가 안 돌았다"; FAIL=$((FAIL+1))
fi
teardown

echo
echo "=== 진행 스트림 ==="
# tee 가 원본 스트림을 보존해야 result 추출이 가능하다.
# 스트림이 비면 진행 표시도 죽고 게이트 판정 근거도 사라진다.
setup
env FAKE_SCENARIO=ok AUTO=1 TEST_CMD="true" ./orchestrate.sh feat >/dev/null 2>&1
if grep -q '"type":"assistant"' .pipeline/feat/design.stream.jsonl 2>/dev/null \
   && [ "$(jq -r '.is_error' .pipeline/feat/design.result.json 2>/dev/null)" = "false" ]; then
  green "  PASS  스트림이 보존되고 마지막 result 만 추출된다"; PASS=$((PASS+1))
else
  red   "  FAIL  스트림 보존/추출 실패"; FAIL=$((FAIL+1))
fi
teardown

echo
echo "=== 모델 교체 감시 ==="
setup
env FAKE_SCENARIO=model_swap AUTO=1 TEST_CMD="true" \
  ./orchestrate.sh feat >/dev/null 2>&1
if grep -q '요청 claude-fable-5 → 실제 claude-opus-4-8' .pipeline/feat/MODEL_LOG.md 2>/dev/null; then
  green "  PASS  다른 모델이 돌면 MODEL_LOG 에 기록된다"; PASS=$((PASS+1))
else
  red   "  FAIL  모델 교체가 기록되지 않음"
  echo "         MODEL_LOG 내용:"; sed 's/^/         /' .pipeline/feat/MODEL_LOG.md 2>/dev/null
  FAIL=$((FAIL+1))
fi
teardown

echo
echo "=== 상담역 상태 창구 ==="
setup
env FAKE_SCENARIO=ok AUTO=1 TEST_CMD="true" ./orchestrate.sh feat >/dev/null 2>&1
if grep -q 'phase: DONE' .pipeline/feat/STATE.md 2>/dev/null; then
  green "  PASS  STATE.md 가 최종 상태를 반영한다"; PASS=$((PASS+1))
else
  red   "  FAIL  STATE.md 미갱신"; FAIL=$((FAIL+1))
fi
teardown

echo
echo "════════════════════════════"
printf "  통과 %d / 실패 %d\n" "$PASS" "$FAIL"
echo "════════════════════════════"
[ "$FAIL" -eq 0 ]
