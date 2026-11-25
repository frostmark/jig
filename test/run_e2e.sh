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

if [ -n "$(leftovers)" ]; then
  echo "run_e2e: compose projects of acme/shop already exist; remove them first:"
  leftovers | sort -u
  exit 1
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/jig-e2e.XXXXXX")" || exit 1
tmp="$(cd "$tmp" && pwd -P)"
trap 'remove_leftovers; chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/gh" "$tmp/plans" "$tmp/profile"
cat >"$tmp/profile/fake-claude" <<'EOF'
#!/bin/sh
set -eu
say() {
  node -e 'process.stdout.write(JSON.stringify({ type: "system", subtype: "fake", msg: process.argv[1] }) + "\n")' "$1"
}
result() {
  node -e 'process.stdout.write(JSON.stringify({ type: "result", subtype: "success", is_error: false, num_turns: 3,
    total_cost_usd: 0.01, result: process.argv[1] }) + "\n")' "$1"
}
check() {
  say "check failed: $1"
  exit 5
}
prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$prompt" = "Implement the plan in /jig/plan.md." ] || check "the prompt is $prompt"
[ -r /jig/plan.md ] || check "no /jig/plan.md"
if touch /jig/plan.md 2>/dev/null; then check "/jig/plan.md is writable"; fi
[ "$(git rev-parse HEAD)" = "${JIG_BASE:-}" ] || check "JIG_BASE is not HEAD"
say "fake claude: the prompt names /jig/plan.md, the plan is read-only, JIG_BASE is HEAD ($JIG_BASE) on $(git branch --show-current)"
if grep -q -x NO-COMMIT /jig/plan.md; then
  printf 'The plan asks for nothing.\n' >JIG_BLOCKED.md
  result "Nothing to do."
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
  result "$(node -e 'for (let n = 1; n <= 1500; n++) console.log(`Шаг ${n}: ответ проверен → готово.`)')"
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
chmod +x "$tmp/bin/gh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL ANTHROPIC_API_KEY
token=e2e0dummy0credential0value
export PATH="$tmp/bin:$PATH" FAKE_GH_DIR="$tmp/gh" JIG_HOME="$tmp/home" JIG_PROFILES="$tmp/profiles"
export CLAUDE_CODE_OAUTH_TOKEN="$token"

origin="$tmp/origin.git"
target="$tmp/shop"
git init -q --bare -b main "$origin"
git init -q -b main "$target"
git -C "$target" config user.name "Test Author"
git -C "$target" config user.email test@example.com
git -C "$target" remote add origin "$origin"
mkdir "$target/.jig"
cp -p "$tmp/profile/"* "$target/.jig/"
echo shop >"$target/README"
git -C "$target" add -A && git -C "$target" commit -q -m init && git -C "$target" push -q origin main
base="$(git -C "$origin" rev-parse main)"
runs="$JIG_HOME/runs/acme/shop"
shown='$JIG_HOME/runs/acme/shop'
attribution="🤖 Generated with [Claude Code](https://claude.com/claude-code)"

jig() {
  (cd "$target" && "$root/bin/jig" "$@") >"$tmp/out" 2>"$tmp/err"
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

jig smoke
equals "smoke exits 0" "$?" 0
has_line "setup in smoke gets the checked HEAD as JIG_BASE" "$tmp/out" "setup: JIG_BASE=$base HEAD=$base branch="
has_line "verify in smoke gets the checked HEAD as JIG_BASE" "$tmp/out" "verify: JIG_BASE=$base"
has_line "the diff against JIG_BASE is empty in smoke" "$tmp/out" "verify: changed since JIG_BASE:"
has_line "smoke has no plan" "$tmp/out" "verify: plan mount: absent"

printf '# Add a health file\n\nWrite ok to health.txt.\n' >"$tmp/plans/add-health.md"
jig run "$tmp/plans/add-health.md"
equals "a clean run exits 0" "$?" 0
has_line "setup starts on the base on the new branch" "$runs/add-health/setup.log" \
  "setup: JIG_BASE=$base HEAD=$base branch=jig/add-health"
has_line "the agent sees the prompt, the read-only plan and JIG_BASE on a branch without a plan commit" \
  "$runs/add-health/claude.log" \
  '{"type":"system","subtype":"fake","msg":"fake claude: the prompt names /jig/plan.md, the plan is read-only, JIG_BASE is HEAD ('"$base"') on jig/add-health"}'
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
body="$tmp/gh/add-health.body"
equals "the PR body starts with verify" "$(sed -n 1p "$body")" "- .jig/verify: green"
has_line "the log line names the run under JIG_HOME" "$body" "- Log: \`$shown/add-health/claude.log\`"
lacks "the PR body has no host path" "$body" "$tmp"
equals "the plan block comes last, fenced, before the attribution" "$(tail -n 15 "$body")" "## Agent summary

What changes: health.txt says ok.

<details><summary>Plan</summary>

\`\`\`markdown
# Add a health file

Write ok to health.txt.
\`\`\`

</details>

$attribution"

printf '# Do nothing\n\nNO-COMMIT\n' >"$tmp/plans/nothing-to-do.md"
jig run "$tmp/plans/nothing-to-do.md"
equals "a run without commits exits 3" "$?" 3
has_line "a run without commits says so" "$tmp/err" \
  "jig: the agent made no commits on jig/nothing-to-do (agent exit 0): nothing was pushed and no PR was opened."
has_line "a run without commits points at the uncommitted JIG_BLOCKED.md" "$tmp/out" \
  "jig: the agent left JIG_BLOCKED.md uncommitted: see $runs/nothing-to-do/blocked-worktree.md"
equals "the uncommitted JIG_BLOCKED.md is kept" "$(cat "$runs/nothing-to-do/blocked-worktree.md")" "The plan asks for nothing."
checks=$(( checks + 1 ))
[ ! -e "$runs/nothing-to-do/verify.log" ] || fail "a run without commits runs no final verify"
nothing_pushed nothing-to-do

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
checks=$(( checks + 1 ))
size="$(bytes <"$body")"
[ "$size" -le 65536 ] || fail "oversized agent output keeps the PR body within 65,536 bytes: $size bytes"
checks=$(( checks + 1 ))
iconv -f UTF-8 -t UTF-8 "$body" >/dev/null 2>&1 || fail "the cut PR body is valid UTF-8"
checks=$(( checks + 1 ))
size="$(grep '^    > ' "$body" | bytes)"
[ "$size" -le 10001 ] || fail "the quoted JIG_BLOCKED.md stays within 10,000 bytes: $size bytes"
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

checks=$(( checks + 1 ))
[ -z "$(leftovers)" ] || fail "compose projects left: $(leftovers | sort -u | tr '\n' ' ')"

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
