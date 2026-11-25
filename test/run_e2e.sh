#!/bin/bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"
image="${JIG_E2E_IMAGE:-}"
projects='^jig-(run|smoke)_acme_shop'

if [ -z "$image" ]; then
  echo "run_e2e: skipped: set JIG_E2E_IMAGE to a local Docker image with bash, git, node and timeout to run jig end to end"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "run_e2e: skipped: Docker is not running"
  exit 0
fi

failures=0
checks=0

fail() {
  failures=$(( failures + 1 ))
  echo "FAIL: $*"
}

equals() {
  local name="$1" got="$2" want="$3"
  checks=$(( checks + 1 ))
  [ "$got" = "$want" ] || fail "$name: got \"$got\", expected \"$want\""
}

has_line() {
  local name="$1" file="$2" line="$3"
  checks=$(( checks + 1 ))
  grep -q -x -F -e "$line" "$file" 2>/dev/null || fail "$name: no line \"$line\" in $file"
}

lacks() {
  local name="$1" file="$2" text="$3"
  checks=$(( checks + 1 ))
  ! grep -q -F -e "$text" "$file" 2>/dev/null || fail "$name: \"$text\" is in $file"
}

bytes() {
  LC_ALL=C wc -c | tr -d ' '
}

leftovers() {
  {
    docker ps -a --format '{{.Label "com.docker.compose.project"}}'
    docker volume ls --format '{{.Label "com.docker.compose.project"}}'
    docker network ls --format '{{.Label "com.docker.compose.project"}}'
  } | grep -E "$projects"
}

remove_leftovers() {
  local project
  for project in $(leftovers | sort -u); do
    docker ps -a -q --filter "label=com.docker.compose.project=$project" | xargs docker rm -f >/dev/null 2>&1
    docker volume ls -q --filter "label=com.docker.compose.project=$project" | xargs docker volume rm >/dev/null 2>&1
    docker network ls -q --filter "label=com.docker.compose.project=$project" | xargs docker network rm >/dev/null 2>&1
  done
}

test_images() {
  {
    docker images -q --no-trunc --filter label=jig.repo=acme/shop
    docker images -q --no-trunc --filter label=jig.repo=acme/other
  } | sort -u
}

remove_images() {
  local ids
  ids="$(test_images)"
  [ -z "$ids" ] || echo "$ids" | xargs docker rmi -f >/dev/null 2>&1
}

if [ -n "$(leftovers)" ]; then
  echo "run_e2e: compose projects of acme/shop already exist; remove them first:"
  leftovers | sort -u
  exit 1
fi
if [ -n "$(test_images)" ]; then
  echo "run_e2e: images labelled jig.repo=acme/shop or jig.repo=acme/other already exist; remove them first:"
  test_images
  exit 1
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/jig-e2e.XXXXXX")" || exit 1
tmp="$(cd "$tmp" && pwd -P)"
trap 'remove_leftovers; remove_images; chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/gh" "$tmp/plans" "$tmp/profile"
cat >"$tmp/profile/fake-claude" <<'EOF'
#!/bin/sh
set -eu
say() {
  node -e 'process.stdout.write(JSON.stringify({ type: "system", subtype: "fake", msg: process.argv[1] }) + "\n")' "$1"
}
result() {
  node -e 'const [text, models, hostile] = process.argv.slice(1); const usage = {};
    for (const m of models.split(" ")) usage[m] = { costUSD: 0.005 };
    if (hostile) for (let n = 1; n <= 1000; n++) usage[`claude-fake-${String(n).padStart(4, "0")}-${"x".repeat(83)}`] = {};
    const subtype = hostile ? "success\n\u001b]0;title\u0007\u001b[2J## Injected\n- **bold**" : "success";
    process.stdout.write(JSON.stringify({ type: "result", subtype, is_error: false, num_turns: 3,
    total_cost_usd: 0.01, modelUsage: usage, result: text }) + "\n")' "$1" "$models" "${2:-}"
}
check() {
  say "check failed: $1"
  exit 5
}
if grep -q '^CHECK-SECRETS ' /jig/plan.md; then
  say "secrets check: $(node -e 'const crypto = require("crypto"), fs = require("fs"), path = require("path");
    const want = process.argv[1], hash = (b) => crypto.createHash("sha256").update(b).digest("hex");
    let files = "absent";
    if (fs.existsSync("/run/secrets")) {
      const found = [];
      const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p); else found.push(p + (hash(fs.readFileSync(p)) === want ? " holds the value" : ""));
      } };
      walk("/run/secrets");
      files = found.join(" ") || "empty";
    }
    process.stdout.write(`E2E_BUILD_SECRET ${"E2E_BUILD_SECRET" in process.env ? "set" : "unset"}, ` +
      `value in the environment: ${Object.values(process.env).some((v) => hash(v) === want) ? "yes" : "no"}, /run/secrets: ${files}`)' \
    "$(sed -n 's/^CHECK-SECRETS //p' /jig/plan.md)")"
fi
init_model=claude-fake-1
if grep -q -x MODEL-TOKEN /jig/plan.md 2>/dev/null; then init_model="$CLAUDE_CODE_OAUTH_TOKEN"; fi
node -e 'process.stdout.write(JSON.stringify({ type: "system", subtype: "init", model: process.argv[1] }) + "\n")' "$init_model"
prompt=""
args=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) args="$args $1"; shift ;;
  esac
done
say "args:$args"
models="$init_model"
if grep -q -x TWO-MODELS /jig/plan.md; then models="claude-fake-1 claude-fake-mini"; fi
[ "$prompt" = "Implement the plan in /jig/plan.md." ] || check "the prompt is $prompt"
[ -r /jig/plan.md ] || check "no /jig/plan.md"
if touch /jig/plan.md 2>/dev/null; then check "/jig/plan.md is writable"; fi
[ "$(git rev-parse HEAD)" = "${JIG_BASE:-}" ] || check "JIG_BASE is not HEAD"
say "fake claude: the prompt names /jig/plan.md, the plan is read-only, JIG_BASE is HEAD ($JIG_BASE) on $(git branch --show-current)"
if grep -q -x NO-COMMIT /jig/plan.md; then
  printf 'The plan asks for nothing.\n' >JIG_BLOCKED.md
  result "Nothing to do."
elif grep -q -x GITHUB /jig/plan.md; then
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  echo ok >health.txt
  git add .github health.txt
  git commit -q -m "Add a workflow and health.txt"
  result "What changes: a workflow and health.txt."
elif grep -q -x GITHUB-REVERT /jig/plan.md; then
  mkdir -p .github/workflows
  echo 'on: push' >.github/workflows/ci.yml
  git add .github
  git commit -q -m "Add a workflow"
  git rm -q -r .github
  git commit -q -m "Remove the workflow"
  echo ok >health.txt
  git add health.txt
  git commit -q -m "Add health.txt"
  : >left-behind.txt
  result "What changes: health.txt says ok."
