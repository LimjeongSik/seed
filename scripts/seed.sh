#!/usr/bin/env bash
# seed 상태 전이 스크립트. 오케스트레이터는 state.json을 직접 고치지 않고 이 스크립트로만 바꾼다.
# 모든 전이는 잠금 아래에서 검증 후 원자적으로 쓴다. 프로젝트 루트에서 실행한다.
#
#   start [max_cycles]        새 실행 시작 (기존 .seed 보관, 소유권 획득, git 기준선 기록)
#   resume                    stopped · stalled 실행을 이 세션이 이어받음 (run 번호 증가)
#   stop [사유]               중단 (어느 세션에서든 가능). 멈춰야 할 에이전트 ID를 출력
#   set <key> <value> ...     phase · awaiting · agents · last 갱신 (주인 세션만)
#   improve                   개선 회차 +1 (최대 2회, 넘으면 종료 코드 4)
#   next-cycle <plan|design>  다음 사이클로 (max_cycles 도달 시 종료 코드 4, 바뀌지 않음)
#   verified                  현재 작업 트리를 "테스터가 검증한 대상"으로 기록
#   check-verified            검증 뒤 코드가 바뀌었는지 (같으면 0, 바뀌었으면 1)
#   stage                     seed가 만든 변경만 스테이징하고 커밋 경로 목록(.seed/.commit-paths)을 만든다
#   finish                    완료 처리 (status done)
#   show                      상태 출력
#
# 종료 코드: 0 성공 · 1 대상 없음 · 2 다른 세션이 진행 중 · 3 주인이 아님/전이 불가 · 4 상한 도달

set -u
SV_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
SV_SESSION="${CLAUDE_CODE_SESSION_ID:-}"
SV_PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SV_PLUGIN/scripts/core.sh"

die() { local code="$1"; shift; echo "seed: $*" >&2; exit "$code"; }
log_line() { [ -f "$SV_DIR/log.md" ] && printf -- '- %s %s\n' "$(now_iso)" "$1" >> "$SV_DIR/log.md"; }
two() { printf '%02d' "$1"; }

# 주인 세션이 running 상태로 진행 중일 때만 허용
require_owner() {
  [ -f "$SV_STATE" ] || die 1 "진행 중인 실행이 없습니다 (.seed/state.json 없음)"
  load_state
  [ "$S_status" = "running" ] || die 3 "status가 $S_status 입니다. /seed:resume 으로 이어받은 뒤 진행하세요"
  if [ -n "$SV_SESSION" ] && [ "$(owner)" != "$SV_SESSION" ]; then
    die 3 "이 세션은 실행의 주인이 아닙니다 (주인: $(owner)). 이 세션에서 진행하려면 /seed:stop 후 /seed:resume"
  fi
}

# ── git 헬퍼 ────────────────────────────────────────────────
in_git() { git -C "$SV_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
git_top() { git -C "$SV_ROOT" rev-parse --show-toplevel; }
git_prefix() { git -C "$SV_ROOT" rev-parse --show-prefix; }

# 프로젝트 루트 아래의 변경 경로(저장소 최상위 기준)를 한 줄씩. seed 소유 경로(.seed, .seed-archive)는 뺀다.
changed_paths() {
  local p xy entry orig
  p="$(git_prefix)"
  git -C "$SV_ROOT" status --porcelain=v1 -z --untracked-files=all -- . |
    while IFS= read -r -d '' entry; do
      xy="${entry:0:2}"
      printf '%s\n' "${entry:3}"
      case "$xy" in R* | C*) IFS= read -r -d '' orig && printf '%s\n' "$orig" ;; esac
    done |
    while IFS= read -r f; do
      case "$f" in "${p}.seed/"* | "${p}.seed-archive/"*) continue ;; esac
      printf '%s\n' "$f"
    done
}

# stdin의 경로마다 "내용해시<TAB>경로". 지워진 경로는 해시 "-"
fingerprint() {
  local top tmp
  top="$(git_top)"
  tmp="$(mktemp -d)"
  cat > "$tmp/all"
  while IFS= read -r f; do [ -f "$top/$f" ] && printf '%s\n' "$f"; done < "$tmp/all" > "$tmp/exist"
  if [ -s "$tmp/exist" ]; then
    awk -v t="$top" '{ print t "/" $0 }' "$tmp/exist" | git -C "$top" hash-object --stdin-paths > "$tmp/hash"
    paste "$tmp/hash" "$tmp/exist"
  fi
  grep -vxF -f "$tmp/exist" "$tmp/all" | awk '{ print "-\t" $0 }'
  rm -rf "$tmp"
}

