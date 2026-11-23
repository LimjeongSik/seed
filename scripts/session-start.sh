#!/usr/bin/env bash
# SessionStart 훅: 압축 뒤에는 실행을 이어가게 하고, 새 세션에는 끝나지 않은 실행이 있음을 알린다.
. "$(dirname "$0")/lib.sh"

status="$(state status)"
case "$status" in running | stalled | stopped) ;; *) exit 0 ;; esac

where="사이클 $(state cycle) · 단계 $(state phase)"
if [ "$status" = "running" ] && is_owner; then
  if [ "$(json_field source "$SV_INPUT")" = "compact" ]; then
    context="seed 실행이 진행 중이다 ($where). 컨텍스트가 압축되었으니 seed:cycle 스킬을 다시 불러 6장 재개 절차대로 .seed/state.json과 .seed/log.md를 읽고, 사용자에게 묻지 말고 현재 단계부터 이어서 진행하라."
  else
    context="이 세션이 주인인 seed 실행이 진행 중이다 ($where). 이어가려면 /seed:resume."
  fi
elif [ "$status" = "running" ]; then
  context="이 프로젝트에서 다른 세션이 seed 실행을 진행 중이다 ($where). 그 세션이 이미 끝났다면 /seed:stop 후 /seed:resume으로 이어받을 수 있다. 진행 상황은 /seed:status."
else
  context="이 프로젝트에 끝나지 않은 seed 실행이 있다 (상태 $status, $where). 이어가려면 /seed:resume, 진행 상황은 /seed:status."
fi
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$context"