elif grep -q -x NOT-FROM-BASE /jig/plan.md; then
  echo ok >health.txt
  git add health.txt
  git reset -q --soft "$(git commit-tree "$(git write-tree)" -m "Start over without the base")"
  result "What changes: health.txt says ok."
elif grep -q -x ECHO-PLAN /jig/plan.md; then
  while IFS= read -r line; do
    say "plan: $line"
  done </jig/plan.md
  echo ok >health.txt
  git add health.txt
  git commit -q -m "Add health.txt"
  result "What changes: health.txt says ok."
elif grep -q -x LEAK-STATUS /jig/plan.md; then
  echo ok >health.txt
  git add health.txt
  git commit -q -m "Add health.txt"
  : >"$CLAUDE_CODE_OAUTH_TOKEN.txt"
  result "What changes: health.txt says ok."
elif grep -q -x OVERSIZED /jig/plan.md; then
  printf '%10000s' '' | tr ' ' '\n' >JIG_BLOCKED.md
  long="$(printf '%240s' '' | tr ' ' x)"
  echo big >big.txt
  echo protected >".jig/protected-$long"
  git add JIG_BLOCKED.md big.txt ".jig/protected-$long"
  git commit -q -m "Add big.txt"
  for n in $(seq 10 69); do
    : >"untracked-$n-$long"
  done
  result "$(node -e 'for (let n = 1; n <= 1500; n++) console.log(`Шаг ${n}: ответ проверен → готово.`)')" hostile
else
  echo ok >health.txt
  git add health.txt
  git commit -q -m "Add health.txt"
  say "agent ran verify: $(cd /workspace && /jig/profile/verify | grep '^verify: JIG_BASE=')"
  result "What changes: health.txt says ok."
fi
EOF
cat >"$tmp/profile/setup" <<'EOF'
#!/bin/sh
set -eu
echo "setup: JIG_BASE=$JIG_BASE HEAD=$(git rev-parse HEAD) branch=$(git branch --show-current)"
EOF
cat >"$tmp/profile/verify" <<'EOF'
#!/bin/sh
set -eu
echo "verify: JIG_BASE=$JIG_BASE"
git cat-file -e "$JIG_BASE^{commit}"
echo "verify: changed since JIG_BASE:" $(git diff --name-only "$JIG_BASE" HEAD)
if [ -e /jig/plan.md ]; then echo "verify: plan mount: present"; else echo "verify: plan mount: absent"; fi
EOF
cat >"$tmp/profile/compose.yml" <<EOF
services:
  app:
    image: $image
    pull_policy: never
    user: "\${JIG_UID:?}:\${JIG_GID:?}"
    command: ["sleep", "infinity"]
    init: true
    network_mode: none
    working_dir: /workspace
    environment:
      HOME: /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - \${JIG_WORKSPACE:?JIG_WORKSPACE must point at the clone}:/workspace
      - ./fake-claude:/usr/local/bin/claude:ro
EOF
printf 'base main\nsetup .jig/setup\nverify .jig/verify\n' >"$tmp/profile/config"
chmod +x "$tmp/profile/fake-claude" "$tmp/profile/setup" "$tmp/profile/verify"

if ! docker run --rm --network none -v "$tmp/profile/fake-claude:/usr/local/bin/claude:ro" --entrypoint sh "$image" -c \
  'for c in bash git node timeout; do command -v "$c" >/dev/null || exit 1; done; [ "$(command -v claude)" = /usr/local/bin/claude ]' \
  >/dev/null 2>&1; then
  echo "run_e2e: $image must be a local image with bash, git, node and timeout on PATH and no claude ahead of /usr/local/bin/claude"
  exit 1
fi

cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_GH_DIR/calls"
[ -z "${FAKE_GH_FORBID:-}" ] || { echo "fake gh: called with deliver branch: $*" >&2; exit 1; }
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo acme/shop; exit 0 ;;
  "pr create")
    head=""; body=""; prev=""
    for a in "$@"; do
      [ "$prev" = --head ] && head="${a#jig/}"
      [ "$prev" = --body-file ] && body="$a"
      prev="$a"
    done
    printf '%s\n' "$@" >"$FAKE_GH_DIR/$head.args"
    cp "$body" "$FAKE_GH_DIR/$head.body"
    echo "https://github.com/acme/shop/pull/1"
    exit 0 ;;
esac
echo "fake gh: unexpected $*" >&2
exit 1
EOF
cat >"$tmp/bin/fake-ssh" <<'EOF'
#!/bin/sh
[ "$1" = git@github.com ] || { echo "fake ssh: unexpected host $1" >&2; exit 1; }
cd "$FAKE_SSH_ROOT" && exec sh -c "$2"
EOF
real_docker="$(command -v docker)"
cat >"$tmp/bin/docker" <<EOF
#!/bin/sh
if [ -n "\${E2E_CALLS:-}" ]; then
  case "\${E2E_BUILD_SECRET-}" in
    "") secret="" ;;
    jig_build_secret_marker_*) secret=marker ;;
    *) secret=secret ;;
  esac
  printf '%s|docker %s\\n' "\$secret" "\$*" >>"\$E2E_CALLS"
fi
exec "$real_docker" "\$@"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/fake-ssh" "$tmp/bin/docker"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL ANTHROPIC_API_KEY BUILDX_BUILDER E2E_BUILD_SECRET
export JIG_MIN_FREE_GB=1
token=e2e0dummy0credential0value
export PATH="$tmp/bin:$PATH" FAKE_GH_DIR="$tmp/gh" JIG_HOME="$tmp/home" JIG_PROFILES="$tmp/profiles"
export GIT_SSH_COMMAND="$tmp/bin/fake-ssh" GIT_SSH_VARIANT=simple FAKE_SSH_ROOT="$tmp/ssh"
export CLAUDE_CODE_OAUTH_TOKEN="$token"

origin="$tmp/ssh/acme/shop.git"
target="$tmp/shop"
git init -q --bare -b main "$origin"
git init -q -b main "$target"
git -C "$target" config user.name "Test Author"
git -C "$target" config user.email test@example.com
git -C "$target" remote add origin git@github.com:acme/shop.git
mkdir "$target/.jig"
cp -p "$tmp/profile/"* "$target/.jig/"
echo shop >"$target/README"
git -C "$target" add -A && git -C "$target" commit -q -m init && git -C "$target" push -q origin main
base="$(git -C "$origin" rev-parse main)"
printf '%s\t\tbranch main of the owner\n' "$base" >"$target/.git/FETCH_HEAD"
owners_fetch_head="$(cat "$target/.git/FETCH_HEAD")"
runs="$JIG_HOME/runs/acme/shop"
shown='$JIG_HOME/runs/acme/shop'
attribution="🤖 Generated with [Claude Code](https://claude.com/claude-code)"

jig() {
  (cd "$target" && E2E_CALLS="$tmp/calls" "$root/bin/jig" "$@") >"$tmp/out" 2>"$tmp/err"
}

fetch_head_kept() {
  equals "$1: FETCH_HEAD in the target checkout is still the owner's" "$(cat "$target/.git/FETCH_HEAD")" "$owners_fetch_head"
}

