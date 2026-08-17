#!/usr/bin/env bash
# 실행 역할 터미널 (터미널 1)
#
# 역할 분리:
#   이 스크립트  = 오케스트레이터. 진행 결정권을 독점한다.
#   advisor.sh   = 상담역. 읽기 전용. 진행 권한 없음.
#   사람         = 유일하게 게이트 버튼을 누르는 주체.
#
# 사용법:
#   ./orchestrate.sh <feature-name>
#   AUTO=1 ./orchestrate.sh <feature-name>     # 사람 게이트 건너뜀 (무인)
#   MAX_RETRY=3 ./orchestrate.sh <feature-name>

set -euo pipefail

# ─────────────────────────────────────────── 설정
ROOT="$(git rev-parse --show-toplevel)"
FEATURE="${1:?사용법: ./orchestrate.sh <feature-name>}"
WORK="$ROOT/.pipeline/$FEATURE"
PROMPTS="$ROOT/prompts"

MAX_RETRY="${MAX_RETRY:-2}"
AUTO="${AUTO:-0}"
# 이미 STATUS: DONE 인 DESIGN.md 가 있으면 설계 단계를 건너뛰고 재사용한다.
# (중단 후 재실행에서 비싼 설계를 다시 만들지 않기 위한 것 — 설계 게이트는 그대로 거친다)
# 설계를 새로 뽑고 싶으면 FRESH_DESIGN=1
FRESH_DESIGN="${FRESH_DESIGN:-0}"
TEST_CMD="${TEST_CMD:-flutter analyze && flutter test}"

# ── 모델 티어링 ──────────────────────────────────────
# 별칭 대신 풀 ID를 박는다. 별칭은 어느 날 조용히 다른 모델을 가리킨다.
#
#   설계  : 최상위. 여기가 틀리면 뒤가 전부 낭비다.
#   구현  : 설계가 확정돼 있으면 난이도가 내려간다. 중간 티어로 충분.
#   검증  : 다시 최상위. "설계에서 벗어난 지점 찾기"는 적대적 추론이라 구현보다 어렵다.
#
# FALLBACK_* 은 가용성 폴백(529 과부하 등) 전용이다.
# 안전 분류기에 의한 모델 교체는 이걸로 막을 수 없다 — MODEL_LOG.md 로 감시한다.
MODEL_DESIGN="${MODEL_DESIGN:-claude-fable-5}"
MODEL_IMPL="${MODEL_IMPL:-claude-opus-5}"
MODEL_VERIFY="${MODEL_VERIFY:-claude-fable-5}"

FALLBACK_DESIGN="${FALLBACK_DESIGN:-claude-opus-5,claude-sonnet-5}"
FALLBACK_IMPL="${FALLBACK_IMPL:-claude-sonnet-5}"
FALLBACK_VERIFY="${FALLBACK_VERIFY:-claude-opus-5,claude-sonnet-5}"

MODEL_LOG=""   # WORK 확정 후 아래에서 설정

mkdir -p "$WORK"
FAIL_LOG="$WORK/FAIL_LOG.md"     # append-only
STATE="$WORK/STATE.md"           # 상담역이 읽는 유일한 실시간 창구
MODEL_LOG="$WORK/MODEL_LOG.md"   # 요청 모델 vs 실제 실행 모델
touch "$FAIL_LOG" "$MODEL_LOG"

export FEATURE WORK ROOT

log() { printf '\033[1;36m[orch]\033[0m %s\n' "$*" >&2; }
die() { state "DIED" "$*"; printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 2; }