# 프로젝트(.seed 제외)의 현재 작업 트리 해시
tree_hash() {
  in_git || return 0
  local idx
  idx="$(mktemp)" && rm -f "$idx"
  (cd "$SV_ROOT" && GIT_INDEX_FILE="$idx" git add -A -- . ':(exclude).seed' ':(exclude).seed-archive' >/dev/null 2>&1 &&
    GIT_INDEX_FILE="$idx" git write-tree)
  rm -f "$idx"
}

# ── 명령 ────────────────────────────────────────────────────
cmd_start() {
  local max="${1:-10}" ts revoked="" agents=""
  case "$max" in '' | *[!0-9]*) die 3 "max_cycles는 숫자여야 합니다: $max" ;; esac
  [ "$max" -ge 1 ] || die 3 "max_cycles는 1 이상이어야 합니다"
  lock || exit 3
  case "$(state status)" in
    running | stalled) die 2 "진행 중인 실행이 있습니다 (status $(state status)). /seed:resume 으로 이어가거나 /seed:stop 후 다시 시작하세요" ;;
  esac
  if [ -d "$SV_DIR" ]; then
    [ -f "$SV_REVOKED" ] && revoked="$(cat "$SV_REVOKED")"
    # 지난 실행의 에이전트는 새 실행 번호와 겹치지 않게 "x"(지난 실행)로 넘긴다
    [ -f "$SV_AGENTS" ] && agents="$(awk '{ print $1, "x" }' "$SV_AGENTS")"
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$SV_ROOT/.seed-archive"
    mv "$SV_DIR" "$SV_ROOT/.seed-archive/$ts" || die 3 ".seed 보관 실패"
    echo "기존 .seed를 .seed-archive/$ts 로 보관했습니다."
  fi
  mkdir -p "$SV_DIR/rules" "$SV_DIR/product" "$SV_DIR/architecture" "$SV_DIR/design" "$SV_DIR/cycles/01"
  cp "$SV_PLUGIN/shared/autonomy.md" "$SV_PLUGIN/shared/workspace.md" "$SV_DIR/rules/"
  echo "# 결정 기록" > "$SV_DIR/decisions.md"
  echo "# 인계 사항" > "$SV_DIR/handoff.md"
  printf '# 진행 기록\n\n' > "$SV_DIR/log.md"
  printf '%s\n' owner .stop-guard .revoked .agents baseline .commit-paths > "$SV_DIR/.gitignore"
  [ -n "$revoked" ] && printf '%s\n' "$revoked" > "$SV_REVOKED"
  [ -n "$agents" ] && printf '%s\n' "$agents" > "$SV_AGENTS"
  printf '%s\n' "$SV_SESSION" > "$SV_OWNER"

  # git: 저장소가 아니면 만든다. 시작 시점의 기존 변경(사용자 작업)을 기준선으로 남겨 seed 커밋에서 뺀다.
  if command -v git >/dev/null 2>&1; then
    in_git || git -C "$SV_ROOT" init -q
    changed_paths | fingerprint > "$SV_DIR/baseline"
  fi

  S_status=running S_run=1 S_cycle=1 S_phase=toolbox S_awaiting="" S_agents="" S_max_cycles="$max"
  S_improve_round=0 S_verified_tree="" S_started_at="$(now_iso)" S_last="실행 시작"
  save_state
  log_line "실행 시작 (run 1 · 최대 $max 사이클)"
  unlock
  echo "시작: run 1 · 사이클 1 · 단계 toolbox · 최대 $max 사이클"
  if [ -s "$SV_DIR/baseline" ]; then
    echo "기존 미커밋 변경 $(wc -l < "$SV_DIR/baseline" | tr -d ' ')개는 사용자 작업으로 보고 seed 커밋에서 뺍니다 (.seed/baseline)."
  fi
  [ -n "$SV_SESSION" ] || echo "경고: 세션 ID를 알 수 없어 Stop · 질문 차단 훅이 적용되지 않습니다." >&2
}