nothing_pushed() {
  local slug="$1"
  equals "$slug: no branch on origin" "$(git -C "$origin" for-each-ref --format='%(refname)' "refs/heads/jig/$slug")" ""
  equals "$slug: no local branch" "$(git -C "$target" for-each-ref --format='%(refname)' "refs/heads/jig/$slug")" ""
  checks=$(( checks + 1 ))
  [ ! -e "$tmp/gh/$slug.args" ] || fail "$slug: gh pr create ran"
}

pr_args() {
  sed -n 1,10p "$tmp/gh/$1.args"
}

harness_args="--append-system-prompt-file /jig/system-prompt.md"
stream_args="--dangerously-skip-permissions --output-format stream-json --verbose"
fake_meta='success, turns: 3, estimated cost $0.01'

mkdir "$tmp/logs"
printf '%s\n' 'not json' '{"type":"system","subtype":"hook","model":"claude-fake-7"}' \
  '{"type":"system","subtype":"init","model":"claude-fake-1"}' \
  '{"type":"system","subtype":"init","model":"claude-fake-9"}' '{"type":"assistant","message":{"model":"claude-fake-8"}}' \
  '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.12,"modelUsage":{"claude-fake-1":{},"claude-fake-mini":{},"has space":{},"x`y":{},"-dash":{}}}' \
  >"$tmp/logs/1-init-and-result"
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-fake-1"}' >"$tmp/logs/2-no-result"
printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":9,"modelUsage":{"claude-fake-2":{}}}' \
  >"$tmp/logs/3-no-init"
: >"$tmp/logs/4-empty"
long99="$(printf '%99s' '' | tr ' ' b)"
long100="$(printf '%100s' '' | tr ' ' c)"
printf '%s\n' '{"type":"system","subtype":"init","model":"a'"$long99"'"}' \
  '{"type":"result","subtype":"success","num_turns":1,"modelUsage":{"a'"$long100"'":{},"[1m]":{},"sonnet[1m]":{}}}' \
  >"$tmp/logs/5-names"
printf '%s\n' '{"type":"system","subtype":"init","model":"claude\u001b[2J"}' \
  '{"type":"result","subtype":"success\n\u001b]0;title\u0007**bold**","is_error":false,"num_turns":"3","total_cost_usd":-0.5,"modelUsage":{"claude-fake-1":{}}}' \
  >"$tmp/logs/6-bad-values"
usage="$(for n in $(seq 1 1000); do printf '"claude-fake-m%s":{},' "$n"; done)"
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-fake-1"}' \
  '{"type":"result","subtype":"error_during_execution\n# Injected","is_error":true,"num_turns":1000000,"total_cost_usd":1e21,"modelUsage":{"claude-fake-1":{},'"${usage%,}"'}}' \
  >"$tmp/logs/7-error-and-many-models"
printf '%s\n' '{"type":"result","subtype":"'"$(printf '%40s' '' | tr ' ' a)"'","num_turns":999999,"total_cost_usd":999999.99}' \
  >"$tmp/logs/8-limits"
printf '%s\n' '{"type":"result","subtype":"'"$(printf '%41s' '' | tr ' ' a)"'","num_turns":-1,"total_cost_usd":1000000}' \
  >"$tmp/logs/9-past-limits"
