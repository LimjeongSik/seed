#!/usr/bin/env bash
# seed 훅 공용 함수. 각 훅 스크립트가 source 한다. 훅 입력(JSON)을 stdin에서 읽는다.

SV_INPUT="$(cat)"

# json_field <key> <text> — 문자열 값 하나를 꺼낸다
json_field() {
  printf '%s\n' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

SV_ROOT="${CLAUDE_PROJECT_DIR:-$(json_field cwd "$SV_INPUT")}"
SV_ROOT="${SV_ROOT:-$PWD}"
SV_SESSION="$(json_field session_id "$SV_INPUT")"
. "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# 이 세션에서 실행이 진행 중인지
is_active() {
  [ "$(state status)" = "running" ] && is_owner
}