# ─────────────────────────────────────────── 상담역용 상태 브로드캐스트
# 셸은 대화를 못 한다. 대신 상태를 파일로 흘려서 상담역이 읽게 한다.
state() {
  local phase=$1 note=${2:-}
  cat > "$STATE" <<EOF
# 파이프라인 상태 (셸이 자동 생성 — 사람이 편집하지 말 것)

- feature: $FEATURE
- phase: $phase
- attempt: ${ATTEMPT:-0} / $((MAX_RETRY + 1))
- pid: $$
- updated: $(date -Iseconds)
- note: $note

## 지금까지 생성된 산출물
$(ls -1 "$WORK"/*.md 2>/dev/null | sed 's|.*/|- |' || echo "- (없음)")

## 마지막 테스트 출력 (tail 20)
\`\`\`
$(tail -20 "$WORK/test_out.txt" 2>/dev/null || echo "(아직 없음)")
\`\`\`
EOF
}

# ─────────────────────────────────────────── 단계 실행기
# run_stage <이름> <모델> <폴백체인> <프롬프트파일> <산출물경로>
#
# stream-json 으로 받아 진행 상황(도구 호출·중간 텍스트)을 실시간으로 흘리고,
# 스트림 마지막의 result 이벤트만 뽑아 게이트 판정에 쓴다.
# (--output-format json 은 완료까지 무출력이라 UX가 나빠서 교체함)
run_stage() {
  local name=$1 model=$2 fallback=$3 prompt_file=$4 artifact=$5
  local out="$WORK/$name.result.json" stream="$WORK/$name.stream.jsonl" code=0

  state "RUNNING:$name" "model=$model"
  log "▶ $name (model=$model, fallback=$fallback)"

  set +e
  envsubst < "$prompt_file" | claude -p \
    --model "$model" \
    --fallback-model "$fallback" \
    --output-format stream-json \
    --verbose \
    --max-turns 40 \
    --max-budget-usd 5 \
    --permission-mode acceptEdits \
    --append-system-prompt "$(cat "$PROMPTS/_contract.md")" \
    | tee "$stream" \
    | jq --unbuffered -r '
        select(.type? == "assistant") | .message.content[]? |
        if .type == "tool_use" then
          "  ⚙ \(.name)  \((.input.file_path // .input.command // .input.pattern // .input.description // "") | tostring | .[0:90])"
        elif .type == "text" and ((.text // "") | length) > 0 then
          "  💬 \(.text | gsub("\\s+"; " ") | .[0:160])"
        else empty end' >&2
  code=${PIPESTATUS[1]}   # [0]=envsubst [1]=claude [2]=tee [3]=jq — 판정 기준은 claude
  set -e

  [ "$code" -eq 0 ] || die "$name: claude 프로세스 실패 (exit $code)"

  # 스트림 마지막의 result 이벤트 = 기존 --output-format json 이 주던 것과 같은 오브젝트
  jq -s '[.[] | select(.type? == "result")] | last' "$stream" > "$out" 2>/dev/null || true
  [ "$(jq -r 'type' "$out" 2>/dev/null)" = "object" ] \
    || die "$name: 스트림에 result 이벤트가 없음 → $stream 확인"

  [ "$(jq -r '.is_error' "$out")" = "false" ] \
    || die "$name: 에이전트 에러 — $(jq -r '.result' "$out" | head -c 300)"

  log "  \$$(jq -r '.total_cost_usd' "$out") / 턴 $(jq -r '.num_turns' "$out")"

  # ── 모델 교체 감시 ────────────────────────────────
  # 안전 분류기가 걸리면 --model 로 지정한 모델이 아닌 다른 모델이 돈다.
  # 이건 --fallback-model 로 막을 수 없으므로, 막는 대신 기록해서 눈에 띄게 한다.
  # ※ 필드명은 버전마다 다를 수 있다. 첫 실행 후 `jq 'keys' result.json` 으로 확인할 것.
  local actual
  actual=$(jq -r '(.modelUsage // {} | keys | join(",")) // empty' "$out" 2>/dev/null || true)
  [ -z "$actual" ] && actual=$(jq -r '.model // empty' "$out" 2>/dev/null || true)

  if [ -n "$actual" ] && [[ "$actual" != *"$model"* ]]; then
    log "  ⚠ 모델 교체 감지: 요청=$model 실제=$actual"
    echo "- $(date -Iseconds) | $name | 요청 $model → 실제 $actual" >> "$MODEL_LOG"
    if [ "$AUTO" != "1" ]; then
      gate_human "요청한 모델이 안 돌았다. 결과를 신뢰할지 판단해라" "$MODEL_LOG"
    fi
  elif [ -z "$actual" ]; then
    echo "- $(date -Iseconds) | $name | 실제 모델 확인 불가 (필드명 점검 필요)" >> "$MODEL_LOG"
  fi

  # 게이트 1: 산출물 물리적 존재
  [ -f "$artifact" ] || die "$name: 산출물 없음 → $artifact"

  # 게이트 2: 종료 형식
  local verdict
  verdict="$(grep -m1 '^STATUS:' "$artifact" | awk '{print $2}' || true)"
  case "${verdict:-MISSING}" in
    DONE)
      log "  ✔ $name DONE" ;;
    BLOCKED)
      state "BLOCKED:$name" "사람 판단 필요"
      log "  ⛔ $name BLOCKED"
      sed -n '/^BLOCKED_REASON:/,$p' "$artifact" >&2
      printf '\n\033[1;33m→ 터미널 2에서 이렇게 물어봐:\033[0m\n  "%s BLOCKED 났어. 원인 뭐야?"\n\n' "$name" >&2
      exit 3 ;;
    *)
      die "$name: STATUS 라인 없음 또는 형식 위반 (DONE|BLOCKED 필수)" ;;
  esac
}

# ─────────────────────────────────────────── 사람 게이트
# 상담역은 여기에 손댈 수 없다. 오직 사람만 누른다.
gate_human() {
  local msg=$1 file=$2
  [ "$AUTO" = "1" ] && { log "  (AUTO=1 — 게이트 통과: $msg)"; return 0; }

  state "GATE" "$msg"
  cat >&2 <<EOF

$(printf '\033[1;33m[게이트]\033[0m') $msg
  검토 대상: $file
  상담역에게: "$(basename "$file") 봐줘"

  y = 진행   e = 열어보기   n = 중단
EOF
  printf '  > ' >&2
  local ans; read -r ans < /dev/tty
  case "$ans" in
    y|Y) return 0 ;;
    e|E) "${EDITOR:-less}" "$file"; gate_human "$msg" "$file" ;;
    *)   die "사람이 중단함" ;;
  esac
}

# ─────────────────────────────────────────── 파이프라인
ATTEMPT=0
state "START"
log "=== $FEATURE 시작 ==="
log "상담역 띄우려면 다른 터미널에서: ./advisor.sh $FEATURE"

if [ "$FRESH_DESIGN" != "1" ] && [ -f "$WORK/DESIGN.md" ] \
   && [ "$(grep -m1 '^STATUS:' "$WORK/DESIGN.md" | awk '{print $2}')" = "DONE" ]; then
  log "↺ 기존 DESIGN.md 재사용 ($(date -r "$WORK/DESIGN.md" '+%m-%d %H:%M') 생성) — 새로 뽑으려면 FRESH_DESIGN=1"
  state "REUSED:design" "기존 산출물 재사용"
else
  run_stage design "$MODEL_DESIGN" "$FALLBACK_DESIGN" "$PROMPTS/design.md" "$WORK/DESIGN.md"
fi
gate_human "설계 검토 — 여기서 틀리면 뒤가 전부 낭비다" "$WORK/DESIGN.md"

while :; do
  ATTEMPT=$((ATTEMPT + 1))
  log "── 시도 $ATTEMPT/$((MAX_RETRY + 1))"

  run_stage impl   "$MODEL_IMPL"   "$FALLBACK_IMPL"   "$PROMPTS/impl.md"   "$WORK/IMPL.md"
  run_stage verify "$MODEL_VERIFY" "$FALLBACK_VERIFY" "$PROMPTS/verify.md" "$WORK/VERIFY.md"

  # ★ 최종 판정은 셸이 한다. 에이전트에게 안 맡긴다.
  state "TESTING" "$TEST_CMD"
  if (cd "$ROOT" && eval "$TEST_CMD") > "$WORK/test_out.txt" 2>&1; then
    log "✅ 검증 통과 ($TEST_CMD)"
    break
  fi

  log "❌ 테스트 실패"
  tail -30 "$WORK/test_out.txt" >&2
  state "TEST_FAILED" "attempt $ATTEMPT"

  [ "$ATTEMPT" -gt "$MAX_RETRY" ] \
    && die "검증 ${MAX_RETRY}회 재시도 후에도 실패 → $FAIL_LOG"

  {
    echo "## attempt $ATTEMPT — $(date -Iseconds)"
    echo '```'
    tail -60 "$WORK/test_out.txt"
    echo '```'
    echo
  } >> "$FAIL_LOG"

  gate_human "재시도 $((ATTEMPT + 1)) 진행? (상담역에게 FAIL_LOG 물어봐도 됨)" "$FAIL_LOG"
done

state "DONE"
log "=== $FEATURE 완료 ==="
log "산출물: $WORK/{DESIGN,IMPL,VERIFY}.md"
