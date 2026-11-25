slug_re='^[a-z0-9][a-z0-9-]*$'
minutes_re='^[1-9][0-9]*$'

[ -f "$plan" ] || jig_fail "plan file not found: $plan"
case "$plan" in
  *.md) ;;
  *) jig_fail "the plan must be a .md file: $plan" ;;
esac
slug="$(basename "$plan" .md)"
[[ $slug =~ $slug_re ]] ||
  jig_fail "the plan file name must be <slug>.md with a slug of lowercase latin letters, digits and dashes: $plan"
plan_abs="$(cd "$(dirname "$plan")" >/dev/null && pwd)/$slug.md"
branch="jig/$slug"

minutes="${JIG_TIMEOUT:-60}"
[[ $minutes =~ $minutes_re ]] || jig_fail "JIG_TIMEOUT must be a positive whole number of minutes"
jig_check_agent_env
extract_js="$(cat "$engine_root/lib/agent-log.js")" || jig_fail "could not read $engine_root/lib/agent-log.js"
jig_set_home
jig_set_profiles

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  jig_fail "both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are set; unset one of them.
Claude Code prefers ANTHROPIC_API_KEY, and API usage is billed separately from the subscription."
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  cred_name=CLAUDE_CODE_OAUTH_TOKEN
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  cred_name=ANTHROPIC_API_KEY
else
  jig_fail "set CLAUDE_CODE_OAUTH_TOKEN (printed by claude setup-token) or ANTHROPIC_API_KEY"
fi
cred_value="${!cred_name}"
[[ $cred_value =~ ^[A-Za-z0-9_-]+$ ]] ||
  jig_fail "the $cred_name value may contain only latin letters, digits, _ and -: check that it was copied whole"
jig_add_secret "$cred_name" "$cred_value"
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY

jig_check_host
git_name="$(git -C "$repo_root" config user.name || true)"
git_email="$(git -C "$repo_root" config user.email || true)"
[ -n "$git_name" ] && [ -n "$git_email" ] ||
  jig_fail "set git config user.name and user.email: the agent's commits are authored with them"
export GIT_AUTHOR_NAME="$git_name" GIT_COMMITTER_NAME="$git_name"
export GIT_AUTHOR_EMAIL="$git_email" GIT_COMMITTER_EMAIL="$git_email"

docker info >/dev/null 2>&1 || jig_fail "Docker is not running"
jig_check_disk
jig_use_builder

jig_repo_identity
jig_find_overlay
jig_resolve_base
[ "$profile_deliver" = branch ] || jig_check_gh
jig_agent_options
jig_read_build_secrets

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  jig_fail "branch $branch already exists locally: pick another plan file name or git -C $repo_root branch -D $branch"
fi
remote_status=0
git -C "$repo_root" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null || remote_status=$?
case "$remote_status" in
  0) jig_fail "branch $branch already exists on origin: pick another plan file name" ;;
  2) ;;
  *) jig_fail "could not list branches on origin" ;;
esac

run="$jig_home/runs/$gh_owner/$gh_name/$slug"
run_shown="\$JIG_HOME/runs/$gh_owner/$gh_name/$slug"
[ "$profile_deliver" = pr ] || run_shown="$run"
[ ! -e "$run" ] || jig_fail "run directory $run already exists: remove it (rm -rf) to reuse the name"

jig_project="jig-run_${docker_repo}_$slug"
started=$(date +%s)
down_done=0
fetched=0

die() {
  local status=$?
  if [ "$status" = 130 ]; then
    echo "$jig_name: interrupted" >&2
    exit 130
  fi
  echo "$jig_name: $*" >&2
  echo "$jig_name: run directory kept: $run" >&2
  if [ "$fetched" = 1 ]; then
    echo "$jig_name: the branch was fetched to $branch; to run the plan again: git -C $repo_root branch -D $branch && rm -rf $run" >&2
  fi
  exit 3
}

refuse() {
  local kept="no local branch $branch was created"
  if [ "$fetched" = 1 ]; then
    git -C "$repo_root" branch -q -D "$branch" >/dev/null 2>&1 ||
      echo "$jig_name: could not delete the local branch $branch: delete it by hand" >&2
    kept="the local branch $branch was deleted"
  fi
  fetched=0
  die "$* Nothing was pushed; $kept."
}