cmd_resume() {
  [ -f "$SV_STATE" ] || die 1 "진행 중인 실행이 없습니다. /seed:plant <서비스>로 시작하세요"
  lock || exit 3
  load_state
  local cur
  cur="$(owner)"
  case "$S_status" in
    done) die 3 "이미 완료된 실행입니다. 보고서: .seed/final-report.md" ;;
    running)
      if [ -n "$cur" ] && [ "$cur" = "$SV_SESSION" ]; then
        unlock
        echo "이 세션이 이미 진행 중입니다: run $S_run · 사이클 $S_cycle · 단계 $S_phase · awaiting '${S_awaiting}' · agents '${S_agents}'"
        return 0
      fi
      [ -n "$cur" ] && die 2 "다른 세션($cur)이 진행 중입니다. 그 세션이 이미 끝났다면 /seed:stop 후 /seed:resume 하세요"
      ;;
  esac
  local stale="$S_agents"
  if [ "$cur" != "$SV_SESSION" ]; then
    revoke "$cur"
    printf '%s\n' "$SV_SESSION" > "$SV_OWNER"
  fi
  S_status=running S_run=$((S_run + 1)) S_awaiting="" S_agents=""
  save_state
  log_line "재개 (run $S_run · 사이클 $S_cycle · 단계 $S_phase)"
  unlock
  echo "재개: run $S_run · 사이클 $S_cycle · 단계 $S_phase · 개선 ${S_improve_round}회차"
  [ -n "$stale" ] && echo "이전 실행의 에이전트(멈췄는지 확인 후 결과는 무시): $stale"
  return 0
}

cmd_stop() {
  [ -f "$SV_STATE" ] || die 1 "진행 중인 실행이 없습니다"
  lock || exit 3
  load_state
  [ "$S_status" = "done" ] && die 3 "이미 완료된 실행입니다"
  local agents="$S_agents" was="$S_status"
  revoke "$(owner)"
  # agents는 남겨 둔다: 다른 세션이 재개할 때 이전 에이전트가 멈췄는지 확인하는 데 쓴다
  S_status=stopped S_awaiting=""
  save_state
  log_line "${1:-사용자 요청}으로 중단 (사이클 $S_cycle · 단계 $S_phase)"
  unlock
  echo "중단: 사이클 $S_cycle · 단계 $S_phase (이전 상태 $was). 이어가기: /seed:resume"
  [ -n "$agents" ] && echo "멈출 에이전트: $agents"
  return 0
}

cmd_set() {
  [ $(($# % 2)) -eq 0 ] && [ $# -gt 0 ] || die 3 "사용법: set <key> <value> [<key> <value> ...]"
  lock || exit 3
  require_owner
  while [ $# -gt 0 ]; do
    case "$1" in
      phase)
        case "$2" in toolbox | plan | design | build | verify | improve | gate | close | review | final) ;;
          *) die 3 "알 수 없는 phase: $2" ;; esac
        S_phase="$2" ;;
      awaiting) S_awaiting="$2" ;;
      agents)
        S_agents="$2"
        local a
        for a in $(printf '%s' "$2" | tr ',' ' '); do bind_agent "$a" "$S_run"; done ;;
      last) S_last="$2" ;;
      *) die 3 "set으로 바꿀 수 없는 키: $1 (cycle · status 등은 전용 명령으로)" ;;
    esac
    shift 2
  done
  save_state
  unlock
}

cmd_improve() {
  lock || exit 3
  require_owner
  [ "$S_improve_round" -ge 2 ] && die 4 "개선은 사이클당 최대 2회입니다. 남은 이슈는 다음 사이클로 넘깁니다"
  S_improve_round=$((S_improve_round + 1)) S_phase=improve
  save_state
  unlock
  echo "개선 ${S_improve_round}회차"
}

cmd_next_cycle() {
  case "${1:-}" in plan | design) ;; *) die 3 "사용법: next-cycle <plan|design>" ;; esac
  lock || exit 3
  require_owner
  [ "$S_cycle" -ge "$S_max_cycles" ] && die 4 "최대 사이클($S_max_cycles)에 도달했습니다. 마무리로 가세요"
  S_cycle=$((S_cycle + 1)) S_improve_round=0 S_phase="$1" S_awaiting="" S_agents="" S_verified_tree=""
  mkdir -p "$SV_DIR/cycles/$(two "$S_cycle")"
  save_state
  log_line "사이클 $S_cycle 시작 (단계 $1)"
  unlock
  echo "사이클 $S_cycle / $S_max_cycles · 단계 $1"
}

