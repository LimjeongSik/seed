#!/usr/bin/env bash
# seed 훅 공용 함수. 각 훅 스크립트가 source 한다.
# 외부 도구(jq 등) 없이 동작하도록 JSON은 sed로 한 줄씩 읽는다.

SV_INPUT="$(cat)"

# json_field <key> <text> — 문자열 값 하나를 꺼낸다
json_field() {
  printf '%s\n' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

SV_ROOT="${CLAUDE_PROJECT_DIR:-$(json_field cwd "$SV_INPUT")}"
SV_ROOT="${SV_ROOT:-$PWD}"
SV_DIR="$SV_ROOT/.seed"
SV_STATE="$SV_DIR/state.json"
SV_OWNER="$SV_DIR/owner"
SV_SESSION="$(json_field session_id "$SV_INPUT")"

# state <key> — state.json에서 값 하나를 읽는다 (문자열 · 숫자)
state() {
  [ -f "$SV_STATE" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\}.*/\1/p" "$SV_STATE" | head -n 1
}

# 이 세션이 실행의 주인인지. 주인 기록이 없으면 지금 세션이 맡는다.
is_owner() {
  [ -n "$SV_SESSION" ] || return 0
  if [ ! -s "$SV_OWNER" ]; then
    printf '%s\n' "$SV_SESSION" > "$SV_OWNER" 2>/dev/null
    return 0
  fi
  [ "$(cat "$SV_OWNER")" = "$SV_SESSION" ]
}

# 이 세션에서 실행이 진행 중인지
is_active() {
  [ "$(state status)" = "running" ] && is_owner
}