refuse_leaks() {
  local f found leaks="" names=""
  for f in "$@"; do
    found=0
    jig_contains_secret "$run/$f" || found=$?
    case "$found" in
      0)
        leaks="$leaks $f"
        names="$names$(jig_secrets_in "$run/$f")"$'\n' ;;
      1) ;;
      *) die "could not scan $run/$f for $(jig_values_of "$(jig_all_secrets)")" ;;
    esac
  done
  [ -n "$leaks" ] || return 0
  rm -f "$run/branch.bundle"
  refuse "$(jig_values_found "$names") found in:$leaks (branch.bundle was removed; the warnings below say what happened to the other files in $run)."
}

redact_logs() {
  local f files=()
  for f in "$run"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$f" != "$run/branch.bundle" ] || continue
    files+=("${f##*/}")
  done
  jig_redact_files "$run" ${files[@]+"${files[@]}"}
}

teardown() {
  down_done=1
  jig_down
}

# The clone holds the agent's .git: its hooks and config would run in any git-aware prompt or editor on the host.
remove_clone() {
  [ -e "$run/repo" ] || return 0
  chmod -R u+rwX "$run/repo" 2>/dev/null || true
  rm -rf "$run/repo" ||
    echo "$jig_name: WARNING: could not remove $run/repo; delete it without running git or opening it in an editor" >&2
}

finish() {
  local status=$?
  trap '' INT TERM HUP
  set +e
  if [ "$down_done" = 0 ]; then
    teardown || echo "$jig_name: docker compose down failed: remove project $jig_project by hand" >&2
  fi
  remove_clone
  redact_logs
  exit "$status"
}

elapsed() {
  local s=$(( $(date +%s) - $1 ))
  echo "$(( s / 60 ))m $(( s % 60 ))s"
}

jig_profile_report
jig_harness_report

mkdir -p "$(dirname "$run")" || jig_fail "could not create $(dirname "$run")"
mkdir "$run" || jig_fail "could not create $run"
jig_extract_profile "$base" "$run" || die "could not put the profile of $base and the overlay into $run/profile"
cp "$plan_abs" "$run/plan.md" || die "could not copy the plan to $run/plan.md"
issue_status=0
jig_plan_issue "$run/plan.md" || issue_status=$?
if [ "$issue_status" = 2 ]; then
  rm -rf "$run"
  jig_fail "the Issue line of $plan still has the template's placeholder (a < or >): write #123 or a tracker ID, or delete the line"
fi
[ "$issue_status" = 0 ] || die "could not read the Issue line of $run/plan.md"
echo "$jig_name: issue: $issue_text"
jig_warn jig_issue_warnings
jig_use_harness "$run/compose.harness.yml" "$run/system-prompt.md" "$run/plan.md" ||
  die "could not write the harness files into $run"
jig_clone "$base" "$run/repo" || die "git clone failed"

jig_use_workspace "$run/repo" "$base"
trap finish EXIT

echo "$jig_name: starting compose project $jig_project"
jig_compose up -d --build --wait || die "docker compose up failed"

jig_compose exec -T app git switch -q -c "$branch" || die "could not create $branch in the container"

echo "$jig_name: preparing the environment with $profile_setup (log: $run/setup.log)"
jig_compose exec -T -w /workspace app "$(jig_profile_command "$profile_setup")" >"$run/setup.log" 2>&1 || die "$profile_setup failed: see $run/setup.log"

prompt="$jig_plan_prompt"

echo "$jig_name: deliver: $(jig_delivery "$branch")"
echo "$jig_name: agent $(jig_agent_settings)"
echo "$jig_name: agent running, up to $minutes min (log: $run/claude.log)"
agent_started=$(date +%s)
agent_status=0
(
  export "$cred_name=$cred_value"
  jig_compose exec -T -e "$cred_name" \
    -e GIT_AUTHOR_NAME -e GIT_AUTHOR_EMAIL -e GIT_COMMITTER_NAME -e GIT_COMMITTER_EMAIL app \
    timeout -k 60 "${minutes}m" \
    claude -p "$prompt" "${jig_harness_args[@]}" ${jig_agent_args[@]+"${jig_agent_args[@]}"} --dangerously-skip-permissions --output-format stream-json --verbose
) </dev/null >"$run/claude.log" 2>&1 || agent_status=$?
# On Ctrl-C docker compose exec exits with 130 instead of dying from SIGINT, so bash skips its INT trap.
[ "$agent_status" != 130 ] || exit 130
agent_seconds=$(( $(date +%s) - agent_started ))
agent_duration="$(elapsed "$agent_started")"
timed_out=0
if [ "$agent_status" = 124 ] || { [ "$agent_status" = 137 ] && [ "$agent_seconds" -ge $(( minutes * 60 )) ]; }; then
  timed_out=1
fi
echo "$jig_name: agent finished with exit $agent_status after $agent_duration"

