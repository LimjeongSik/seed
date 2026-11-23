#!/usr/bin/env bash
# seed 상태 전이 · 훅 회귀 테스트. 임시 프로젝트에서 세션 A · B를 흉내 낸다.
#   bash tests/run.sh
set -u
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
S="$PLUGIN/scripts"
pass=0 fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

new_project() {
  P="$(mktemp -d)/proj"
  mkdir -p "$P"
  export CLAUDE_PROJECT_DIR="$P"
  cd "$P" || exit 1
}
# as <session> <seed.sh 인자...>
as() { local s="$1"; shift; CLAUDE_CODE_SESSION_ID="$s" bash "$S/seed.sh" "$@" >/dev/null 2>&1; }
# hook <script> <session> [extra json]
hook() { printf '{"session_id":"%s","cwd":"%s"%s}' "$2" "$P" "${3:-}" | bash "$S/$1" 2>/dev/null; }
st() { sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$P/.seed/state.json"; }
G() { git -c user.name=t -c user.email=t@t "$@"; }

echo "1. 실행 소유권"
new_project
as A start 3
check "A가 시작하면 주인은 A" '[ "$(cat .seed/owner)" = A ] && [ "$(st status)" = running ]'
as B start; code=$?
check "실행 중에 B가 시작하면 거절(2)" '[ $code -eq 2 ]'
check "거절된 시작은 소유권을 바꾸지 않음" '[ "$(cat .seed/owner)" = A ]'
as B resume; code=$?
check "실행 중에 B가 재개하면 거절(2)" '[ $code -eq 2 ] && [ "$(cat .seed/owner)" = A ]'
as B set phase plan; code=$?
check "주인이 아닌 B는 상태를 못 바꿈(3)" '[ $code -eq 3 ] && [ "$(st phase)" = toolbox ]'
check "A의 Stop 훅은 막음" 'hook stop.sh A | grep -q block'
check "B의 Stop 훅은 막지 않음" '[ -z "$(hook stop.sh B)" ]'
check "A의 질문은 차단, B는 허용" 'hook deny-ask.sh A | grep -q deny && [ -z "$(hook deny-ask.sh B)" ]'

echo "2. 중단 · 재개 · 오래된 에이전트"
as A set awaiting developer agents agent-111
as B stop; code=$?
check "다른 세션에서도 중단 가능" '[ $code -eq 0 ] && [ "$(st status)" = stopped ] && [ -z "$(st awaiting)" ]'
check "중단 뒤 A의 Stop 훅은 막지 않음" '[ -z "$(hook stop.sh A)" ]'
check "중단 뒤 A의 역할 에이전트 도구 호출은 차단" 'hook guard-agent.sh A ",\"agent_id\":\"x\",\"agent_type\":\"seed:developer\"" | grep -q deny'
check "중단 뒤 A의 하위 에이전트도 차단(30분 이내)" 'hook guard-agent.sh A ",\"agent_id\":\"y\",\"agent_type\":\"general-purpose\"" | grep -q deny'
check "A의 메인 대화 도구 호출은 허용" '[ -z "$(hook guard-agent.sh A)" ]'
out="$(CLAUDE_CODE_SESSION_ID=B bash "$S/seed.sh" resume 2>&1)"
check "B가 재개하면 running · 주인 B · run 2" '[ "$(st status)" = running ] && [ "$(cat .seed/owner)" = B ] && [ "$(st run)" = 2 ]'
check "재개 시 이전 에이전트 ID를 알려 줌" 'printf "%s" "$out" | grep -q agent-111'
check "재개 뒤에도 A의 역할 에이전트는 차단" 'hook guard-agent.sh A ",\"agent_id\":\"x\",\"agent_type\":\"seed:tester\"" | grep -q deny'
check "B의 에이전트는 허용" '[ -z "$(hook guard-agent.sh B ",\"agent_id\":\"z\",\"agent_type\":\"seed:tester\"")" ]'
check "재개 뒤 Stop 훅은 B에만 적용" 'hook stop.sh B | grep -q block && [ -z "$(hook stop.sh A)" ]'

as B stop
as B resume
check "같은 세션의 stopped → resume도 running으로 복원" '[ "$(st status)" = running ] && [ "$(st run)" = 3 ]'
check "같은 세션 재개 뒤 새 에이전트는 허용" '[ -z "$(hook guard-agent.sh B ",\"agent_id\":\"z2\",\"agent_type\":\"seed:tester\"")" ]'
check "같은 세션 재개 뒤 이전 run의 에이전트 z는 차단" 'hook guard-agent.sh B ",\"agent_id\":\"z\",\"agent_type\":\"seed:tester\"" | grep -q deny'

echo "2b. 에이전트의 실행 소속"
ag() { hook guard-agent.sh "$1" ",\"agent_id\":\"$2\",\"agent_type\":\"${3:-seed:developer}\""; }
start_ag() { hook agent-start.sh "$1" ",\"agent_id\":\"$2\",\"agent_type\":\"${3:-seed:developer}\"" >/dev/null; }
check "진행 중 처음 본 에이전트는 허용(지금 run에 묶임)" '[ -z "$(ag B old-busy)" ]'
start_ag B old-quiet                       # 생성만 되고 도구를 쓰지 않은 에이전트
start_ag B old-sub general-purpose         # 역할 에이전트가 고용한 하위 에이전트
as B set agents old-listed
as B stop
check "중단 직후 옛 에이전트 차단" '[ -n "$(ag B old-busy)" ]'
as B resume
check "같은 세션 재개 뒤에도 옛 에이전트(도구 사용) 차단" 'ag B old-busy | grep -q deny'
check "같은 세션 재개 뒤에도 옛 에이전트(생성만) 차단" 'ag B old-quiet | grep -q deny'
check "옛 하위 에이전트도 차단" 'ag B old-sub general-purpose | grep -q deny'
check "set agents로 등록한 옛 에이전트도 차단" 'ag B old-listed | grep -q deny'
start_ag B new-role
check "재개 뒤 새로 만든 에이전트는 허용" '[ -z "$(ag B new-role)" ] && [ -z "$(ag B new-sub general-purpose)" ]'
check "메인 대화는 계속 허용" '[ -z "$(hook guard-agent.sh B)" ]'

echo "3. stalled"
rm -f .seed/.stop-guard
for i in 1 2 3 4; do hook stop.sh B >/dev/null; done
check "변화 없이 4번 막히면 stalled" '[ "$(st status)" = stalled ]'
as B resume
check "stalled → resume은 running" '[ "$(st status)" = running ]'
as A resume; code=$?
check "running 중 다른 세션 재개는 거절" '[ $code -eq 2 ]'

echo "4. 사이클 상한 · 개선 회차"
as B improve; as B improve; as B improve; code=$?
check "개선은 2회까지(3회째 4)" '[ $code -eq 4 ] && [ "$(st improve_round)" = 2 ]'
as B next-cycle design
check "다음 사이클: cycle 2 · improve_round 0 · phase design" '[ "$(st cycle)" = 2 ] && [ "$(st improve_round)" = 0 ] && [ "$(st phase)" = design ] && [ -d .seed/cycles/02 ]'
as B next-cycle plan
as B next-cycle plan; code=$?
check "max_cycles(3)에서 다음 사이클은 거절(4)" '[ $code -eq 4 ] && [ "$(st cycle)" = 3 ]'
as B set phase bogus; code=$?
check "알 수 없는 phase 거절" '[ $code -eq 3 ]'
as B set last 'a "quoted", value'
check "따옴표 · 쉼표가 든 last도 JSON이 깨지지 않음" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" .seed/state.json'
as B finish
check "finish → done, 이후 Stop 훅 해제" '[ "$(st status)" = done ] && [ -z "$(hook stop.sh B)" ]'
as A start 2
check "done 뒤 새 시작은 기존 .seed 보관" '[ "$(st status)" = running ] && [ -n "$(ls .seed-archive)" ] && [ "$(cat .seed/owner)" = A ]'

echo "5. 기존 사용자 변경 보존"
new_project
G init -q
printf 'v1\n' > user.txt; printf 'keep\n' > staged.txt
G add . && G commit -qm init
printf 'user-edit\n' > user.txt          # 사용자가 고치던 파일
printf 'draft\n' > notes.txt             # 사용자의 untracked 파일
printf 'staged-edit\n' > staged.txt && G add staged.txt   # 사용자가 스테이징해 둔 변경
as A start
printf 'app\n' > app.js                  # seed가 만든 파일
printf 'user-edit\nseed-edit\n' > user.txt  # seed가 사용자 파일도 고침(겹침)
out="$(CLAUDE_CODE_SESSION_ID=A bash "$S/seed.sh" stage 2>&1)"
check "겹친 파일을 알려 줌" 'printf "%s" "$out" | grep -q user.txt'
G commit -qm "seed: 사이클 1" --pathspec-from-file=.seed/.commit-paths --pathspec-file-nul
files="$(G show --name-only --format= HEAD)"
check "seed 파일과 .seed 기록은 커밋" 'printf "%s\n" "$files" | grep -qx app.js && printf "%s\n" "$files" | grep -qx .seed/state.json'
check "사용자 파일 · untracked · 스테이징 변경은 커밋 안 함" '! printf "%s\n" "$files" | grep -qxE "user.txt|notes.txt|staged.txt"'
check "사용자 스테이징 변경은 그대로 staged" 'G diff --cached --name-only | grep -qx staged.txt'
check "사용자 작업 내용 보존" 'grep -q user-edit user.txt && [ -f notes.txt ] && grep -q staged-edit staged.txt'
check "owner · baseline은 커밋 안 함" '! printf "%s\n" "$files" | grep -qE "\.seed/(owner|baseline|\.commit-paths)"'

echo "5b. 깨끗한 저장소(빈 기준선)"
new_project
G init -q
printf 'v1\n' > readme.txt && G add . && G commit -qm init
as A start
check "기준선이 비어 있음" '[ ! -s .seed/baseline ]'
printf 'app\n' > app.js; printf 'v2\n' > readme.txt
as A stage; code=$?
G commit -qm c1 --pathspec-from-file=.seed/.commit-paths --pathspec-file-nul
files="$(G show --name-only --format= HEAD)"
check "새 파일 · 수정 파일 모두 커밋" '[ $code -eq 0 ] && printf "%s\n" "$files" | grep -qx app.js && printf "%s\n" "$files" | grep -qx readme.txt'
check "커밋 뒤 작업 트리 깨끗(.seed 제외)" '[ -z "$(G status --porcelain -- . ":(exclude).seed")" ]'

echo "5c. 재시작 뒤 지난 실행 에이전트"
start_ag A prev-run
as A finish
as A start
check "지난 실행(run 1)의 에이전트는 새 run 1에서도 차단" 'ag A prev-run | grep -q deny'

echo "6. 새 저장소에서 첫 커밋"
new_project
printf 'old\n' > existing.txt
as A start
printf 'new\n' > new.txt
as A stage
G commit -qm first --pathspec-from-file=.seed/.commit-paths --pathspec-file-nul; code=$?
check "첫 커밋 성공, 기존 파일은 제외" '[ $code -eq 0 ] && G show --name-only --format= HEAD | grep -qx new.txt && ! G show --name-only --format= HEAD | grep -qx existing.txt'

echo "7. 검증 대상 해시"
as A verified
check "검증 직후 변경 없음(0)" 'CLAUDE_CODE_SESSION_ID=A bash "$S/seed.sh" check-verified >/dev/null'
printf 'gate-fix\n' >> new.txt
check "gate가 코드를 고치면 재검증 필요(1)" '! CLAUDE_CODE_SESSION_ID=A bash "$S/seed.sh" check-verified >/dev/null'
printf 'log\n' >> .seed/log.md
as A verified
printf 'more log\n' >> .seed/log.md
check ".seed 기록 변경은 재검증 대상 아님" 'CLAUDE_CODE_SESSION_ID=A bash "$S/seed.sh" check-verified >/dev/null'

echo
echo "통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ]
