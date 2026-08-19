#!/usr/bin/env bash
# 파이프라인 전용 worktree 를 만든다.
#
# 왜 필요한가:
#   각 단계가 --permission-mode acceptEdits 로 돌기 때문에, 메인 체크아웃에서 돌리면
#   사람이 편집 중인 파일을 에이전트가 그대로 덮어쓴다. worktree 는 같은 저장소의
#   다른 체크아웃이라 원본 워킹트리가 무손상으로 남는다.
#
# 사용법:
#   ./pipeline-worktree.sh <feature-name> [base-ref]
#   ./pipeline-worktree.sh p0-fixes              # HEAD 에서 분기
#   ./pipeline-worktree.sh p0-fixes develop      # develop 에서 분기
#
# 정리:
#   git worktree remove ../<repo>-pipeline-<feature>
#   git branch -D pipeline/<feature>

set -euo pipefail

FEATURE="${1:?사용법: ./pipeline-worktree.sh <feature-name> [base-ref]}"
BASE="${2:-HEAD}"

MAIN="$(git rev-parse --show-toplevel)"
WT="$(dirname "$MAIN")/$(basename "$MAIN")-pipeline-$FEATURE"
BRANCH="pipeline/$FEATURE"

log() { printf '\033[1;36m[wt]\033[0m %s\n' "$*" >&2; }

# ── 미커밋 변경 경고 ─────────────────────────────────
# worktree 는 커밋된 내용만 가져간다. 손에 든 변경은 따라가지 않는다.
# 이걸 모르고 돌리면 "왜 내가 고친 게 없어졌지"가 아니라
# "에이전트가 내가 이미 고친 걸 또 고쳤네"로 나타난다 — 후자가 훨씬 늦게 발견된다.
if [ -n "$(git -C "$MAIN" status --porcelain)" ]; then
  log "⚠ 메인에 커밋 안 된 변경이 있다 — worktree 에는 따라가지 않는다:"
  git -C "$MAIN" status --short | sed 's/^/     /' >&2
  log "  옮기려면 (추적 중인 파일만):"
  log "    git -C '$MAIN' diff > /tmp/wip-$FEATURE.patch"
  log "    git -C '$WT' apply /tmp/wip-$FEATURE.patch"
  if [ "${WT_YES:-0}" = "1" ]; then
    log "  (WT_YES=1 — 확인 없이 계속)"
  else
    printf '  이대로 계속? (y/N) ' >&2
    # tty 가 없으면(백그라운드·CI) read 가 rc=1 로 끝나고 set -e 가 그 자리에서
    # exit 1 을 낸다. 없는 tty 는 "y 를 누르지 않았다"와 같은 뜻이므로 n 으로 떨군다.
    read -r ans < /dev/tty || ans=n
    case "$ans" in y|Y) ;; *) log "중단"; exit 1 ;; esac
  fi
fi

# ── worktree 생성 ────────────────────────────────────
if [ -d "$WT" ]; then
  log "이미 있음 → 재사용: $WT"
elif git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  log "브랜치 $BRANCH 가 이미 있다 → 그걸 체크아웃한다"
  git -C "$MAIN" worktree add "$WT" "$BRANCH"
else
  log "브랜치 $BRANCH 를 $BASE 에서 새로 만든다"
  git -C "$MAIN" worktree add -b "$BRANCH" "$WT" "$BASE"
fi

# ── 설계 산출물 이어받기 ─────────────────────────────
# 설계는 최상위 모델이 뽑는 가장 비싼 산출물이다. 사람이 이미 검토해서 DONE 인 게
# 메인에 있으면 worktree 에서 다시 뽑지 않는다.
# 재사용 조건은 orchestrate.sh 와 같은 기준(STATUS: DONE)을 쓴다 —
# 파일 존재만 보면 중간에 죽어 반쯤 쓰인 설계를 물려받는다.
SRC_DESIGN="$MAIN/.pipeline/$FEATURE/DESIGN.md"
if [ -f "$SRC_DESIGN" ] \
   && [ "$(grep -m1 '^STATUS:' "$SRC_DESIGN" | awk '{print $2}')" = "DONE" ]; then
  mkdir -p "$WT/.pipeline/$FEATURE"
  cp "$SRC_DESIGN" "$WT/.pipeline/$FEATURE/DESIGN.md"
  log "기존 DESIGN.md 이어받음 → 설계 단계는 건너뛴다 (새로 뽑으려면 FRESH_DESIGN=1)"
fi

# ── gitignore 된 근거 자료 반입 ──────────────────────
# HANDOFF.json 은 .gitignore 대상(서버 취약점·기기 식별자 포함, 원격이 공개라 로컬 전용)이라
# worktree 에 따라오지 않는다. 그런데 design/judge/impl 프롬프트가 이걸 근거 자료로 읽는다 —
# 없으면 설계가 근거 없이 돌고, 그 사실이 산출물에는 드러나지 않는다.
#
# 읽기 전용으로 복사한다. 프롬프트가 "읽기만" 이라고 말하는 것과 별개로,
# acceptEdits 로 도는 에이전트를 상대로는 파일 권한이 유일하게 확실한 제약이다.
for f in HANDOFF.json HANDOFF-ARCHIVE.json; do
  if [ -f "$MAIN/$f" ]; then
    cp "$MAIN/$f" "$WT/$f"
    chmod 444 "$WT/$f"
    log "근거 자료 반입: $f (읽기 전용)"
  fi
done

# ── Flutter 의존성 ───────────────────────────────────
# .dart_tool/ 은 gitignore 라 worktree 에 따라오지 않는다.
# pub get 없이 돌리면 첫 TEST_CMD 에서 죽고, 원인이 파이프라인처럼 보인다.
if [ -f "$WT/pubspec.yaml" ]; then
  log "flutter pub get (worktree 는 .dart_tool 을 물려받지 못한다)"
  (cd "$WT" && flutter pub get) || log "⚠ pub get 실패 — 수동으로 돌린 뒤 파이프라인을 시작해라"
fi

cat >&2 <<EOF

  worktree : $WT
  브랜치   : $BRANCH  (base: $BASE)

  실행:
    cd "$WT" && ./orchestrate.sh $FEATURE
    cd "$WT" && AUTO=1 ./orchestrate.sh $FEATURE          # 사람 게이트 없이

  상담역 (다른 터미널):
    cd "$WT" && ./advisor.sh $FEATURE

  결과 확인 / 가져오기:
    git -C "$MAIN" diff $BRANCH -- lib test
    git -C "$MAIN" merge $BRANCH

  정리:
    git -C "$MAIN" worktree remove "$WT"
    git -C "$MAIN" branch -D $BRANCH
EOF