jig_compose restart app >/dev/null 2>&1 || die "could not restart the app container before $profile_verify"

collect="$run/collect.log"
jig_compose exec -T app git -c core.fsmonitor=false status --porcelain >"$run/status.txt" 2>>"$collect" ||
  die "git status failed in the container: see $collect"
jig_compose exec -T app sh -c 'cat JIG_BLOCKED.md 2>/dev/null || true' >"$run/blocked-worktree.md" 2>>"$collect" ||
  die "could not read JIG_BLOCKED.md in the container: see $collect"
commits="$(jig_compose exec -T app git -c core.fsmonitor=false rev-list --count "refs/heads/$branch" "^$base" 2>>"$collect")" &&
  [[ $commits =~ ^[0-9]+$ ]] || die "could not count the commits of $branch in the container: see $collect"

verify_status=0
if [ "$commits" != 0 ]; then
  jig_compose exec -T app git -c core.fsmonitor=false bundle create - "refs/heads/$branch" "^$base" \
    >"$run/branch.bundle" 2>>"$collect" || die "could not bundle $branch in the container: see $collect"
  jig_compose exec -T app \
    sh -c 'git -c core.hooksPath=/dev/null -c core.fsmonitor=false checkout -q -f "$1" && git -c core.fsmonitor=false clean -q -fd' \
    sh "$branch" >>"$collect" 2>&1 ||
    die "could not check out a clean $branch for $profile_verify: see $collect"

  echo "$jig_name: running $profile_verify on the committed $branch (log: $run/verify.log)"
  jig_compose exec -T -w /workspace app "$(jig_profile_command "$profile_verify")" >"$run/verify.log" 2>&1 || verify_status=$?
  [ "$verify_status" != 130 ] || exit 130
  echo "$jig_name: $profile_verify exit $verify_status"
fi

extract_status=0
jig_compose exec -T app node -e "$extract_js" summary <"$run/claude.log" >"$run/summary.md" 2>/dev/null ||
  extract_status=$?
[ "$extract_status" != 130 ] || exit 130
[ "$extract_status" = 0 ] || : >"$run/summary.md"
extract_status=0
agent_log="$(jig_compose exec -T app node -e "$extract_js" meta <"$run/claude.log" 2>/dev/null)" ||
  extract_status=$?
[ "$extract_status" != 130 ] || exit 130
[ "$extract_status" = 0 ] || agent_log=""
agent_report="$(jig_agent_report "$agent_log")"
echo "$jig_name: agent: $(jig_redact_text "$agent_report")"

teardown || die "docker compose down failed: remove project $jig_project by hand"
[ "$jig_interrupted" = 0 ] || exit 130
echo "$jig_name: compose project $jig_project removed"
remove_clone

if [ "$commits" = 0 ]; then
  [ "$timed_out" = 0 ] || echo "$jig_name: the agent hit JIG_TIMEOUT=$minutes min and was stopped"
  ! grep -q 'JIG_BLOCKED\.md$' "$run/status.txt" ||
    echo "$jig_name: the agent left JIG_BLOCKED.md uncommitted: see $run/blocked-worktree.md"
  [ ! -s "$run/status.txt" ] || echo "$jig_name: uncommitted changes were left in the clone: see $run/status.txt"
  [ ! -s "$run/summary.md" ] || echo "$jig_name: the agent's final message: $run/summary.md"
  [ "$profile_deliver" = branch ] ||
    die "the agent made no commits on $branch (agent exit $agent_status): nothing was pushed and no PR was opened."
  die "the agent made no commits on $branch (agent exit $agent_status): no branch was fetched into $repo_root."
fi

g() { git -C "$repo_root" "$@"; }
g -c transfer.fsckObjects=true -c fetch.fsckObjects=true \
  fetch --quiet --no-write-fetch-head "$run/branch.bundle" "refs/heads/$branch" || { rm -f "$run/branch.bundle"; die "could not fetch $branch from the bundle"; }