equals "the log gives the outcome, turns and cost that fit jig's shape, the first init model and up to five other models with their count" \
  "$(docker run --rm --network none -v "$root/lib/agent-log.js:/jig/agent-log.js:ro" -v "$tmp/logs:/logs:ro" \
    --entrypoint sh "$image" -c 'for f in /logs/*; do echo "== ${f#/logs/}"; node -e "$(cat /jig/agent-log.js)" meta <"$f"; done' 2>&1)" \
  "== 1-init-and-result
success, turns: 4, estimated cost \$0.12
claude-fake-1
1 claude-fake-mini
== 2-no-result

claude-fake-1
0
== 3-no-init
error (error_max_turns), turns: 9

1 claude-fake-2
== 4-empty


0
== 5-names
success, turns: 1
a$long99
1 sonnet[1m]
== 6-bad-values


1 claude-fake-1
== 7-error-and-many-models
error
claude-fake-1
1000 claude-fake-m1 claude-fake-m2 claude-fake-m3 claude-fake-m4 claude-fake-m5
== 8-limits
$(printf '%40s' '' | tr ' ' a), turns: 999999, estimated cost \$999999.99

0
== 9-past-limits


0"

smoke="$JIG_HOME/smoke/acme/shop"
jig smoke
equals "smoke exits 0" "$?" 0
checks=$(( checks + 1 ))
[ ! -e "$smoke/repo" ] || fail "a green smoke removes its clone"
checks=$(( checks + 1 ))
[ ! -e "$smoke/build.log" ] || fail "a smoke of a profile that builds nothing writes no build.log"
checks=$(( checks + 1 ))
[ ! -e "$tmp/gh/calls" ] || fail "smoke runs gh: $(cat "$tmp/gh/calls")"
has_line "setup in smoke gets the checked HEAD as JIG_BASE" "$tmp/out" "setup: JIG_BASE=$base HEAD=$base branch="
has_line "verify in smoke gets the checked HEAD as JIG_BASE" "$tmp/out" "verify: JIG_BASE=$base"
has_line "the diff against JIG_BASE is empty in smoke" "$tmp/out" "verify: changed since JIG_BASE:"
has_line "smoke has no plan" "$tmp/out" "verify: plan mount: absent"

printf '# Add a health file\n\nIssue: #12\n\nWrite ok to health.txt.\n' >"$tmp/plans/add-health.md"
jig run "$tmp/plans/add-health.md"
equals "a clean run exits 0" "$?" 0
equals "pr delivery checks gh's login and its name for the origin URL, then opens the PR" "$(cut -d' ' -f1-6 "$tmp/gh/calls")" \
  "auth status --hostname github.com
repo view git@github.com:acme/shop.git --json nameWithOwner --jq
pr create --repo acme/shop --base main"
has_line "setup starts on the base on the new branch" "$runs/add-health/setup.log" \
  "setup: JIG_BASE=$base HEAD=$base branch=jig/add-health"
has_line "the agent sees the prompt, the read-only plan and JIG_BASE on a branch without a plan commit" \
  "$runs/add-health/claude.log" \
  '{"type":"system","subtype":"fake","msg":"fake claude: the prompt names /jig/plan.md, the plan is read-only, JIG_BASE is HEAD ('"$base"') on jig/add-health"}'
has_line "without a model or an effort jig passes neither" "$runs/add-health/claude.log" \
  '{"type":"system","subtype":"fake","msg":"args: '"$harness_args $stream_args"'"}'
has_line "the terminal names the issue the PR fixes before the agent starts" "$tmp/out" "jig: issue: Fixes #12"
equals "the terminal names pr delivery and Claude Code's defaults before the agent starts" \
  "$(grep -A 1 -x -F 'jig: deliver: pr (pushes jig/add-health and opens a PR)' "$tmp/out")" \
  "jig: deliver: pr (pushes jig/add-health and opens a PR)
jig: agent model: default, effort: default"
has_line "the terminal names the model from the log and the default effort next to turns and cost" "$tmp/out" \
  "jig: agent: $fake_meta, model: claude-fake-1 (default), effort: default"
has_line "the agent's own verify sees JIG_BASE" "$runs/add-health/claude.log" \
  '{"type":"system","subtype":"fake","msg":"agent ran verify: verify: JIG_BASE='"$base"'"}'
has_line "the final verify sees JIG_BASE" "$runs/add-health/verify.log" "verify: JIG_BASE=$base"
has_line "the final verify diffs against JIG_BASE" "$runs/add-health/verify.log" "verify: changed since JIG_BASE: health.txt"
has_line "the final verify sees the plan mount" "$runs/add-health/verify.log" "verify: plan mount: present"
equals "the pushed branch holds only the agent's commit" "$(git -C "$origin" rev-list --count main..jig/add-health)" 1
equals "the pushed branch changes only the agent's file" "$(git -C "$origin" diff --name-only main jig/add-health)" health.txt
equals "a ready PR titled with the plan's heading" "$(pr_args add-health)" "pr
create
--repo
acme/shop
--base
main
--head
jig/add-health
--title
Add a health file"
lacks "the clean PR is not a draft" "$tmp/gh/add-health.args" --draft
fetch_head_kept add-health
body="$tmp/gh/add-health.body"
equals "the PR body starts with Fixes for the plan's issue, then verify and the agent with its model and effort" \
  "$(sed -n 1,4p "$body")" "Fixes #12

- .jig/verify: green
- Agent: exit 0, $fake_meta, model: claude-fake-1 (default), effort: default"
has_line "the log line names the run under JIG_HOME" "$body" "- Log: \`$shown/add-health/claude.log\`"
lacks "the PR body has no host path" "$body" "$tmp"
equals "the plan block comes last, fenced, before the attribution" "$(tail -n 17 "$body")" "## Agent summary

What changes: health.txt says ok.

<details><summary>Plan</summary>

\`\`\`markdown
# Add a health file

Issue: #12

Write ok to health.txt.
\`\`\`

</details>

$attribution"

printf '# Do nothing\n\nNO-COMMIT\n\n**Issue:** #5\n' >"$tmp/plans/nothing-to-do.md"
jig run "$tmp/plans/nothing-to-do.md"
equals "a run without commits exits 3" "$?" 3
has_line "a plan without an Issue line names no issue at launch" "$tmp/out" "jig: issue: none"
has_line "a misplaced Issue line is named in a warning at launch" "$tmp/err" \
  "jig: WARNING: the plan's line 5 is not read as its Issue line: **Issue:** #5 (jig reads \"Issue: <ref>\" only as the first line under the title)"
has_line "a run without commits says so" "$tmp/err" \
  "jig: the agent made no commits on jig/nothing-to-do (agent exit 0): nothing was pushed and no PR was opened."
has_line "a run without commits names the model and effort next to turns and cost" "$tmp/out" \
  "jig: agent: $fake_meta, model: claude-fake-1 (default), effort: default"
has_line "a run without commits points at the uncommitted JIG_BLOCKED.md" "$tmp/out" \
  "jig: the agent left JIG_BLOCKED.md uncommitted: see $runs/nothing-to-do/blocked-worktree.md"
equals "the uncommitted JIG_BLOCKED.md is kept" "$(cat "$runs/nothing-to-do/blocked-worktree.md")" "The plan asks for nothing."
checks=$(( checks + 1 ))
[ ! -e "$runs/nothing-to-do/verify.log" ] || fail "a run without commits runs no final verify"
nothing_pushed nothing-to-do
fetch_head_kept nothing-to-do

printf '# Keep the placeholder\n\nIssue: <ref>\n\nWrite ok to health.txt.\n' >"$tmp/plans/placeholder.md"
jig run "$tmp/plans/placeholder.md"
equals "the template's placeholder in the Issue line stops the run with exit 2" "$?" 2
equals "the placeholder is named as the last thing on the terminal" "$(tail -n 1 "$tmp/err")" \
  "jig: the Issue line of $tmp/plans/placeholder.md still has the template's placeholder (a < or >): write #123 or a tracker ID, or delete the line"
lacks "the placeholder stops the run before the compose project starts" "$tmp/out" "starting compose project"
checks=$(( checks + 1 ))
[ ! -e "$runs/placeholder" ] || fail "the placeholder leaves no run directory"
nothing_pushed placeholder

{
  printf '# Oversized\n\nOVERSIZED\n\n```sh\n'
  for n in $(seq 1 3000); do
    printf 'echo step %s\n' "$n"
  done
} >"$tmp/plans/oversized.md"
jig run "$tmp/plans/oversized.md"
equals "a run with JIG_BLOCKED.md and uncommitted changes exits 1" "$?" 1
has_line "the PR is a draft" "$tmp/gh/oversized.args" --draft
body="$tmp/gh/oversized.body"
equals "a plan without an Issue line: the PR body starts with verify" "$(sed -n 1p "$body")" "- .jig/verify: green"
many="$(for n in 1 2 3 4 5; do printf 'claude-fake-000%s-%s and ' "$n" "$(printf '%83s' '' | tr ' ' x)"; done)995 more"
has_line "a log with control characters in its outcome and 1,000 models gives a short printable agent line" "$tmp/out" \
  "jig: agent: turns: 3, estimated cost \$0.01, model: claude-fake-1 (default), also $many, effort: default"
has_line "the PR's agent line is as short" "$body" \
  "- Agent: exit 0, turns: 3, estimated cost \$0.01, model: claude-fake-1 (default), also $many, effort: default"
has_line "the PR still lists what needs attention" "$body" "## Needs attention"
for f in "$tmp/out" "$tmp/err" "$body"; do
  lacks "no escape character from the log reaches ${f##*/}" "$f" $'\e'
done
checks=$(( checks + 1 ))
size="$(bytes <"$body")"
[ "$size" -le 65536 ] || fail "oversized agent output keeps the PR body within 65,536 bytes: $size bytes"
checks=$(( checks + 1 ))
iconv -f UTF-8 -t UTF-8 "$body" >/dev/null 2>&1 || fail "the cut PR body is valid UTF-8"
checks=$(( checks + 1 ))
size="$(grep '^    > ' "$body" | bytes)"
[ "$size" -le 10001 ] || fail "the quoted JIG_BLOCKED.md stays within 10,000 bytes: $size bytes"
checks=$(( checks + 1 ))
[ "$(grep -c -x '    > ' "$body")" -gt 1400 ] || fail "the quoted JIG_BLOCKED.md keeps the blank lines that fit"
has_line "the quoted JIG_BLOCKED.md says where the whole text is" "$body" \
  "    > (cut: the whole text is in \`$shown/oversized/blocked-branch.md\`)"
equals "50 status lines, each cut to 200 bytes" \
  "$(grep '^?? untracked-' "$body" | awk 'length($0) == 200 && /\.\.\.$/' | wc -l | tr -d ' ')" 50
