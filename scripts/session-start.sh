#!/usr/bin/env bash
# SessionStart 훅: 압축 뒤에는 실행을 이어가게 하고, 새 세션에는 끝나지 않은 실행이 있음을 알린다.
. "$(dirname "$0")/lib.sh"

status="$(state status)"
[ "$status" = "running" ] || [ "$status" = "stalled" ] || exit 0

where="사이클 $(state cycle) · 단계 $(state phase)"
if [ "$(json_field source "$SV_INPUT")" = "compact" ] && [ "$status" = "running" ] && is_owner; then
  context="seed 실행이 진행 중이다 ($where). 컨텍스트가 압축되었으니 seed:cycle 스킬을 다시 불러 .seed/state.json과 .seed/log.md를 읽고, 사용자에게 묻지 말고 현재 단계부터 이어서 진행하라."
else
  context="이 프로젝트에 끝나지 않은 seed 실행이 있다 (상태 $status, $where). 사용자가 이어가길 원하면 /seed:resume, 진행 상황은 /seed:status."
fi
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$context"
