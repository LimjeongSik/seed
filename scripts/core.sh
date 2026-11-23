#!/usr/bin/env bash
# seed 상태 공용 함수. 훅(lib.sh)과 상태 전이 스크립트(seed.sh)가 source 한다.
# 호출하는 쪽이 SV_ROOT, SV_SESSION을 정한 뒤 source 한다. 외부 도구(jq 등) 없이 동작한다.

SV_DIR="$SV_ROOT/.seed"
SV_STATE="$SV_DIR/state.json"
SV_OWNER="$SV_DIR/owner"
SV_REVOKED="$SV_DIR/.revoked"
SV_AGENTS="$SV_DIR/.agents"
SV_KEYS="status run cycle phase awaiting agents max_cycles improve_round verified_tree started_at updated_at last"
SV_NUM_KEYS=" run cycle max_cycles improve_round "

# state <key> — state.json에서 값 하나를 읽는다 (문자열 · 숫자)
state() {
  [ -f "$SV_STATE" ] || return 0
  sed -n "s/^[[:space:]{]*\"$1\"[[:space:]]*:[[:space:]]*//p" "$SV_STATE" | head -n 1 |
    sed 's/[[:space:]]*}\{0,1\}[[:space:]]*$//; s/,$//; s/^"\(.*\)"$/\1/; s/\\"/"/g; s/\\\\/\\/g'
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s; }

now_iso() { date +%Y-%m-%dT%H:%M:%S%z | sed 's/\([0-9][0-9]\)$/:\1/'; }

# 실행 잠금. 프로젝트 밖(TMPDIR)에 두어 .seed를 옮기는 동안에도 유지된다.
SV_LOCK="${TMPDIR:-/tmp}/seed-lock-$(printf '%s' "$SV_ROOT" | cksum | awk '{print $1}')"
lock() {
  local i=0
  while ! mkdir "$SV_LOCK" 2>/dev/null; do
    # 30초 넘은 잠금은 죽은 프로세스가 남긴 것으로 본다
    if [ $(( $(date +%s) - $(mtime "$SV_LOCK") )) -gt 30 ]; then rm -rf "$SV_LOCK"; continue; fi
    i=$((i + 1))
    [ "$i" -gt 80 ] && { echo "seed: 상태 잠금을 얻지 못했습니다 ($SV_LOCK)" >&2; return 1; }
    sleep 0.1
  done
  trap 'rmdir "$SV_LOCK" 2>/dev/null' EXIT
}
unlock() { rmdir "$SV_LOCK" 2>/dev/null; trap - EXIT; }

# state.json을 S_<key> 변수로 읽는다
load_state() {
  local k
  for k in $SV_KEYS; do eval "S_$k=\"\$(state $k)\""; done
}

json_escape() { printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# S_<key> 변수를 state.json에 쓴다 (키 하나에 한 줄, 원자적 교체)
save_state() {
  local k v n=0 total tmp="$SV_STATE.tmp.$$"
  S_updated_at="$(now_iso)"
  set -- $SV_KEYS
  total=$#
  {
    echo "{"
    for k in $SV_KEYS; do
      n=$((n + 1))
      eval "v=\"\$S_$k\""
      case "$SV_NUM_KEYS" in
        *" $k "*) printf '  "%s": %s' "$k" "${v:-0}" ;;
        *) printf '  "%s": "%s"' "$k" "$(json_escape "$v")" ;;
      esac
      [ "$n" -lt "$total" ] && printf ','
      printf '\n'
    done
    echo "}"
  } > "$tmp" && mv "$tmp" "$SV_STATE"
}

owner() { [ -s "$SV_OWNER" ] && cat "$SV_OWNER"; }

# 이 세션이 실행의 주인인지. 주인 기록이 없으면 아무도 주인이 아니다(자동으로 가져가지 않는다).
is_owner() {
  [ -n "$SV_SESSION" ] && [ "$(owner)" = "$SV_SESSION" ]
}

# 소유권을 잃은 세션을 기록한다: 그 세션에서 돌던 에이전트가 계속 파일을 고치지 못하게 훅이 막는다.
revoke() {
  [ -n "$1" ] || return 0
  printf '%s %s\n' "$1" "$(date +%s)" >> "$SV_REVOKED"
}

# 에이전트를 실행 번호에 묶는다. 처음 묶인 실행 번호가 유지된다(재개해도 옛 에이전트는 옛 실행 소속).
# agent_run <agent_id> — 묶인 실행 번호. 없으면 빈 값
agent_run() {
  [ -n "$1" ] && [ -f "$SV_AGENTS" ] || return 0
  awk -v a="$1" '$1 == a { print $2; exit }' "$SV_AGENTS"
}
# bind_agent <agent_id> <run> — 아직 묶이지 않았을 때만 기록
bind_agent() {
  [ -n "$1" ] && [ -n "$2" ] && [ -d "$SV_DIR" ] || return 0
  [ -n "$(agent_run "$1")" ] && return 0
  printf '%s %s\n' "$1" "$2" >> "$SV_AGENTS"
}

# revoked_since <session> — 소유권을 잃은 시각(epoch). 없으면 빈 값
revoked_since() {
  [ -f "$SV_REVOKED" ] || return 0
  awk -v s="$1" '$1 == s { t = $2 } END { if (t) print t }' "$SV_REVOKED"
}
