#!/usr/bin/env bash
# Stop 훅: 실행이 끝나기 전에는 턴 종료를 막고 다음 단계를 진행하게 한다.
# - 에이전트 결과를 기다리는 중(awaiting)이면 막지 않는다
# - state.json이 바뀌지 않은 채 3번 연속 막혔으면 진행이 멈춘 것으로 보고 stalled로 표시한 뒤 놓아준다
. "$(dirname "$0")/lib.sh"

is_active || exit 0
[ -n "$(state awaiting)" ] && exit 0

guard="$SV_DIR/.stop-guard"
sum="$(cksum < "$SV_STATE" | awk '{print $1}')"
prev=""
count=0
[ -f "$guard" ] && read -r prev count < "$guard"
if [ "$sum" = "$prev" ]; then count=$((count + 1)); else count=1; fi

if [ "$count" -gt 3 ]; then
  if lock; then
    load_state
    if [ "$S_status" = "running" ]; then
      S_status=stalled
      save_state
    fi
    unlock
  fi
  rm -f "$guard"
  echo "seed: 진행이 멈춰 stalled로 표시했습니다. /seed:resume 으로 이어갈 수 있습니다." >&2
  exit 0
fi

printf '%s %s\n' "$sum" "$count" > "$guard"
reason="seed 실행 중 (사이클 $(state cycle) · 단계 $(state phase)). 사용자에게 확인을 구하거나 멈추지 말고 seed:cycle 스킬 절차대로 다음 단계를 진행하라. 상태는 .seed/state.json, 이력은 .seed/log.md에 있다. 상태는 seed.sh로만 바꾸고, 에이전트 결과를 기다릴 때는 seed.sh set awaiting으로 표시한다. 실제로 완성했다면 마무리 절차를 밟고 seed.sh finish로 끝낸다."
printf '{"decision":"block","reason":"%s"}\n' "$reason"