cmd_verified() {
  lock || exit 3
  require_owner
  S_verified_tree="$(tree_hash)"
  save_state
  unlock
  echo "검증 대상 기록: ${S_verified_tree:-(git 없음)}"
}

cmd_check_verified() {
  [ -f "$SV_STATE" ] || die 1 "진행 중인 실행이 없습니다"
  local want cur
  want="$(state verified_tree)"
  cur="$(tree_hash)"
  [ -z "$cur" ] && { echo "git 없음: 비교 생략"; return 0; }
  [ -z "$want" ] && { echo "검증 기록 없음: 재검증 필요"; return 1; }
  if [ "$want" = "$cur" ]; then echo "검증 뒤 변경 없음"; return 0; fi
  echo "검증 뒤 코드가 바뀌었습니다: 재검증 필요"
  return 1
}

cmd_stage() {
  lock || exit 3
  require_owner
  in_git || die 1 "git 저장소가 아닙니다"
  local top base="$SV_DIR/baseline" list n=0 overlap
  top="$(git_top)"
  list="$(mktemp)"
  [ -f "$base" ] || : > "$base"
  # TAKE: seed가 만든 변경 · OVERLAP: 시작 전부터 사용자가 바꾸던 파일을 seed도 고친 경우(커밋하지 않음)
  changed_paths | fingerprint |
    awk -F'\t' -v bf="$base" 'FILENAME == bf { b[$2] = $1; next }
      ($2 in b) { if (b[$2] != $1) print "OVERLAP\t" $2; next }
      { print "TAKE\t" $2 }' "$base" - > "$list"
  overlap="$(awk -F'\t' '$1 == "OVERLAP" { print $2 }' "$list")"
  {
    awk -F'\t' '$1 == "TAKE" { print $2 }' "$list"
    # .seed 기록은 항상 seed 소유
    git -C "$SV_ROOT" ls-files -z -m -o -d --exclude-standard -- .seed .seed-archive | tr '\0' '\n' |
      awk -v p="$(git_prefix)" '{ print p $0 }'
  } | sort -u | while IFS= read -r f; do
    [ -n "$f" ] && printf ':(top,literal)%s\0' "$f"
  done > "$SV_DIR/.commit-paths"
  rm -f "$list"
  n="$(tr -cd '\0' < "$SV_DIR/.commit-paths" | wc -c | tr -d ' ')"
  if [ -n "$overlap" ]; then
    echo "시작 전부터 있던 사용자 변경과 겹쳐 커밋에서 뺀 파일 (작업 트리에는 남아 있음):"
    printf '%s\n' "$overlap" | sed 's/^/  /'
  fi
  if [ "$n" -eq 0 ]; then unlock; echo "커밋할 seed 변경이 없습니다"; return 1; fi
  (cd "$SV_ROOT" && git add -A --pathspec-from-file=.seed/.commit-paths --pathspec-file-nul) || die 3 "git add 실패"
  unlock
  echo "커밋 대상 ${n}개를 스테이징했습니다. 다음 명령으로 이 경로만 커밋하세요:"
  echo "  git commit -m \"<메시지>\" --pathspec-from-file=.seed/.commit-paths --pathspec-file-nul"
}

cmd_finish() {
  lock || exit 3
  require_owner
  S_status=done S_phase=final S_awaiting="" S_agents=""
  save_state
  log_line "완료 (사이클 $S_cycle)"
  unlock
  echo "완료 처리했습니다."
}

cmd_show() {
  [ -f "$SV_STATE" ] || { echo "진행 중인 실행이 없습니다"; return 1; }
  cat "$SV_STATE"
  if is_owner; then echo "주인: 이 세션"; else echo "주인: $(owner || echo 없음) (이 세션 아님)"; fi
}

cmd="${1:-show}"
[ $# -gt 0 ] && shift
case "$cmd" in
  start) cmd_start "$@" ;;
  resume) cmd_resume ;;
  stop) cmd_stop "$@" ;;
  set) cmd_set "$@" ;;
  improve) cmd_improve ;;
  next-cycle) cmd_next_cycle "$@" ;;
  verified) cmd_verified ;;
  check-verified) cmd_check_verified ;;
  stage) cmd_stage ;;
  finish) cmd_finish ;;
  show) cmd_show ;;
  *) die 3 "알 수 없는 명령: $cmd" ;;
esac
