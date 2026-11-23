#!/usr/bin/env bash
# PreToolUse 훅: 지금 실행(run)에 속하지 않은 에이전트가 파일을 고치지 못하게 막는다.
# 메인 대화의 도구 호출은 막지 않는다(에이전트 호출만).
# - 에이전트는 처음 본 시점(SubagentStart · 첫 도구 호출 · seed.sh set agents)의 run에 묶인다.
#   하위 에이전트도 생성될 때의 run에 묶이므로 실행 번호를 이어받는다.
# - 주인 세션이 진행 중이면: 지금 run에 묶인 에이전트만 허용한다. 같은 세션에서 재개해도 옛 에이전트는 막힌다.
# - 중단되었거나 다른 세션으로 넘어간 세션이면: seed 역할 에이전트(seed:*)는 계속,
#   그 밖의 에이전트(역할 에이전트가 고용한 하위 에이전트 등)는 소유권을 잃은 뒤 30분 동안 막는다.
. "$(dirname "$0")/lib.sh"

aid="$(json_field agent_id "$SV_INPUT")"
[ -n "$aid" ] || exit 0
[ -f "$SV_STATE" ] || exit 0

deny() {
  reason="seed 실행이 중단되었거나 재개 · 이관되어 이 에이전트는 지금 실행에 속하지 않는다. 작업이 반영되지 않으니 파일을 고치지 말고 지금까지 한 일만 짧게 반환하고 끝내라."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

run="$(state run)"
if is_active; then
  bind_agent "$aid" "$run"
  [ "$(agent_run "$aid")" = "$run" ] && exit 0
  deny
fi

since="$(revoked_since "$SV_SESSION")"
[ -n "$since" ] || exit 0
bind_agent "$aid" "$run"  # 중단 중에 처음 본 에이전트도 지금(옛) run 소속으로 묶어, 재개 뒤에도 막히게 한다
case "$(json_field agent_type "$SV_INPUT")" in
  seed:*) ;;
  *) [ $(($(date +%s) - since)) -lt 1800 ] || exit 0 ;;
esac
deny
