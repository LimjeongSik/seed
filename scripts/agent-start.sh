#!/usr/bin/env bash
# SubagentStart 훅: 주인 세션에서 생긴 에이전트를 생성 시점의 실행 번호(run)에 묶는다.
# 도구를 한 번도 쓰지 않은 채 중단 · 재개를 넘긴 에이전트도 옛 실행 소속으로 가려낼 수 있다.
. "$(dirname "$0")/lib.sh"

aid="$(json_field agent_id "$SV_INPUT")"
[ -n "$aid" ] && [ -f "$SV_STATE" ] || exit 0
is_owner || [ -n "$(revoked_since "$SV_SESSION")" ] || exit 0
bind_agent "$aid" "$(state run)"
exit 0
