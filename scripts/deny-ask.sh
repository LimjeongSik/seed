#!/usr/bin/env bash
# PreToolUse(AskUserQuestion) 훅: 실행 중에는 사용자에게 질문하지 못하게 한다.
. "$(dirname "$0")/lib.sh"

is_active || exit 0

reason="seed 실행 중에는 사용자에게 묻지 않는다. .seed/rules/autonomy.md 2장의 기준으로 직접 정하고 .seed/decisions.md에 D-NNN으로 기록한 뒤 진행하라."
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
