#!/usr/bin/env bash
# UserPromptSubmit 훅: /seed:plant · resume을 입력한 세션을 실행의 주인으로 기록한다.
# Stop · AskUserQuestion 훅은 주인 세션에만 적용되므로, 같은 폴더의 다른 세션은 방해받지 않는다.
. "$(dirname "$0")/lib.sh"

printf '%s' "$SV_INPUT" | grep -Eq '"prompt"[[:space:]]*:[[:space:]]*"[[:space:]]*/(seed:)?(plant|resume)([[:space:]"]|$)' || exit 0
[ -n "$SV_SESSION" ] || exit 0

mkdir -p "$SV_DIR"
printf '%s\n' "$SV_SESSION" > "$SV_OWNER"
rm -f "$SV_DIR/.stop-guard"
exit 0