has_line "the status lines past 50 are counted" "$body" "... and 10 more"
equals "a protected path is listed cut to 200 bytes" \
  "$(grep -c -x '  - `\.jig/protected-x\{182\}\.\.\.`' "$body")" 1
has_line "the cut summary says where the whole message is" "$body" \
  "*The summary is cut here: the whole message is in \`$shown/oversized/summary.md\`.*"
equals "the cut plan sits in a fence longer than its own open fence" \
  "$(grep -n -x -e '<details><summary>Plan (cut)</summary>' -e '````markdown' -e '````' "$body" | cut -d: -f2)" \
  '<details><summary>Plan (cut)</summary>
````markdown
````'
equals "jig's fence closes the cut plan, and the note and the attribution follow outside it" "$(tail -n 7 "$body")" "\`\`\`\`

*The plan is cut here: it has $(bytes <"$tmp/plans/oversized.md") bytes, the whole plan is in \`$shown/oversized/plan.md\`.*

</details>

$attribution"
checks=$(( checks + 1 ))
tail -n 8 "$body" | sed -n 1p | grep -q -x 'echo step [0-9]*' || fail "the plan is cut inside its own open fence"

{
  for n in $(seq 1 2000); do
    printf 'Step %s: keep the handler as it is.\n' "$n"
  done
  printf '\n# %s\n' "$token"
} >"$tmp/plans/late-token.md"
jig run "$tmp/plans/late-token.md"
equals "a plan whose title carries the credential exits 3" "$?" 3
checks=$(( checks + 1 ))
grep -q -F "jig: the CLAUDE_CODE_OAUTH_TOKEN value was found in: plan.md (branch.bundle was removed" "$tmp/err" ||
  fail "the credential in the title is found in the plan's copy: $(cat "$tmp/err")"
lacks "the cut PR body itself never had the credential" "$runs/late-token/pr-body.md" "[REDACTED]"
nothing_pushed late-token

printf '# Add a workflow\n\nGITHUB\n' >"$tmp/plans/github-pr.md"
jig run "$tmp/plans/github-pr.md"
equals "pr delivery of a branch that changes .github/ exits 3" "$?" 3
has_line "pr delivery refuses a branch that changes .github/" "$tmp/err" \
  "jig: jig/github-pr changes paths under .github/ (see $runs/github-pr/branch.patch): a pushed workflow runs with the repository's secrets and write access. Nothing was pushed; the local branch jig/github-pr was deleted."
nothing_pushed github-pr
fetch_head_kept github-pr

mkdir -p "$JIG_PROFILES/acme/shop"
printf 'base main\nsetup .jig/setup\nverify .jig/verify\nmodel opus\neffort high\n' >"$JIG_PROFILES/acme/shop/config"
printf '# Use the settings\n\nIssue: ABC-123\n\nTWO-MODELS\n' >"$tmp/plans/settings.md"
(export JIG_MODEL=claude-fake-2 && jig run "$tmp/plans/settings.md")
equals "a run with a model and an effort exits 0" "$?" 0
has_line "JIG_MODEL overrides the profile's model, and the profile's effort is passed" "$runs/settings/claude.log" \
  '{"type":"system","subtype":"fake","msg":"args: '"$harness_args"' --model claude-fake-2 --effort high '"$stream_args"'"}'
has_line "the terminal names another tracker's reference as text before the agent starts" "$tmp/out" "jig: issue: ABC-123 (as text)"
has_line "the terminal names the requested model and effort with their sources before the agent starts" "$tmp/out" \
  "jig: agent model: claude-fake-2 (from JIG_MODEL), effort: high (from the profile)"
models_text="model: claude-fake-1 (claude-fake-2 from JIG_MODEL), also claude-fake-mini, effort: high (from the profile)"
has_line "the terminal names the model from the log, the requested one and the other models" "$tmp/out" \
  "jig: agent: $fake_meta, $models_text"
equals "another tracker's reference opens the PR body as is" "$(sed -n 1,4p "$tmp/gh/settings.body")" "Issue: ABC-123

- .jig/verify: green
- Agent: exit 0, $fake_meta, $models_text"

printf 'base main\nsetup .jig/setup\nverify .jig/verify\ndeliver branch\n' >"$JIG_PROFILES/acme/shop/config"
export FAKE_GH_FORBID=1
rm -f "$tmp/gh/calls"

handed_over() {
  local slug="$1" commits="$2" files="$3"
  equals "$slug: the branch is in the target checkout" "$(git -C "$target" rev-list --count "main..jig/$slug")" "$commits"
  equals "$slug: the branch changes only the agent's files" "$(git -C "$target" diff --name-only main "jig/$slug")" "$files"
  equals "$slug: no branch on origin" "$(git -C "$origin" for-each-ref --format='%(refname)' "refs/heads/jig/$slug")" ""
  equals "$slug: the target checkout stays on main with a clean worktree and index" \
    "$(git -C "$target" symbolic-ref --short HEAD) $(git -C "$target" status --porcelain)" "main "
  checks=$(( checks + 1 ))
  [ ! -e "$runs/$slug/pr-body.md" ] || fail "$slug: a PR description was written"
}

no_gh() {
  checks=$(( checks + 1 ))
  [ ! -e "$tmp/gh/calls" ] || fail "$1: gh ran with deliver branch: $(cat "$tmp/gh/calls")"
}

attention_items() {
  sed -n '/^## Needs attention$/,/^## Profile$/p' "$1" | sed '1,2d;$d'
}

printf '# Add a health file\n\nIssue: #12\n\nWrite ok to health.txt.\n' >"$tmp/plans/branch-health.md"
jig run "$tmp/plans/branch-health.md"
equals "a clean branch run exits 0" "$?" 0
handed_over branch-health 1 health.txt
no_gh "a clean branch run"
equals "the terminal names branch delivery next to the agent settings before the agent starts" \
  "$(grep -A 1 -x -F 'jig: deliver: branch' "$tmp/out")" "jig: deliver: branch
jig: agent model: default, effort: default"
fetch_head_kept branch-health
has_line "branch delivery tells the agent that jig hands the branch over" "$runs/branch-health/system-prompt.md" \
  "- Commit on the current branch, in small commits. Do not push: jig hands the branch to the owner."
report="$runs/branch-health/report.md"
equals "the report starts with the plan's title, the issue, the repository, the branch, the base, verify and the agent" \
  "$(sed -n 1,9p "$report")" "# Add a health file

Fixes #12

- Repository: $target
- Branch: jig/branch-health (1 commit)
- Base: main at $base
- .jig/verify: green
- Agent: exit 0, $fake_meta, model: claude-fake-1 (default), effort: default"
checks=$(( checks + 1 ))
sed -n 10p "$report" | grep -q -x -e '- Duration: [0-9]*m [0-9]*s in total, agent [0-9]*m [0-9]*s (limit 60 min)' ||
  fail "the report's duration line: $(sed -n 10p "$report")"
equals "the report names the log and the plan copy with host paths, and the commands to read the branch" \
  "$(sed -n 11,17p "$report")" "- Log: \`$runs/branch-health/claude.log\`
- Plan: \`$runs/branch-health/plan.md\`

\`\`\`sh
git -C $target log --oneline $base..jig/branch-health
git -C $target diff $base...jig/branch-health
\`\`\`"
equals "the commands in the report show the agent's commit and its diff" \
  "$(sed -n 15,16p "$report" | while IFS= read -r command; do eval "$command --format=%s --stat=80" 2>&1 | sed -n 1p; done)" \
  "Add health.txt
 health.txt | 1 +"
lacks "a clean report needs no attention" "$report" "## Needs attention"
equals "the report ends with the profile, the harness and the agent's summary, without the plan or an attribution" \
  "$(sed -n '/^## Profile$/,$p' "$report" | grep -e '^## ' -e '^What changes')" "## Profile
## Harness
## Agent summary
What changes: health.txt says ok."
for text in "<details>" "Write ok to health.txt." "Generated with" '$JIG_HOME'; do
  lacks "the report has no $text" "$report" "$text"
done
equals "the terminal ends with the result, verify, the report and the diff command" "$(tail -n 4 "$tmp/out")" \
  "jig: ready: jig/branch-health in $target
jig: .jig/verify: green
jig: report: $report
jig: diff: git -C $target diff $base...jig/branch-health"

printf '# Add a workflow\n\nGITHUB\n' >"$tmp/plans/branch-github.md"
jig run "$tmp/plans/branch-github.md"
equals "a branch run that changes .github/ exits 1" "$?" 1
handed_over branch-github 1 ".github/workflows/ci.yml
health.txt"
no_gh "a branch run with .github/"
equals "the .github/ change is the first item that needs attention" "$(attention_items "$runs/branch-github/report.md")" \
  "- Changes under \`.github/\`, in a commit or in the diff against main: a pushed workflow runs with the repository's secrets and write access, so review them before you push:
  - \`.github/workflows/ci.yml\`"
has_line "the terminal names .github/ as the reason" "$tmp/out" "jig: needs attention (.github/): jig/branch-github in $target"

printf '# Add and remove a workflow\n\nGITHUB-REVERT\n' >"$tmp/plans/branch-revert.md"
jig run "$tmp/plans/branch-revert.md"
equals "a branch run that changes .github/ and reverts it exits 1" "$?" 1
handed_over branch-revert 3 health.txt
no_gh "a branch run with a reverted .github/ change"
equals "the reverted .github/ change comes first, before the uncommitted changes" \
  "$(attention_items "$runs/branch-revert/report.md")" \
  "- Changes under \`.github/\`, in a commit or in the diff against main: a pushed workflow runs with the repository's secrets and write access, so review them before you push:
  - \`.github/workflows/ci.yml\` (changed, then reverted within the branch)
- Uncommitted changes were left in the clone; they are not on the branch and .jig/verify ran without them:

\`\`\`
?? left-behind.txt
\`\`\`"
has_line "the terminal names both reasons, .github/ first" "$tmp/out" \
  "jig: needs attention (.github/; uncommitted changes): jig/branch-revert in $target"

printf '# Do nothing\n\nNO-COMMIT\n' >"$tmp/plans/branch-nothing.md"
jig run "$tmp/plans/branch-nothing.md"
equals "a branch run without commits exits 3" "$?" 3
has_line "a branch run without commits says no branch was fetched" "$tmp/err" \
  "jig: the agent made no commits on jig/branch-nothing (agent exit 0): no branch was fetched into $target."
nothing_pushed branch-nothing
no_gh "a branch run without commits"

printf '# Start over\n\nNOT-FROM-BASE\n' >"$tmp/plans/branch-unrooted.md"
jig run "$tmp/plans/branch-unrooted.md"
equals "a branch run whose branch does not start from the base exits 3" "$?" 3
equals "a branch that does not start from the base stops jig before its credential scan" "$(tail -n 2 "$tmp/err")" \
  "jig: jig/branch-unrooted does not start from main ($base)
jig: run directory kept: $runs/branch-unrooted"
nothing_pushed branch-unrooted
no_gh "a branch run whose branch does not start from the base"
fetch_head_kept branch-unrooted

printf '# Leave the credential\n\nLEAK-STATUS\n' >"$tmp/plans/branch-leak.md"
jig run "$tmp/plans/branch-leak.md"
equals "a branch run whose report would carry the credential exits 3" "$?" 3
checks=$(( checks + 1 ))
grep -q -F "jig: the CLAUDE_CODE_OAUTH_TOKEN value was found in: report.md (branch.bundle was removed" "$tmp/err" ||
  fail "the credential in an uncommitted file name is found in the report: $(cat "$tmp/err")"
nothing_pushed branch-leak
no_gh "a branch run with the credential"
fetch_head_kept branch-leak

printf '# Carry the credential in the plan\n\nThe agent never needs %s.\n' "$token" >"$tmp/plans/branch-plan-leak.md"
jig run "$tmp/plans/branch-plan-leak.md"
equals "a branch run whose plan carries the credential exits 3" "$?" 3
checks=$(( checks + 1 ))
grep -q -F "jig: the CLAUDE_CODE_OAUTH_TOKEN value was found in: plan.md (branch.bundle was removed" "$tmp/err" ||
  fail "branch delivery finds the credential in the plan's copy alone: $(cat "$tmp/err")"
nothing_pushed branch-plan-leak
no_gh "a branch run whose plan carries the credential"

printf '# Name the credential as the model\n\nMODEL-TOKEN\n' >"$tmp/plans/branch-model-token.md"
jig run "$tmp/plans/branch-model-token.md"
equals "a branch run whose log names the credential as its model exits 3" "$?" 3
has_line "the terminal's agent line hides a model name that is the credential" "$tmp/out" \
  "jig: agent: $fake_meta, model: [REDACTED] (default), effort: default"
for f in "$tmp/out" "$tmp/err"; do
  lacks "the credential named as the model does not reach the terminal: ${f##*/}" "$f" "$token"
done
checks=$(( checks + 1 ))
grep -q -F "jig: the CLAUDE_CODE_OAUTH_TOKEN value was found in: report.md (branch.bundle was removed" "$tmp/err" ||
  fail "the report that names the credential as the model is refused: $(cat "$tmp/err")"
nothing_pushed branch-model-token
has_line "the report is redacted in the run directory" "$runs/branch-leak/report.md" "?? [REDACTED].txt"

context="$(docker context show)"
build_id="${tmp##*.}"
built=acme-shop-jig-e2e:latest
overlay="$JIG_PROFILES/acme/shop"
build_secret='acme:ghp_e2e0build/sec&ret.*[x]^$\1'
printf 'base main\nsetup .jig/setup\nverify .jig/verify\ndeliver branch\nbuild-secret E2E_BUILD_SECRET\n' >"$overlay/config"
cat >"$overlay/Dockerfile" <<EOF
FROM $image
ARG E2E_RUN
RUN --mount=type=secret,id=e2e,mode=0444 printf 'build %s sees %s\n' "\$E2E_RUN" "\$(cat /run/secrets/e2e)"
EOF
sed -e "s|^    image: .*|    image: $built\\
    build:\\
      context: .\\
      args:\\
        E2E_RUN: \${E2E_RUN:?}\\
      secrets:\\
        - e2e|" -e '/^    pull_policy: never$/d' "$tmp/profile/compose.yml" >"$tmp/compose-build.yml"
printf 'secrets:\n  e2e:\n    environment: E2E_BUILD_SECRET\n' >>"$tmp/compose-build.yml"
cp "$tmp/compose-build.yml" "$overlay/compose.yml"

image_id() {
  docker image inspect --format '{{.Id}}' "$1" 2>/dev/null
}

no_secret() {
  local f
  for f in "$@"; do
    lacks "the build secret's value is not in ${f#"$tmp/"}" "$f" "$build_secret"
  done
}

printf '# Build\n\nWrite ok to health.txt.\n' >"$tmp/plans/build-missing.md"
(export E2E_RUN=$build_id-missing && jig run "$tmp/plans/build-missing.md")
equals "a run whose build secret is not set exits 2" "$?" 2
equals "the missing build secret is named as the last thing on the terminal" "$(tail -n 1 "$tmp/err")" \
  "jig: the profile's build-secret E2E_BUILD_SECRET is not set: export E2E_BUILD_SECRET before jig builds (jig hands its value only to docker compose, for the build)"
lacks "the missing build secret stops the run before the compose project starts" "$tmp/out" "starting compose project"
checks=$(( checks + 1 ))
[ ! -e "$runs/build-missing" ] || fail "a missing build secret leaves no run directory"
(export E2E_RUN=$build_id-missing E2E_BUILD_SECRET= && jig smoke)
equals "a smoke whose build secret is empty exits 2" "$?" 2
has_line "smoke names the empty build secret" "$tmp/err" \
  "jig: the profile's build-secret E2E_BUILD_SECRET is not set: export E2E_BUILD_SECRET before jig builds (jig hands its value only to docker compose, for the build)"
lacks "the missing build secret stops smoke before the build" "$tmp/out" "building app"

export E2E_BUILD_SECRET="$build_secret"
sed 's|^      HOME: /tmp$|      HOME: /tmp\
      E2E_BUILD_SECRET:|' "$tmp/compose-build.yml" >"$overlay/compose.yml"
printf '# Pass the build secret on\n\nWrite ok to health.txt.\n' >"$tmp/plans/build-env.md"
(export E2E_RUN=$build_id-env && jig run "$tmp/plans/build-env.md")
equals "a run with a build secret in a service's environment exits 2" "$?" 2
equals "the build secret in the environment is named as the last thing on the terminal" "$(tail -n 1 "$tmp/err")" \
  "jig: the build secret E2E_BUILD_SECRET is in the environment of the service app (docker compose config): jig never passes a build secret into a container. Remove it from the service's environment and env_file; the build gets it from a top-level secret with environment: E2E_BUILD_SECRET"
lacks "the build secret in the environment stops the run before the compose project starts" "$tmp/out" "starting compose project"
checks=$(( checks + 1 ))
[ ! -e "$runs/build-env" ] || fail "a build secret in the environment leaves no run directory"
no_secret "$tmp/out" "$tmp/err"
sed 's|^      HOME: /tmp$|      HOME: /tmp\
      TOKEN: x${E2E_BUILD_SECRET}|' "$tmp/compose-build.yml" >"$overlay/compose.yml"
(export E2E_RUN=$build_id-env && jig smoke)
equals "a smoke whose compose project resolves a build secret into another variable exits 2" "$?" 2
equals "the resolved build secret is named as the last thing on the terminal" "$(tail -n 1 "$tmp/err")" \
  "jig: the value of the build secret E2E_BUILD_SECRET reaches the compose project (docker compose config resolves \${E2E_BUILD_SECRET} in it: in an environment value, a build arg, a label or elsewhere): jig never passes a build secret into a container. The build gets it from a top-level secret with environment: E2E_BUILD_SECRET"
no_secret "$tmp/out" "$tmp/err"
sed 's|^      HOME: /tmp$|      HOME: /tmp\
    secrets:\
      - e2e|' "$tmp/compose-build.yml" >"$overlay/compose.yml"
(export E2E_RUN=$build_id-runtime && jig smoke)
equals "a smoke whose app service takes the build secret as a runtime secret exits 2" "$?" 2
equals "the runtime secret is named as the last thing on the terminal" "$(tail -n 1 "$tmp/err")" \
  "jig: the build secret E2E_BUILD_SECRET reaches the service app as its runtime secret e2e (the top-level secret e2e takes environment: E2E_BUILD_SECRET): jig never passes a build secret into a container. Remove e2e from the service's secrets; the build gets it under build: secrets:"
lacks "the runtime secret stops smoke before the build" "$tmp/out" "building app"
cp "$tmp/compose-build.yml" "$overlay/compose.yml"

(export E2E_RUN=$build_id-disk JIG_MIN_FREE_GB=999999 && jig smoke)
equals "a smoke with too little free disk exits 2" "$?" 2
checks=$(( checks + 1 ))
grep -q -x -e "jig: the filesystem of JIG_HOME ($JIG_HOME) has [0-9]*\.[0-9] GiB free, less than JIG_MIN_FREE_GB=999999\. Free space before jig builds (docker system df shows what Docker holds, docker builder prune removes its build cache), or lower JIG_MIN_FREE_GB (0 turns the check off)" "$tmp/err" ||
  fail "the disk refusal says how much is free and what to do: $(cat "$tmp/err")"
lacks "the disk check stops smoke before the build" "$tmp/out" "building app"
(export JIG_MIN_FREE_GB=ten && jig run "$tmp/plans/build-missing.md")
equals "a run with an invalid JIG_MIN_FREE_GB exits 2" "$?" 2
equals "the invalid JIG_MIN_FREE_GB is named" "$(tail -n 1 "$tmp/err")" "jig: JIG_MIN_FREE_GB must be a whole number of GiB (0 turns the check off)"

(export E2E_RUN=$build_id-builder BUILDX_BUILDER=acme-missing-builder && jig smoke)
status=$?
checks=$(( checks + 1 ))
[ "$status" != 0 ] || fail "a smoke with a BUILDX_BUILDER that does not exist must fail"
has_line "a BUILDX_BUILDER that is set is the builder jig names" "$tmp/out" \
  "jig: building app with acme-missing-builder from BUILDX_BUILDER (log: $smoke/build.log)"
checks=$(( checks + 1 ))
grep -q -i -F 'builder "acme-missing-builder"' "$smoke/build.log" ||
  fail "docker compose builds with the BUILDX_BUILDER that is set: $(cat "$smoke/build.log")"

(export E2E_RUN=$build_id-smoke && jig smoke)
equals "a smoke that builds exits 0" "$?" 0
has_line "without BUILDX_BUILDER jig builds with the Docker context's own builder" "$tmp/out" \
  "jig: building app with $context, the builder of the Docker context (log: $smoke/build.log)"
checks=$(( checks + 1 ))
grep -q -F "building with \"$context\" instance" "$smoke/build.log" ||
  fail "docker compose builds with the context's builder: $(cat "$smoke/build.log")"
checks=$(( checks + 1 ))
grep -q -F "build $build_id-smoke sees [REDACTED]" "$tmp/out" || fail "the terminal shows the build's output redacted: $(cat "$tmp/out")"
checks=$(( checks + 1 ))
grep -q -F "build $build_id-smoke sees [REDACTED]" "$smoke/build.log" || fail "build.log has the build's output redacted"
no_secret "$tmp/out" "$tmp/err" "$smoke/build.log"
equals "the built image is labelled with the repository" \
  "$(docker image inspect --format '{{index .Config.Labels "jig.repo"}}' "$built")" acme/shop
checks=$(( checks + 1 ))
[ ! -e "$smoke/repo" ] || fail "a green smoke that builds removes its clone"
smoke_image="$(image_id "$built")"
equals "the image is built once, by jig's build step and not again by up" \
  "$(cat "$tmp/out" "$tmp/err" | grep -c "naming to docker.io/library/$built")" 1

printf '#!/bin/sh\necho "verify: red on purpose"\nexit 3\n' >"$overlay/verify"
chmod +x "$overlay/verify"
(export E2E_RUN=$build_id-smoke && jig smoke)
equals "a red smoke exits with verify's code" "$?" 3
has_line "a red smoke says where its clone stays" "$tmp/err" "jig: the clone stays for a look until the next smoke: $smoke/repo"
checks=$(( checks + 1 ))
[ -d "$smoke/repo/.git" ] || fail "a red smoke keeps its clone"
equals "a cached rebuild gives the same image" "$(image_id "$built")" "$smoke_image"
rm "$overlay/verify"

mkdir "$tmp/other"
printf 'FROM scratch\nCOPY file /file\n' >"$tmp/other/Dockerfile"
other_ids=""
for content in one two; do
  printf '%s\n' "$content" >"$tmp/other/file"
  BUILDX_BUILDER="$context" docker build -q --label jig.repo=acme/other -t acme-other-jig-e2e:latest "$tmp/other" >/dev/null 2>&1
  other_ids="$other_ids $(image_id acme-other-jig-e2e:latest)"
done
other_old="${other_ids# }"
other_old="${other_old%% *}"
equals "another repository's image is dangling before the run" \
  "$(docker images -q --no-trunc --filter dangling=true --filter label=jig.repo=acme/other)" "$other_old"

printf '# Leak the build secret\n\nECHO-PLAN\n\nThe build reads %s.\n' "$build_secret" >"$tmp/plans/build-leak.md"
(export E2E_RUN=$build_id-leak && jig run "$tmp/plans/build-leak.md")
equals "a run whose plan carries the build secret exits 3" "$?" 3
checks=$(( checks + 1 ))
grep -q -F "jig: the E2E_BUILD_SECRET value was found in: plan.md (branch.bundle was removed" "$tmp/err" ||
  fail "the build secret in the plan is found by the scan: $(cat "$tmp/err")"
nothing_pushed build-leak
has_line "the run names the build and its log" "$tmp/out" \
  "jig: building app with $context, the builder of the Docker context (log: $runs/build-leak/build.log)"
checks=$(( checks + 1 ))
grep -q -F "build $build_id-leak sees [REDACTED]" "$runs/build-leak/build.log" || fail "the run's build.log has the build's output redacted"
checks=$(( checks + 1 ))
grep -q -F '"msg":"plan: The build reads [REDACTED]."' "$runs/build-leak/claude.log" ||
  fail "claude.log has the build secret redacted: $(grep 'plan: The build' "$runs/build-leak/claude.log")"
has_line "the redaction names the files and the build secret" "$tmp/err" \
  "jig: WARNING: the E2E_BUILD_SECRET value was found in claude.log plan.md and replaced with [REDACTED] in $runs/build-leak"
no_secret "$tmp/out" "$tmp/err" "$runs/build-leak/build.log" "$runs/build-leak/claude.log" "$runs/build-leak/plan.md"
checks=$(( checks + 1 ))
grep -q -E '^jig: removed the dangling images labelled jig\.repo=acme/shop \(reclaimed [0-9.]+[kMG]?B\)$' "$tmp/out" ||
  fail "the run says it removed the repository's dangling images: $(cat "$tmp/out")"
checks=$(( checks + 1 ))
[ -z "$(image_id "$smoke_image")" ] || fail "the repository's image that the rebuild left dangling is removed"
equals "another repository's dangling image stays" "$(image_id "$other_old")" "$other_old"
leak_image="$(image_id "$built")"

if command -v sha256sum >/dev/null 2>&1; then
  build_sha="$(printf '%s' "$build_secret" | sha256sum | cut -d' ' -f1)"
else
  build_sha="$(printf '%s' "$build_secret" | shasum -a 256 | cut -d' ' -f1)"
fi
printf '# Add a health file\n\nWrite ok to health.txt.\n\nCHECK-SECRETS %s\n' "$build_sha" >"$tmp/plans/build-health.md"
rm -f "$tmp/calls"
(export E2E_RUN=$build_id-health && jig run "$tmp/plans/build-health.md")
equals "a clean run that builds exits 0" "$?" 0
checks=$(( checks + 1 ))
grep -q -F '"msg":"secrets check: E2E_BUILD_SECRET unset, value in the environment: no, /run/secrets: absent"' "$runs/build-health/claude.log" ||
  fail "the agent's container has neither the build secret's variable nor its value: $(grep 'secrets check' "$runs/build-health/claude.log")"
equals "of the compose commands only the build gets the build secret, config gets jig's marker and up runs without either" \
  "$(grep '|docker compose ' "$tmp/calls" | sed -E 's/^([a-z]*)\|docker compose -p jig-run_acme_shop_build-health( -f [^ ]+)+ ([a-z]+).*/\1 \3/' | LC_ALL=C sort -u)" \
  " down
 exec
 restart
 up
marker config
secret build"
handed_over build-health 1 health.txt
no_gh "a clean run that builds"
checks=$(( checks + 1 ))
grep -q -F "build $build_id-health sees [REDACTED]" "$runs/build-health/build.log" || fail "the clean run's build.log has the build's output redacted"
no_secret "$tmp/out" "$tmp/err" "$runs/build-health/build.log"
equals "a run builds the image once" "$(cat "$tmp/out" "$tmp/err" | grep -c "naming to docker.io/library/$built")" 1
checks=$(( checks + 1 ))
[ -z "$(image_id "$leak_image")" ] || fail "each rebuild removes the image it left dangling"
equals "only the current image and another repository's are left" "$(test_images | wc -l | tr -d ' ')" 3
unset E2E_BUILD_SECRET

checks=$(( checks + 1 ))
[ -z "$(leftovers)" ] || fail "compose projects left: $(leftovers | sort -u | tr '\n' ' ')"

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