heads="$(g bundle list-heads "$run/branch.bundle" "refs/heads/$branch")" || die "could not list the heads of $run/branch.bundle"
tip="${heads%% *}"
[ "$heads" = "$tip refs/heads/$branch" ] && [[ $tip =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] &&
  tip="$(g rev-parse --verify --quiet "$tip^{commit}")" || die "could not resolve $branch in $run/branch.bundle"
g merge-base --is-ancestor "$base" "$tip" || die "$branch does not start from $base_branch ($base)"

g log -p --text --diff-merges=first-parent --format=fuller "$base..$tip" >"$run/branch.patch" ||
  die "git log failed on $branch"
g rev-list --objects --no-object-names "$base..$tip" | g cat-file --batch >"$run/branch.objects" ||
  die "could not read the objects of $branch"
refuse_leaks branch.patch branch.objects summary.md blocked-worktree.md
g update-ref "refs/heads/$branch" "$tip" "" || die "could not create $branch in $repo_root"
fetched=1

g log -z --format= --name-only --no-renames --diff-merges=first-parent "$base..$tip" >"$run/touched.z" ||
  die "git log failed on $branch"
g diff -z --name-only --no-renames "$base" "$tip" >"$run/changed.z" || die "git diff failed on $branch"
github_changed=$'\n'
while IFS= read -r -d '' f; do
  case "$f" in
    .github | .github/*) github_changed="$github_changed$f"$'\n' ;;
  esac
done <"$run/changed.z"
github=""
github_count=0
while IFS= read -r -d '' f; do
  case "$f" in
    .github | .github/*) ;;
    *) continue ;;
  esac
  github_count=$(( github_count + 1 ))
  [ "$github_count" -le "$list_max" ] || continue
  case "$github_changed" in
    *$'\n'"$f"$'\n'*) github="$github- \`$(jig_pr_line "$f")\`
" ;;
    *) github="$github- \`$(jig_pr_line "$f")\` (changed, then reverted within the branch)
" ;;
  esac
done < <(cat "$run/touched.z" "$run/changed.z" | LC_ALL=C sort -z -u)
[ "$github_count" -le "$list_max" ] || github="$github- and $(( github_count - list_max )) more
"
[ -z "$github" ] || [ "$profile_deliver" = branch ] ||
  refuse "$branch changes paths under .github/ (see $run/branch.patch): a pushed workflow runs with the repository's secrets and write access."

protected=""
protected_count=0
changes=0
while IFS= read -r -d '' f; do
  [ "$f" = JIG_BLOCKED.md ] || changes=1
  if jig_protected "$f"; then
    protected_count=$(( protected_count + 1 ))
    [ "$protected_count" -gt "$list_max" ] || protected="$protected- \`$(jig_pr_line "$f")\`
"
  fi
done <"$run/changed.z"
[ "$protected_count" -le "$list_max" ] || protected="$protected- and $(( protected_count - list_max )) more
"

blocked=""
blocked_file=""
if g cat-file -e "$tip:JIG_BLOCKED.md" 2>/dev/null; then
  g show "$tip:JIG_BLOCKED.md" >"$run/blocked-branch.md" || die "could not read JIG_BLOCKED.md from $branch"
  blocked_file="blocked-branch.md"
elif grep -q 'JIG_BLOCKED\.md$' "$run/status.txt"; then
  blocked_file="blocked-worktree.md"
fi
if [ -n "$blocked_file" ]; then
  blocked="$(jig_pr_excerpt "$jig_pr_blocked_max" "$run/$blocked_file" '    > ' \
    "    > (cut: the whole text is in \`$run_shown/$blocked_file\`)")" || die "could not read $run/$blocked_file"
  [ -n "$blocked" ] || blocked="    > (empty)"
  [ "$blocked_file" = blocked-branch.md ] || blocked="$blocked
    > (left uncommitted in the clone)"
fi

title="$(sed -n 's/^# //p' "$run/plan.md" | sed -n 1p)" || die "could not read the title of $run/plan.md"
[ -n "$title" ] || title="$slug"

reasons=""
attention=""
note() { attention="$attention- $1
"; }
if [ -n "$github" ]; then
  reasons="$reasons .github/;"
  note "Changes under \`.github/\`, in a commit or in the diff against $base_branch: a pushed workflow runs with the repository's secrets and write access, so review them before you push:
$(printf '%s' "$github" | sed 's/^/  /')"
fi
if [ "$verify_status" != 0 ]; then
  reasons="$reasons $profile_verify red;"
  note "$profile_verify is red (exit $verify_status): see \`$run_shown/verify.log\`."
fi
if [ "$timed_out" = 1 ]; then
  reasons="$reasons timeout;"
  note "The agent hit JIG_TIMEOUT=$minutes min and was stopped."
elif [ "$agent_status" != 0 ]; then
  reasons="$reasons agent exit $agent_status;"
  note "The agent exited with code $agent_status."
fi
if [ -n "$blocked" ]; then
  reasons="$reasons JIG_BLOCKED.md;"
  note "The agent left JIG_BLOCKED.md:

$blocked
"
fi
if [ -n "$protected" ]; then
  reasons="$reasons protected paths;"
  note "Changes in paths the agent must not edit:
$(printf '%s' "$protected" | sed 's/^/  /')"
fi
if [ "$changes" = 0 ]; then
  reasons="$reasons no changes;"
  note "The branch's commits change nothing against $base_branch other than \`JIG_BLOCKED.md\`."
fi
if [ -s "$run/status.txt" ]; then
  reasons="$reasons uncommitted changes;"
  status_lines=""
  status_count=0
  while IFS= read -r line || [ -n "$line" ]; do
    status_count=$(( status_count + 1 ))
    [ "$status_count" -gt "$list_max" ] || status_lines="$status_lines$(jig_pr_line "$line")
"
  done <"$run/status.txt"
  [ "$status_count" -le "$list_max" ] || status_lines="$status_lines... and $(( status_count - list_max )) more
"
  if [ "$profile_deliver" = pr ]; then delivered="in this PR"; else delivered="on the branch"; fi
  note "Uncommitted changes were left in the clone; they are not $delivered and $profile_verify ran without them:

\`\`\`
$status_lines\`\`\`"
fi

summary="$(jig_pr_excerpt "$jig_pr_summary_max" "$run/summary.md" '' "
*The summary is cut here: the whole message is in \`$run_shown/summary.md\`.*")" || die "could not read $run/summary.md"
[ -n "$summary" ] || summary="(the agent left no final message: see \`$run_shown/claude.log\`)"
if [ "$verify_status" = 0 ]; then verify_text="green"; else verify_text="red (exit $verify_status)"; fi
agent_text="exit $agent_status, $agent_report"

top_name="PR description"
[ "$profile_deliver" = pr ] || top_name=report
top="$(
  if [ "$profile_deliver" = branch ]; then
    echo "# $title"
    echo
  fi
  if [ -n "$issue_line" ]; then
    echo "$issue_line"
    echo
  fi
  [ "$profile_deliver" = pr ] || jig_report_branch "$repo_root" "$branch" "$commits" "$base_branch" "$base"
  echo "- $profile_verify: $verify_text"
  echo "- Agent: $agent_text"
  echo "- Duration: $(elapsed "$started") in total, agent $agent_duration (limit $minutes min)"
  echo "- Log: \`$run_shown/claude.log\`"
  if [ "$profile_deliver" = branch ]; then
    echo "- Plan: \`$run/plan.md\`"
    echo
    echo '```sh'
    jig_log_command "$repo_root" "$base" "$branch"
    echo
    jig_diff_command "$repo_root" "$base" "$branch"
    echo
    echo '```'
  fi
  if [ -n "$attention" ]; then
    echo
    echo "## Needs attention"
    echo
    printf '%s' "$attention"
  fi
  echo
  printf '%s' "$jig_profile_md"
  echo
  printf '%s' "$jig_harness_md"
  echo
  echo "## Agent summary"
  echo
  printf '%s\n' "$summary"
)" || die "could not compose the $top_name"

if [ "$profile_deliver" = branch ]; then
  report="$run/report.md"
  printf '%s\n' "$top" >"$report" || die "could not write $report"
  refuse_leaks plan.md report.md
  if [ -n "$reasons" ]; then
    echo "$jig_name: needs attention ($(echo "$reasons" | sed 's/^ //; s/;$//')): $branch in $repo_root"
  else
    echo "$jig_name: ready: $branch in $repo_root"
  fi
  echo "$jig_name: $profile_verify: $verify_text"
  echo "$jig_name: report: $report"
  echo "$jig_name: diff: $(jig_diff_command "$repo_root" "$base" "$branch")"
  [ -z "$reasons" ] || exit 1
  exit 0
fi

body="$run/pr-body.md"
jig_pr_body "$run/plan.md" "$run_shown/plan.md" "$top" "🤖 Generated with [Claude Code](https://claude.com/claude-code)" >"$body" ||
  die "could not write $body"

refuse_leaks plan.md pr-body.md

g push --quiet origin "refs/heads/$branch:refs/heads/$branch" || die "git push origin $branch failed"
pr_args=(--base "$base_branch" --head "$branch" --title "$title" --body-file "$body")
[ -z "$reasons" ] || pr_args+=(--draft)
pr_url="$(cd "$repo_root" && gh pr create --repo "$gh_repo" "${pr_args[@]}")" ||
  die "gh pr create failed; $branch is pushed, open the PR by hand with the body in $body"

if [ -n "$reasons" ]; then
  echo "$jig_name: draft PR ($(echo "$reasons" | sed 's/^ //; s/;$//')): $pr_url"
  exit 1
fi
echo "$jig_name: PR ready: $pr_url"
