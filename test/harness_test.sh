#!/bin/bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"
engine_root="$root"
jig_name=jig
. "$root/lib/common.sh"
. "$root/lib/profile.sh"
. "$root/lib/harness.sh"
. "$root/lib/pr.sh"
. "$root/lib/build.sh"

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

exits_2() {
  local name="$1" want="$2" out status
  shift 2
  checks=$(( checks + 1 ))
  out="$( ("$@") 2>&1)"
  status=$?
  if [ "$status" != 2 ]; then
    fail "$name: exit $status, expected 2 (output: $out)"
  elif [[ $out != *"$want"* ]]; then
    fail "$name: message \"$out\" does not contain \"$want\""
  fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/jig-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

github_repo() {
  equals "$1 names $2" "$(jig_github_repo "$1" || echo refused)" "$2"
}
for url in https://github.com/acme/shop.git https://github.com/acme/shop https://github.com/acme/shop/ \
  https://github.com/acme/shop.git/ http://github.com/acme/shop git://github.com/acme/shop.git \
  https://user:x-token@github.com/acme/shop.git https://github.com:443/acme/shop https://GitHub.COM/acme/shop \
  git@github.com:acme/shop.git git@github.com:acme/shop github.com:acme/shop.git git@github.com:/acme/shop.git \
  ssh://git@github.com/acme/shop.git ssh://git@github.com:22/acme/shop ssh://github.com/acme/shop/; do
  github_repo "$url" acme/shop
done
github_repo https://github.com/Acme-Corp/My_Shop.v2.git Acme-Corp/My_Shop.v2
github_repo git@github.com:Acme/Shop Acme/Shop
github_repo https://github.com/acme/shop.git.git acme/shop.git
github_repo https://github.com/acme/.github acme/.github
github_repo git@github.com:acme/.gitignore.git acme/.gitignore
for url in /srv/git/shop.git file:///srv/github.com/acme/shop.git https://gitlab.com/acme/shop.git \
  git@gitlab.com:acme/shop.git https://github.com.example.org/acme/shop https://example.org/github.com/acme/shop \
  mygithub.com:acme/shop https://notgithub.com/acme/shop https://github.com/acme https://github.com/acme/shop/tree/main \
  https://github.com/acme/shop.git/extra 'https://github.com/acme/sh op' 'https://github.com/acme/shop;id' \
  'https://github.com/acme/$(id)' https://github.com/../shop https://github.com/acme/.. https://github.com/./shop \
  https://github.com/acme/.git https://github.com/acme/.git.git git@github.com:acme/.GIT.git git@github.com:acme/.Git \
  https://github.com/.git/shop ftp://github.com/acme/shop 'git@github.com:acme/shop:x' https://github.com//shop \
  'git@github.com acme/shop' xssh://git@github.com/acme/shop /srv/github.com:acme/shop git@github.com:acme/shop/extra \
  "https://github.com/acme/shop
https://github.com/acme/other" https://github.com/acme/shоp; do
  github_repo "$url" refused
done

git init -q "$tmp/identity"
git -C "$tmp/identity" remote add origin git@github.com:Acme/My.Shop.git
identity() {
  (repo_root="$tmp/identity" && jig_repo_identity && printf '%s|%s|%s|%s|%s' "$origin_url" "$gh_repo" "$gh_owner" "$gh_name" "$docker_repo") 2>&1
}
equals "the identity keeps the origin URL's case, and the docker name is lowercased" "$(identity)" \
  "git@github.com:Acme/My.Shop.git|Acme/My.Shop|Acme|My.Shop|acme_my-shop"
git -C "$tmp/identity" remote set-url origin https://user:e2e0secret0value@gitlab.com/acme/shop.git
exits_2 "an origin that is not on GitHub stops jig and names the accepted forms" \
  "jig: the origin remote of $tmp/identity is not a GitHub repository URL; jig takes <owner>/<repo> from https://github.com/<owner>/<repo>, git@github.com:<owner>/<repo> or ssh://git@github.com/<owner>/<repo>, with or without .git" \
  identity
equals "the refused origin URL is not printed" "$(identity | grep -c e2e0secret0value)" 0
git -C "$tmp/identity" remote remove origin
exits_2 "a checkout without origin stops jig" "jig: $tmp/identity has no remote origin" identity

gh() {
  printf '%s\n' "$*" >>"$tmp/gh.calls"
  case "$1 $2" in
    "auth status") [ "$gh_auth" = ok ] ;;
    "repo view") [ "$gh_view" != fail ] && echo "$gh_view" ;;
    *) return 1 ;;
  esac
}
check_gh() {
  rm -f "$tmp/gh.calls"
  (origin_url=git@github.com:acme/shop.git gh_repo=acme/shop repo_root=/src/shop && jig_check_gh) 2>&1
}
gh_auth=ok gh_view=acme/shop
equals "gh that names the parsed repository passes" "$(check_gh)" ""
equals "gh is asked about github.com and the origin URL" "$(cat "$tmp/gh.calls")" "auth status --hostname github.com
repo view git@github.com:acme/shop.git --json nameWithOwner --jq .nameWithOwner"
gh_auth=no
exits_2 "pr delivery needs gh logged in" \
  "jig: gh is not logged in to github.com: run gh auth login (deliver pr opens the PR with gh; deliver branch needs no gh)" check_gh
gh_auth=ok gh_view=fail
exits_2 "a failing gh repo view stops jig" "jig: gh repo view failed for the origin remote of /src/shop" check_gh
gh_view=Acme/shop
exits_2 "GitHub's spelling must be the origin URL's" \
  "jig: the origin URL of /src/shop names the repository acme/shop, but GitHub names it Acme/shop: set origin to GitHub's spelling (git -C /src/shop remote set-url origin <URL>), which also names the overlay and the run directories" \
  check_gh
gh_view=acme/shop-old
exits_2 "a renamed repository's old URL stops jig" "but GitHub names it acme/shop-old" check_gh
unset -f gh

gh_owner=acme
gh_name=shop
jig_home="$tmp/home"
profiles="$tmp/profiles"
overlay="$profiles/acme/shop"

find_in() {
  JIG_PROFILES="$1"
  jig_set_profiles
  jig_find_overlay
}

found() {
  (find_in "$1" && printf '%s|%s|%s' "$overlay_dir" "$overlay_rules" "$overlay_plugin") 2>&1
}

unset JIG_PROFILES
equals "the overlay root defaults to JIG_HOME/profiles" \
  "$( (jig_set_profiles && jig_find_overlay && printf '%s|%s|%s' "$overlay_dir" "$overlay_rules" "$overlay_plugin") 2>&1)" \
  "$tmp/home/profiles/acme/shop||"
equals "no overlay directory: no rules, no plugin" "$(found "$profiles")" "$overlay||"
git init -q "$tmp/target"
printf '# Add a health check\n' >"$tmp/add-health-check.md"
checks=$(( checks + 1 ))
out="$(cd "$tmp" && env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY JIG_HOME="$tmp/home" JIG_PROFILES=profiles \
  "$root/bin/jig" run add-health-check.md --repo "$tmp/target" 2>&1)"
status=$?
if [ "$status" != 2 ] || [ "$out" != "jig: JIG_PROFILES must be an absolute path" ]; then
  fail "a relative JIG_PROFILES stops jig run before the credential check: exit $status (output: $out)"
fi

run_with() {
  (cd "$tmp" && env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u JIG_MODEL -u JIG_EFFORT JIG_HOME="$tmp/home" \
    JIG_PROFILES=profiles "$@" "$root/bin/jig" run add-health-check.md --repo "$tmp/target" 2>&1)
}
exits_2 "a JIG_EFFORT that is not a level stops jig run before the credential check" \
  "jig: JIG_EFFORT must be one of low, medium, high, xhigh, max" run_with JIG_EFFORT=extreme
exits_2 "a JIG_MODEL outside the model characters stops jig run before the credential check" \
  "jig: JIG_MODEL must be a Claude Code model name or alias" run_with 'JIG_MODEL=opus --verbose'
exits_2 "a valid JIG_MODEL and JIG_EFFORT pass on to the next check" \
  "jig: JIG_PROFILES must be an absolute path" run_with 'JIG_MODEL=sonnet[1m]' JIG_EFFORT=xhigh
exits_2 "an empty JIG_MODEL and JIG_EFFORT count as unset" \
  "jig: JIG_PROFILES must be an absolute path" run_with JIG_MODEL= JIG_EFFORT=

mkdir -p "$overlay/plugin/skills/review"
equals "an overlay with only a plugin" "$(found "$profiles")" "$overlay||$overlay/plugin"
printf 'Prefer small functions.\n' >"$overlay/rules.md"
equals "an overlay with rules and a plugin" "$(found "$profiles")" "$overlay|$overlay/rules.md|$overlay/plugin"
rm -r "$overlay/plugin"
equals "an overlay with only rules" "$(found "$profiles")" "$overlay|$overlay/rules.md|"
equals "another overlay root" "$(found "$tmp/elsewhere")" "$tmp/elsewhere/acme/shop||"

rm "$overlay/rules.md"
mkdir "$overlay/rules.md"
exits_2 "rules.md is a directory" "the overlay rules $overlay/rules.md must be a readable regular file" find_in "$profiles"
rmdir "$overlay/rules.md"
ln -s "$tmp/missing.md" "$overlay/rules.md"
exits_2 "rules.md is a dangling link" "the overlay rules $overlay/rules.md must be a readable regular file" find_in "$profiles"
rm "$overlay/rules.md"
printf 'Prefer small functions.\n' >"$overlay/rules.md"
chmod 000 "$overlay/rules.md"
exits_2 "rules.md is not readable" "the overlay rules $overlay/rules.md must be a readable regular file" find_in "$profiles"
rm -f "$overlay/rules.md"
: >"$overlay/plugin"
exits_2 "plugin is a file" "the overlay plugin $overlay/plugin must be a directory" find_in "$profiles"
rm "$overlay/plugin"
ln -s "$tmp/missing" "$overlay/plugin"
exits_2 "plugin is a dangling link" "the overlay plugin $overlay/plugin must be a directory" find_in "$profiles"
rm "$overlay/plugin"
rmdir "$overlay"
: >"$overlay"
exits_2 "the repository's overlay is a file" "the overlay $overlay must be a directory" find_in "$profiles"
rm "$overlay"
ln -s "$tmp/missing" "$overlay"
exits_2 "the repository's overlay is a dangling link" "the overlay $overlay must be a directory" find_in "$profiles"
rm "$overlay"

mkdir "$profiles/acme/Shop"
exits_2 "an overlay directory whose name differs from the origin URL's only in case stops jig on any filesystem" \
  "jig: the overlay directory is spelled $profiles/acme/Shop, but the origin URL (acme/shop) makes jig look for $profiles/acme/shop: give both GitHub's spelling (rename the directory, or set origin with git remote set-url)" \
  find_in "$profiles"
rmdir "$profiles/acme/Shop"
mv "$profiles/acme" "$profiles/ACME"
mkdir "$profiles/ACME/shop"
exits_2 "an owner directory that differs only in case stops jig" \
  "jig: the overlay directory is spelled $profiles/ACME, but the origin URL (acme/shop) makes jig look for $profiles/acme:" \
  find_in "$profiles"
mv "$profiles/ACME" "$tmp/acme-overlays"
ln -s "$tmp/acme-overlays" "$profiles/acme"
mv "$tmp/acme-overlays/shop" "$tmp/acme-overlays/Shop"
exits_2 "a repository directory in another case is found behind an owner directory that is a link" \
  "jig: the overlay directory is spelled $profiles/acme/Shop, but the origin URL (acme/shop) makes jig look for $profiles/acme/shop:" \
  find_in "$profiles"
mv "$tmp/acme-overlays/Shop" "$tmp/acme-overlays/shop"
mkdir "$tmp/acme-overlays/shop-old" "$tmp/acme-overlays/shop.d"
: >"$tmp/acme-overlays/shop/rules.md"
equals "an owner directory that is a link is looked into, and names that only start with the repository's do not count" \
  "$(found "$profiles")" "$overlay|$overlay/rules.md|"
rm "$profiles/acme"
rm -r "$tmp/acme-overlays"
mkdir "$profiles/acme"

jig_parse_profile cfg <<<"base main
setup .jig/setup
verify bin/verify
protect CLAUDE.md
protect .jig/*
protect bin/verify
protect deploy/*
protect deploy/*.yml
protect */CLAUDE.md"
equals "protected list: always-protected paths first, covered entries left out" "$(jig_protected_list)" \
  '  - `.jig/*`
  - `bin/verify`
  - `CLAUDE.md`
  - `deploy/*`
  - `*/CLAUDE.md`'

jig_parse_profile cfg <<<"base main
setup .jig/setup
verify .jig/verify
protect CLAUDE.md"
rules="$(jig_engine_rules)"
checks=$(( checks + 1 ))
[[ $rules == *'Run `cd /workspace && /jig/profile/verify` yourself'* ]] ||
  fail "the engine rules give the profile's verify command with its working directory: $rules"
checks=$(( checks + 1 ))
[[ $rules == *"
$(jig_protected_list)
"* ]] || fail "the engine rules carry the protected list: $rules"
checks=$(( checks + 1 ))
[[ $rules != *@VERIFY@* && $rules != *@PROTECTED@* ]] || fail "the engine rules keep a placeholder: $rules"

flat() {
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}
has() {
  checks=$(( checks + 1 ))
  [[ $(flat "$2") == *"$3"* ]] || fail "$1: no \"$3\" in: $2"
}
hasnt() {
  checks=$(( checks + 1 ))
  [[ $(flat "$2") != *"$3"* ]] || fail "$1: \"$3\" in: $2"
}
shape="Your final message becomes part of the pull request description. By default write it as: What changes, Behaviour changes, Not done (with what you noticed but did not fix), How to check (what a reviewer should click or run, if anything). If the repository's instructions or the rules after these give the final message another shape, such as a team's pull request template, use that shape instead."
equals "the rules are for pr delivery when the config has no deliver" "$profile_deliver" pr
has "pr rules: jig pushes and opens the PR" "$rules" "Commit on the current branch, in small commits. Do not push or open a pull request: jig does that."
has "pr rules: a protected path makes a draft, .github/ stops the push" "$rules" \
  "Do not change these paths (\`*\` matches any characters, \`/\` included). jig opens the pull request as a draft if any of them changes, and pushes nothing if \`.github/\` changes. \`JIG_BLOCKED.md\` at the repository root is always allowed"
has "pr rules: the final message goes into the PR, in the default shape unless other rules give one" "$rules" "$shape"
hasnt "pr rules do not hand the branch over" "$rules" "hands the branch"
checks=$(( checks + 1 ))
[[ ! $rules =~ @[A-Z_]+@ ]] || fail "the pr rules keep a placeholder: $rules"
jig_parse_profile cfg <<<"base main
setup .jig/setup
verify .jig/verify
protect CLAUDE.md
deliver branch"
branch_rules="$(jig_engine_rules)"
has "branch rules: jig hands the branch over" "$branch_rules" "Commit on the current branch, in small commits. Do not push: jig hands the branch to the owner."
has "branch rules: a protected path or .github/ marks the branch for attention" "$branch_rules" \
  "Do not change these paths (\`*\` matches any characters, \`/\` included). If any of them, or anything under \`.github/\`, changes, jig hands the branch over marked for the owner's attention. \`JIG_BLOCKED.md\` at the repository root is always allowed"
has "branch rules: the final message goes into the run report, in the default shape unless other rules give one" "$branch_rules" \
  "Your final message goes into the run report. ${shape#*description. }"
for text in "pull request description" "opens the pull request" "pushes nothing" "jig does that"; do
  hasnt "branch rules do not mention a PR jig opens: $text" "$branch_rules" "$text"
done
checks=$(( checks + 1 ))
[[ ! $branch_rules =~ @[A-Z_]+@ ]] || fail "the branch rules keep a placeholder: $branch_rules"
equals "branch rules differ from pr rules only in the delivery sentences" \
  "$(diff <(printf '%s\n' "$rules") <(printf '%s\n' "$branch_rules") | grep -c '^[<>]')" 6
for mode in queue ""; do
  checks=$(( checks + 1 ))
  (profile_deliver="$mode" && jig_engine_rules >/dev/null 2>&1) && fail "rules for an unknown delivery mode are refused: \"$mode\""
done
jig_parse_profile cfg <<<"base main
setup .jig/setup
verify .jig/verify
protect CLAUDE.md"

mkdir -p "$overlay"
printf 'OVERLAY RULE: prefer small functions.\n' >"$overlay/rules.md"
overlay_rules=""
jig_write_system_prompt "$tmp/prompt.md"
equals "the system prompt without overlay rules is the engine rules" "$(cat "$tmp/prompt.md")" "$rules"
overlay_rules="$overlay/rules.md"
jig_write_system_prompt "$tmp/prompt.md"
equals "the overlay rules follow the engine rules" "$(cat "$tmp/prompt.md")" "$rules

OVERLAY RULE: prefer small functions."

overlay_plugin=""
jig_write_harness_compose "$tmp/harness.yml"
equals "the compose override without a plugin mounts the system prompt and the plan" "$(cat "$tmp/harness.yml")" 'services:
  app:
    volumes:
      - type: bind
        source: ${JIG_SYSTEM_PROMPT:?jig sets JIG_SYSTEM_PROMPT}
        target: /jig/system-prompt.md
        read_only: true
      - type: bind
        source: ${JIG_PLAN:?jig sets JIG_PLAN}
        target: /jig/plan.md
        read_only: true'
overlay_plugin="$overlay/plugin"
jig_write_harness_compose "$tmp/harness.yml"
equals "the compose override with a plugin mounts it read-only too" "$(cat "$tmp/harness.yml")" 'services:
  app:
    volumes:
      - type: bind
        source: ${JIG_SYSTEM_PROMPT:?jig sets JIG_SYSTEM_PROMPT}
        target: /jig/system-prompt.md
        read_only: true
      - type: bind
        source: ${JIG_PLAN:?jig sets JIG_PLAN}
        target: /jig/plan.md
        read_only: true
      - type: bind
        source: ${JIG_OVERLAY_PLUGIN:?jig sets JIG_OVERLAY_PLUGIN}
        target: /jig/overlay
        read_only: true'

used() {
  jig_compose_files=(-f profile.yml)
  jig_use_harness "$tmp/harness.yml" "$tmp/prompt.md" "$tmp/run/plan.md" &&
    printf '%s|%s|%s|%s|%s' "${jig_harness_args[*]}" "${jig_compose_files[*]}" "$JIG_SYSTEM_PROMPT" "$JIG_PLAN" \
      "${JIG_OVERLAY_PLUGIN-unset}"
}
overlay_plugin=""
equals "agent arguments without a plugin" "$( (unset JIG_OVERLAY_PLUGIN; used) 2>&1)" \
  "--append-system-prompt-file /jig/system-prompt.md|-f profile.yml -f $tmp/harness.yml|$tmp/prompt.md|$tmp/run/plan.md|unset"
overlay_plugin="$overlay/plugin"
equals "agent arguments with a plugin" "$( (unset JIG_OVERLAY_PLUGIN; used) 2>&1)" \
  "--append-system-prompt-file /jig/system-prompt.md --plugin-dir /jig/overlay|-f profile.yml -f $tmp/harness.yml|$tmp/prompt.md|$tmp/run/plan.md|$overlay/plugin"
equals "the prompt names the mounted plan" "$jig_plan_prompt" "Implement the plan in /jig/plan.md."

agent_options() {
  (
    profile_model="$1" profile_effort="$2"
    unset JIG_MODEL JIG_EFFORT
    [ "$3" = unset ] || export JIG_MODEL="$3"
    [ "$4" = unset ] || export JIG_EFFORT="$4"
    jig_agent_options && printf '%s|%s' "${jig_agent_args[*]+${jig_agent_args[*]}}" "$(jig_agent_settings)"
  ) 2>&1
}
equals "no model or effort: no arguments, Claude Code's defaults" "$(agent_options "" "" unset unset)" \
  "|model: default, effort: default"
equals "the profile's model and effort" "$(agent_options opus high unset unset)" \
  "--model opus --effort high|model: opus (from the profile), effort: high (from the profile)"
equals "JIG_MODEL and JIG_EFFORT override the profile" "$(agent_options opus high 'sonnet[1m]' max)" \
  "--model sonnet[1m] --effort max|model: sonnet[1m] (from JIG_MODEL), effort: max (from JIG_EFFORT)"
equals "JIG_EFFORT alone overrides only the effort" "$(agent_options opus high unset low)" \
  "--model opus --effort low|model: opus (from the profile), effort: low (from JIG_EFFORT)"
equals "JIG_MODEL without a profile model, no effort" "$(agent_options "" "" claude-opus-5-5 unset)" \
  "--model claude-opus-5-5|model: claude-opus-5-5 (from JIG_MODEL), effort: default"
equals "only an effort from the profile" "$(agent_options "" medium unset unset)" \
  "--effort medium|model: default, effort: medium (from the profile)"
equals "empty JIG_MODEL and JIG_EFFORT leave the profile's values" "$(agent_options opus high "" "")" \
  "--model opus --effort high|model: opus (from the profile), effort: high (from the profile)"

delivery() {
  (profile_deliver="$1" && jig_delivery jig/add-health) 2>&1
}
equals "the launch says that pr delivery pushes the branch and opens a PR" "$(delivery pr)" \
  "pr (pushes jig/add-health and opens a PR)"
equals "the launch says branch delivery" "$(delivery branch)" branch
for mode in queue ""; do
  checks=$(( checks + 1 ))
  out="$(delivery "$mode")" && fail "an unknown delivery mode is not named at launch: \"$mode\" -> $out"
done

fill() {
  printf "%$1s" '' | tr ' ' "$2"
}

report() {
  (
    profile_model="$1" profile_effort="$2"
    unset JIG_MODEL JIG_EFFORT
    [ "$3" = unset ] || export JIG_MODEL="$3"
    jig_agent_options && jig_agent_report "$4"
  ) 2>&1
}
meta='success, turns: 3, estimated cost $0.01'
equals "the model from the log next to turns and cost, with Claude Code's defaults" \
  "$(report "" "" unset "$meta
claude-sonnet-5-5
0")" "$meta, model: claude-sonnet-5-5 (default), effort: default"
equals "an alias from the profile and the model the log names" "$(report opus high unset "$meta
claude-opus-5-5
0")" "$meta, model: claude-opus-5-5 (opus from the profile), effort: high (from the profile)"
equals "a model name that the log confirms is named once" "$(report "" "" claude-opus-5-5 "$meta
claude-opus-5-5
0")" "$meta, model: claude-opus-5-5 (from JIG_MODEL), effort: default"
equals "the other models in the log follow the main one" "$(report "" "" unset "$meta
claude-opus-5-5
2 claude-haiku-5 claude-fake-2")" "$meta, model: claude-opus-5-5 (default), also claude-haiku-5 and claude-fake-2, effort: default"
equals "a log without a result or a model" "$(report opus "" unset "")" \
  "model: unknown (opus from the profile), effort: default"
equals "a log with a result and no model" "$(report "" low unset "$meta

0")" "$meta, model: unknown (default), effort: low (from the profile)"
equals "a log without a main model names the other models" "$(report "" "" unset "$meta

1 claude-fake-2")" "$meta, model: unknown (default), also claude-fake-2, effort: default"
for kept in 'error (error_max_turns), turns: 9' 'error, turns: 3' 'turns: 3, estimated cost $0.01' \
  'estimated cost $123456.78' success "$(fill 40 a), turns: 999999"; do
  equals "an outcome, turns and cost in jig's shape are kept: $kept" "$(report "" "" unset "$kept
claude-fake-1
0")" "$kept, model: claude-fake-1 (default), effort: default"
done
for dropped in "success"$'\e]0;title\a' $'\e[2Jsuccess, turns: 3' '**success**, turns: 3' 'success, turns: 3 [x](y)' \
  'Success, turns: 3' "$(fill 41 a), turns: 3" "error ($(fill 41 a)), turns: 3" 'success, turns: 1234567' 'success, turns: -1' \
  'success, estimated cost $1234567.00' 'success, estimated cost $0.1' 'turns: 3, success' 'success, ' ', turns: 3'; do
  equals "an outcome, turns and cost in another shape are dropped: $(printable "$dropped")" "$(report "" "" unset "$dropped
claude-fake-1
0")" "model: claude-fake-1 (default), effort: default"
done
for bad in $'claude\e[2J' 'has space' "a$(fill 100 b)" '-dash' 'x`y'; do
  equals "a main model outside the model rule is unknown: $(printable "$bad")" "$(report "" "" unset "$meta
$bad
0")" "$meta, model: unknown (default), effort: default"
done
for count in x 01 -1 1234567 ''; do
  equals "other models without a count of them are dropped: $count" "$(report "" "" unset "$meta
claude-fake-1
$count claude-haiku-5")" "$meta, model: claude-fake-1 (default), effort: default"
done
equals "other models outside the model rule are counted, not named" "$(report "" "" unset "$meta
claude-fake-1
4 claude-a x\`y claude-b $'\e[2J'")" "$meta, model: claude-fake-1 (default), also claude-a and claude-b and 2 more, effort: default"
equals "other models past a fifth are counted, not named" "$(report "" "" unset "$meta
claude-fake-1
1000 $(for n in $(seq 1 1000); do printf 'claude-m%s ' "$n"; done)")" \
  "$meta, model: claude-fake-1 (default), also claude-m1 and claude-m2 and claude-m3 and claude-m4 and claude-m5 and 995 more, effort: default"
equals "only other models, all past the names given, are counted" "$(report "" "" unset "$meta
claude-fake-1
7")" "$meta, model: claude-fake-1 (default), also 7 more, effort: default"
equals "lines after the other models are not read" "$(report "" "" unset "$meta
claude-fake-1
0
1 claude-evil")" "$meta, model: claude-fake-1 (default), effort: default"
mkdir "$tmp/glob" && : >"$tmp/glob/sonnet1"
equals "a model name is not a file pattern" "$(cd "$tmp/glob" && report "" "" unset "$meta
claude-fake-1
1 sonnet[1m]")" "$meta, model: claude-fake-1 (default), also sonnet[1m], effort: default"

repo_root="$tmp/repo"
git init -q -b main "$repo_root"
mkdir -p "$repo_root/.claude/skills/review" "$repo_root/.claude/skills/lint" "$repo_root/.claude/agents"
: >"$repo_root/.claude/skills/review/SKILL.md"
: >"$repo_root/.claude/skills/lint/SKILL.md"
: >"$repo_root/.claude/agents/critic.md"
: >"$repo_root/.claude/agents/notes.txt"
git -C "$repo_root" add -A && git -C "$repo_root" commit -q -m harness
base="$(git -C "$repo_root" rev-parse HEAD)"
mkdir -p "$repo_root/.claude/skills/deploy"
: >"$repo_root/.claude/skills/deploy/SKILL.md"
: >"$repo_root/.claude/agents/helper.md"
git -C "$repo_root" add -A && git -C "$repo_root" commit -q -m "a skill and an agent after the base"
mkdir -p "$overlay/plugin/skills/review" "$overlay/plugin/skills/deploy" "$overlay/plugin/agents"
: >"$overlay/plugin/agents/critic.md"
: >"$overlay/plugin/agents/helper.md"
: >"$overlay/plugin/agents/notes.txt"

equals "overlay names that the repository's skills and agents already have" "$(jig_harness_shadows)" \
  "the overlay plugin's skill review has the same name as .claude/skills/review in the repository; the agent sees both
the overlay plugin's agent critic has the same name as .claude/agents/critic.md in the repository; the agent sees both"
overlay_plugin=""
equals "no overlay plugin, no name warnings" "$(jig_harness_shadows)" ""
overlay_plugin="$overlay/plugin"
git -C "$repo_root" rm -q -r .claude && git -C "$repo_root" commit -q -m "no harness"
base="$(git -C "$repo_root" rev-parse HEAD)"
equals "a repository without .claude/, no name warnings" "$(jig_harness_shadows)" ""

mkdir -p "$repo_root/.claude/skills/x\`y" "$overlay/plugin/skills/x\`y"
: >"$repo_root/.claude/skills/x\`y/SKILL.md"
git -C "$repo_root" add -A && git -C "$repo_root" commit -q -m "a skill with a backtick"
base="$(git -C "$repo_root" rev-parse HEAD)"
overlay_root="$profiles"
overlay_dir="$overlay"
overlay_rules="$overlay/rules.md"
overlay_plugin="$overlay/plugin"
jig_harness_report >"$tmp/out" 2>"$tmp/err"
equals "the harness sources go to stdout with host paths" "$(cat "$tmp/out")" "jig: engine rules: $root/lib/rules.md
jig: overlay rules: $overlay/rules.md
jig: overlay plugin: $overlay/plugin"
equals "name warnings go to stderr, printable" "$(cat "$tmp/err")" \
  "jig: WARNING: the overlay plugin's skill x?y has the same name as .claude/skills/x?y in the repository; the agent sees both"
equals "the PR section has the sources without host paths and the warnings" "$jig_harness_md" '## Harness

```
engine rules: jig'"'"'s lib/rules.md
overlay rules: $JIG_PROFILES/acme/shop/rules.md
overlay plugin: $JIG_PROFILES/acme/shop/plugin
WARNING: the overlay plugin'"'"'s skill x?y has the same name as .claude/skills/x?y in the repository; the agent sees both
```
'
overlay_rules=""
overlay_plugin=""
jig_harness_report >"$tmp/out" 2>"$tmp/err"
equals "the harness sources without an overlay" "$(cat "$tmp/out")" "jig: engine rules: $root/lib/rules.md
jig: overlay rules: none (no $overlay/rules.md)
jig: overlay plugin: none (no $overlay/plugin)"
equals "the PR section without an overlay" "$jig_harness_md" '## Harness

```
engine rules: jig'"'"'s lib/rules.md
overlay rules: none (no $JIG_PROFILES/acme/shop/rules.md)
overlay plugin: none (no $JIG_PROFILES/acme/shop/plugin)
```
'

mkdir "$tmp/run"
printf '# Add a health check\n\nAnswer `GET /health` with 200.\n' >"$tmp/run/plan.md"
equals "the PR body ends with the plan, fenced in a collapsed block, before the attribution" \
  "$(jig_pr_body "$tmp/run/plan.md" copy.md '- verify: green

## Agent summary

Done.' attribution)" '- verify: green

## Agent summary

Done.

<details><summary>Plan</summary>

```markdown
# Add a health check

Answer `GET /health` with 200.
```

</details>

attribution'
printf 'Run `make` or ````:\n\n```sh\nmake\n```\n' >"$tmp/run/fenced.md"
equals "the fence is longer than the plan's longest backtick run, wherever it is in a line" \
  "$(jig_pr_body "$tmp/run/fenced.md" copy.md top end | sed -n '5p;11p')" '`````markdown
`````'

bytes() {
  LC_ALL=C wc -c | tr -d ' '
}
fill 82 p >"$tmp/run/fits.md"
fill 83 p >"$tmp/run/over.md"
utf8="$(locale -a 2>/dev/null | grep -i -m 1 -E '^(c|en_us)\.utf-?8$')"
top="$(printf '\342\206\222%.0s' $(seq 1 16))rr"
equals "a body of exactly the limit keeps the whole plan" \
  "$( (export LC_ALL="${utf8:-C}" && jig_pr_body_max=200 && jig_pr_body "$tmp/run/fits.md" copy.md "$top" t | bytes) 2>&1)" 200
equals "a plan one byte over the limit is cut, multibyte characters counted in bytes" \
  "$( (export LC_ALL="${utf8:-C}" && jig_pr_body_max=200 && jig_pr_body "$tmp/run/over.md" copy.md "$top" t | sed -n 3p) 2>&1)" \
  "<details><summary>Plan (cut)</summary>"

for n in a b c d e f g h i j k l m n o p q r s t; do
  printf 'line %s \342\206\222\n' "$n"
done >"$tmp/run/plan.md"
cut_at() {
  (export LC_ALL="${utf8:-C}" && jig_pr_body_max=$1 && jig_pr_body "$tmp/run/plan.md" copy.md top end) 2>&1
}
equals "a cut plan keeps the whole lines that fit and names its copy" "$(cut_at 186)" 'top

<details><summary>Plan (cut)</summary>

```markdown
line a →
line b →
line c →
```

*The plan is cut here: it has 220 bytes, the whole plan is in `copy.md`.*

</details>

end'
equals "the cut body fills the limit exactly" "$(cut_at 186 | bytes)" 186
equals "a line that would pass the limit by one byte is left out" "$(cut_at 185 | sed -n 5,8p)" '```markdown
line a →
line b →
```'
equals "no room for a line: the block holds only the note" "$(cut_at 160 | sed -n 3,7p)" '<details><summary>Plan (cut)</summary>

*The plan is cut here: it has 220 bytes, the whole plan is in `copy.md`.*

</details>'

{
  printf 'Steps:\n\n```sh\n'
  for n in $(seq 1 100); do
    printf 'echo %s\n' "$n"
  done
} >"$tmp/run/open-fence.md"
cut_open_fence() {
  (jig_pr_body_max=300 && jig_pr_body "$tmp/run/open-fence.md" fence-copy.md top end) 2>&1
}
equals "a plan cut inside its own open fence: jig's longer fence closes the block before the note" \
  "$(cut_open_fence | sed '/^echo /d')" 'top

<details><summary>Plan (cut)</summary>

````markdown
Steps:

```sh
````

*The plan is cut here: it has 806 bytes, the whole plan is in `fence-copy.md`.*

</details>

end'
equals "the open fence is cut after the lines that fit" "$(cut_open_fence | grep '^echo ' | sed -n '1p;$p')" 'echo 1
echo 16'

head_lines="$(for n in $(seq -w 1 20); do echo "line $n"; done)"
equals "a head that leaves no room for the plan's note is cut after its last whole line that fits" \
  "$( (export LC_ALL="${utf8:-C}" && jig_pr_body_max=218 && jig_pr_body "$tmp/run/plan.md" copy.md "$head_lines" end) 2>&1)" 'line 01
line 02
line 03

*The description is cut here to stay within GitHub'"'"'s limit.*

<details><summary>Plan (cut)</summary>

*The plan is cut here: it has 220 bytes, the whole plan is in `copy.md`.*

</details>

end'
equals "the cut head fills the limit exactly" \
  "$( (export LC_ALL="${utf8:-C}" && jig_pr_body_max=218 && jig_pr_body "$tmp/run/plan.md" copy.md "$head_lines" end | bytes) 2>&1)" 218
equals "a head line that would pass the limit by one byte is left out" \
  "$( (export LC_ALL="${utf8:-C}" && jig_pr_body_max=217 && jig_pr_body "$tmp/run/plan.md" copy.md "$head_lines" end | sed -n 1,4p) 2>&1)" 'line 01
line 02

*The description is cut here to stay within GitHub'"'"'s limit.*'

in_utf8() {
  (export LC_ALL="${utf8:-C}" && "$@") 2>&1
}
equals "a text within the limit stays whole" "$(in_utf8 jig_cut 8 'ab
cd
ef')" 'ab
cd
ef'
equals "a cut keeps the lines that fit" "$(in_utf8 jig_cut 7 'ab
cd
ef')" 'ab
cd'
equals "a cut right before a line break keeps that line" "$(in_utf8 jig_cut 5 'ab
cd
ef')" 'ab
cd'
arrows="$(printf '\342\206\222\342\206\222\342\206\222')"
equals "a cut inside a multibyte character drops the whole character" "$(in_utf8 jig_cut 5 "$arrows" | bytes)" 3
equals "a cut right after a multibyte character keeps it" "$(in_utf8 jig_cut 6 "$arrows" | bytes)" 6
equals "no room, no text" "$(in_utf8 jig_cut 0 "$arrows")" ""
equals "a negative room, no text" "$(in_utf8 jig_cut -5 "$arrows")" ""

equals "a line of the limit stays whole" "$(jig_pr_line "$(fill 200 x)")" "$(fill 200 x)"
equals "a longer line is cut to the limit and marked" "$(jig_pr_line "$(fill 201 x)")" "$(fill 197 x)..."
equals "a listed line is printable" "$(jig_pr_line "$(printf 'a\tb`c\342\206\222')")" 'a?b?c???'

fill 30 '\n' >"$tmp/run/blank.md"
equals "an excerpt quotes every line" "$(jig_pr_excerpt 200 "$tmp/run/blank.md" '> ' cut | sed -n '1p;30p')" '> 
> '
equals "quoted blank lines past the limit are cut on a line and end with the note" \
  "$(jig_pr_excerpt 20 "$tmp/run/blank.md" '> ' '> (cut)')" '> 
> 
> 
> 
> (cut)'
equals "a quoted excerpt fits the limit" "$(jig_pr_excerpt 20 "$tmp/run/blank.md" '> ' '> (cut)' | bytes)" 19
printf 'ab\ncd' >"$tmp/run/exact.md"
equals "an excerpt of exactly the limit stays whole" "$(jig_pr_excerpt 5 "$tmp/run/exact.md" '' cut)" 'ab
cd'
printf 'ab\ncd\nef' >"$tmp/run/lines.md"
equals "an excerpt one byte over the limit is cut on a line and ends with the note" \
  "$(jig_pr_excerpt 7 "$tmp/run/lines.md" '' X)" 'ab
cd
X'
printf 'abcdefghij' >"$tmp/run/letters.md"
equals "a cut excerpt fills its limit exactly" "$(jig_pr_excerpt 6 "$tmp/run/letters.md" '' X)" 'abcd
X'
printf '%s' "$arrows$arrows" >"$tmp/run/arrows.md"
equals "an excerpt without line breaks is cut on a character" \
  "$(in_utf8 jig_pr_excerpt 11 "$tmp/run/arrows.md" '' '…' | od -An -tx1 | tr -d ' \n')" e28692e286920ae280a6
for n in $(seq 1 2000); do
  printf 'Повтор %s: проверь ответ.\n' "$n"
done >"$tmp/run/summary.md"
summary="$(in_utf8 jig_pr_excerpt 40000 "$tmp/run/summary.md" '' '
*cut*')"
checks=$(( checks + 1 ))
size="$(printf '%s' "$summary" | bytes)"
[ "$size" -le 40000 ] && [ "$size" -gt 39900 ] || fail "a long multibyte summary is cut to 40,000 bytes: $size bytes"
checks=$(( checks + 1 ))
printf '%s' "$summary" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail "a cut multibyte summary is valid UTF-8"
equals "a cut summary ends with its note after a blank line" "$(printf '%s' "$summary" | tail -n 3 | sed 1d)" '
*cut*'

for n in $(seq 1 3000); do
  printf 'Step %s: change the handler and its spec.\n' "$n"
done >"$tmp/run/plan.md"
jig_pr_body "$tmp/run/plan.md" copy.md "$(fill 40000 s)" "🤖 Generated with [Claude Code](https://claude.com/claude-code)" >"$tmp/run/pr-body.md"
checks=$(( checks + 1 ))
size="$(bytes <"$tmp/run/pr-body.md")"
[ "$size" -le 65536 ] && [ "$size" -gt 65400 ] ||
  fail "a long plan next to a 40,000-byte summary fills GitHub's 65,536 characters without passing them: $size bytes"
equals "the attribution follows the cut plan" "$(tail -n 3 "$tmp/run/pr-body.md")" "</details>

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

plan_issue() {
  printf "$1" >"$tmp/run/issue.md"
  jig_plan_issue "$tmp/run/issue.md"
}
issue() {
  (plan_issue "$1" && printf '%s' "$issue_line") 2>&1
}
equals "an issue of the repository becomes Fixes" "$(issue '# Add a health check\n\nIssue: #12\n\nWhy.\n')" "Fixes #12"
equals "the Issue line right under the title, without a blank line" "$(issue '# Title\nIssue: #12\n')" "Fixes #12"
equals "blanks around the reference are dropped" "$(issue '# Title\n\nIssue:\t #12 \t\n')" "Fixes #12"
equals "a plan with CRLF line ends" "$(issue '# Title\r\n\r\nIssue: #12\r\n\r\nWhy.\r\n')" "Fixes #12"
equals "another tracker's ID is passed through" "$(issue '# Title\n\nIssue: ABC-123\n')" "Issue: ABC-123"
equals "a number with letters is passed through" "$(issue '# Title\n\nIssue: #12a\n')" "Issue: #12a"
equals "a number with a leading zero is passed through" "$(issue '# Title\n\nIssue: #012\n')" "Issue: #012"
equals "issue zero is passed through" "$(issue '# Title\n\nIssue: #0\n')" "Issue: #0"
equals "a bare # is passed through" "$(issue '# Title\n\nIssue: #\n')" "Issue: #"
equals "two numbers are passed through" "$(issue '# Title\n\nIssue: #12 #13\n')" "Issue: #12 #13"
equals "another repository's issue is passed through" "$(issue '# Title\n\nIssue: acme/web#12\n')" "Issue: acme/web#12"
equals "a passed-through reference is printable" "$(issue '# Title\n\nIssue: ABC-1`id`\001\n')" "Issue: ABC-1?id??"
equals "a passed-through reference is cut to 200 bytes" "$(issue "# Title\n\nIssue: $(fill 250 x)\n" | bytes)" 207
equals "no Issue line" "$(issue '# Title\n\nWhy.\n\n## Links\n\n- #12\n')" ""
equals "an empty Issue line" "$(issue '# Title\n\nIssue: \t\n\nWhy.\n')" ""

launch() {
  (plan_issue "$1" && printf '%s' "$issue_text") 2>&1
}
equals "the launch names the issue that the PR fixes" "$(launch '# Title\n\nIssue: #12\n')" "Fixes #12"
equals "the launch names another reference as text" "$(launch '# Title\n\nIssue: ABC-1`id`\n')" "ABC-1?id? (as text)"
equals "the launch says when there is no issue" "$(launch '# Title\n\nWhy.\n')" "none"

placeholder() {
  (plan_issue "$1"; echo "$?") 2>&1
}
equals "the template's placeholder left in the Issue line is refused" "$(placeholder '# Title\n\nIssue: <ref>\n')" 2
equals "a < in the reference is refused" "$(placeholder '# Title\n\nIssue: ABC<123\n')" 2
equals "a > in the reference is refused" "$(placeholder '# Title\n\nIssue: ABC->123\n')" 2
equals "a placeholder on a line jig does not read is no error" "$(placeholder '# Title\n\nWhy.\n\nIssue: <ref>\n')" 0
sed 's/^Issue: <ref>$/Issue: #12/' "$root/plans/TEMPLATE.md" >"$tmp/run/template.md"
equals "the filled template gives Fixes and no warnings" \
  "$( (jig_plan_issue "$tmp/run/template.md" && printf '%s|%s' "$issue_line" "$(jig_issue_warnings)") 2>&1)" "Fixes #12|"
equals "the template as is is refused" "$( (jig_plan_issue "$root/plans/TEMPLATE.md"; echo "$?") 2>&1)" 2

unread() {
  (plan_issue "$1" && printf '%s|%s' "$issue_line" "$(jig_issue_warnings)") 2>&1
}
warning() {
  printf "the plan's line %s is not read as its Issue line: %s (jig reads \"Issue: <ref>\" only as the first line under the title)" "$1" "$2"
}
equals "an Issue line after the first paragraph is not read" "$(unread '# Title\n\nWhy.\n\nIssue: #12\n')" "|$(warning 5 'Issue: #12')"
equals "an Issue line before the title is not read" "$(unread 'Issue: #12\n# Title\n')" "|$(warning 1 'Issue: #12')"
equals "an Issue line under a later heading is not read" "$(unread '# Title\n\nWhy.\n\n# Second\n\nIssue: #12\n')" \
  "|$(warning 7 'Issue: #12')"
equals "an Issue line under a second-level heading is not read" "$(unread '## Notes\n\nIssue: #12\n')" "|$(warning 3 'Issue: #12')"
equals "a lowercase issue line is not read" "$(unread '# Title\n\nissue: #12\n')" "|$(warning 3 'issue: #12')"
equals "an indented Issue line is not read" "$(unread '# Title\n\n  Issue: #12\n')" "|$(warning 3 '  Issue: #12')"
equals "a bold Issue line is not read" "$(unread '# Title\n\nWhy.\n\n**Issue:** #5\n')" "|$(warning 5 '**Issue:** #5')"
equals "an Issue word without a colon is not read" "$(unread '# Title\n\nIssue #12\n')" "|$(warning 3 'Issue #12')"
equals "an indented Issue word without a colon is not read" "$(unread '# Title\n\nWhy.\n\n  Issue #12\n')" \
  "|$(warning 5 '  Issue #12')"
equals "a bold Issue word without a colon is not read" "$(unread '# Title\n\nWhy.\n\n**Issue** #5\n')" \
  "|$(warning 5 '**Issue** #5')"
equals "a longer word that starts with Issue is not read" "$(unread '# Title\n\nIssues: #12\n')" "|$(warning 3 'Issues: #12')"
equals "a sentence that mentions an Issue line is not read" "$(unread '# Title\n\nSee Issue: #12\n')" \
  "|$(warning 3 'See Issue: #12')"
equals "a list item with an Issue label is not read" "$(unread '# Title\n\nWhy.\n\n- _issue_: #12\n')" \
  "|$(warning 5 '- _issue_: #12')"
equals "a tracker key that starts with issue is no line that is not read" "$(unread '# Title\n\nIssue: ISSUE-7\n')" \
  "Issue: ISSUE-7|"
equals "a second Issue line is not read" "$(unread '# Title\n\nIssue: #12\n\nIssue: #13\n')" "Fixes #12|$(warning 5 'Issue: #13')"
equals "each line that is not read is named" "$(unread 'issue: #1\n# Title\n\nWhy.\n\nIssue: #12\n')" \
  "|$(warning 1 'issue: #1')
$(warning 6 'Issue: #12')"
equals "a line that is not read is named without its CR" "$(unread '# Title\r\n\r\nWhy.\r\n\r\nissue: #12\r\n')" \
  "|$(warning 5 'issue: #12')"
equals "a line that is not read is named in 200 printable bytes" \
  "$(unread "# Title\n\nWhy.\n\nIssue: \`$(fill 250 x)\n")" "|$(warning 5 "Issue: ?$(fill 189 x)...")"
equals "the word issue in prose, a heading or a plural label is no Issue line" \
  "$(unread '# Title\n\nIssue: #12\n\nThis fixes the issue where it fails.\n\nKnown issues: none.\n\nReissue: the token is renewed.\n\n## Issue: notes\n\n# Issue: another title\n')" \
  "Fixes #12|"

for word in /home/dev/src/shop /srv/a_b.c-d/e=f:g@h%i+j,k; do
  equals "a plain path is a shell word as is: $word" "$(jig_shell_word "$word")" "$word"
done
for word in "/home/dev/my shop" "/srv/it's" "/srv/'a'b''" '/srv/$(id)' '/srv/a;b' '/srv/`id`' '/srv/~a' '/srv/a*' '/srv/a"b' \
  '/srv/a\b' "/srv/new
line" ''; do
  checks=$(( checks + 1 ))
  quoted="$(jig_shell_word "$word")"
  [ "$(eval "printf '%s' $quoted")" = "$word" ] && [[ $quoted == \'*\' ]] ||
    fail "a path with shell characters is one quoted shell word: $word -> $quoted"
done
equals "a quote in a path is closed, escaped and reopened" "$(jig_shell_word "/srv/it's")" "'/srv/it'\\''s'"
equals "the log command names the repository, the base commit and the branch" \
  "$(jig_log_command "/home/dev/my shop" 0123abcd jig/add-health)" "git -C '/home/dev/my shop' log --oneline 0123abcd..jig/add-health"
equals "the diff command names the repository, the base commit and the branch" \
  "$(jig_diff_command "/home/dev/my shop" 0123abcd jig/add-health)" "git -C '/home/dev/my shop' diff 0123abcd...jig/add-health"
equals "the diff command is whole for a repository path with a line break" \
  "$(jig_diff_command "/srv/new
line" 0123abcd jig/x)" "git -C '/srv/new
line' diff 0123abcd...jig/x"
equals "the report names the repository, the branch with its commits and the base" \
  "$(jig_report_branch /home/dev/shop jig/add-health 2 main 0123abcd)" "- Repository: /home/dev/shop
- Branch: jig/add-health (2 commits)
- Base: main at 0123abcd"
equals "one commit is singular" "$(jig_report_branch /home/dev/shop jig/x 1 develop 0123abcd | sed -n 2p)" \
  "- Branch: jig/x (1 commit)"

mkdir "$tmp/secrets"
equals "without secrets nothing is found, quietly" "$(jig_contains_secret "$root/README.md" 2>&1; echo "$?")" 1
equals "without secrets the stream passes as is" "$(printf 'a e2e0dummy0token b\n' | jig_redact_stream)" "a e2e0dummy0token b"
secret='acme:ghp_e2e/x&y.*[a]^$\1'
jig_add_secret CLAUDE_CODE_OAUTH_TOKEN e2e0dummy0token
jig_add_secret NPM_TOKEN "$secret"
near='near acme:ghp_e2e/x&y.*[a]^$\2 and acme:ghp_e2e/x&yQ[a]^$\1 and acme:ghp_e2e/x&y.*a^$\1'
printf 'token e2e0dummy0token here\nnpm %s and %s\nplain line\n%s\n' "$secret" "$secret" "$near" >"$tmp/secrets/log"
redacted="token [REDACTED] here
npm [REDACTED] and [REDACTED]
plain line
$near"
printf '%s\n' "$near" >"$tmp/secrets/near"
printf 'only %s\n' "$secret" >"$tmp/secrets/npm"
equals "a value with : / & and regex characters is found as a fixed string" "$(jig_contains_secret "$tmp/secrets/npm"; echo "$?")" 0
equals "near misses of the value are not found" "$(jig_contains_secret "$tmp/secrets/near"; echo "$?")" 1
equals "an unreadable file is no clean file" "$(jig_contains_secret "$tmp/secrets/missing" 2>/dev/null; echo "$?")" 2
equals "the names of the values in a file, longest value first" "$(jig_secrets_in "$tmp/secrets/log")" \
  "NPM_TOKEN
CLAUDE_CODE_OAUTH_TOKEN"
equals "only the names of the values in the file" "$(jig_secrets_in "$tmp/secrets/npm")" NPM_TOKEN
equals "no name for near misses" "$(jig_secrets_in "$tmp/secrets/near")" ""
equals "one value was found" "$(jig_values_found NPM_TOKEN)" "the NPM_TOKEN value was"
equals "two values were found, named longest value first" "$(jig_values_found "CLAUDE_CODE_OAUTH_TOKEN
NPM_TOKEN
CLAUDE_CODE_OAUTH_TOKEN")" "the NPM_TOKEN and CLAUDE_CODE_OAUTH_TOKEN values were"
equals "three values are listed with commas" \
  "$(jig_add_secret DEPLOY_KEY x && jig_values_found "$(jig_all_secrets)")" \
  "the NPM_TOKEN, CLAUDE_CODE_OAUTH_TOKEN and DEPLOY_KEY values were"
equals "all values by name" "$(jig_values_of "$(jig_all_secrets)")" "the NPM_TOKEN and CLAUDE_CODE_OAUTH_TOKEN values"
cp "$tmp/secrets/log" "$tmp/secrets/log-file"
jig_redact_file "$tmp/secrets/log-file"
equals "a file is redacted value by value as fixed strings" "$(cat "$tmp/secrets/log-file")" "$redacted"
equals "a stream is redacted the same way" "$(jig_redact_stream <"$tmp/secrets/log")" "$redacted"
rm -f "$tmp/secrets/read"
equals "a stream is redacted line by line as it comes" \
  "$( { printf 'first %s\n' "$secret"
      for n in $(seq 1 50); do [ -e "$tmp/secrets/read" ] && break; sleep 0.1; done
      if [ -e "$tmp/secrets/read" ]; then echo second; else echo "held back"; fi
    } | jig_redact_stream | { IFS= read -r line; : >"$tmp/secrets/read"; printf '%s|' "$line"; cat; })" \
  "first [REDACTED]|second"
equals "a text is redacted as fixed strings" "$(jig_redact_text "model $secret and e2e0dummy0token, not $near")" \
  "model [REDACTED] and [REDACTED], not $near"
equals "glob characters in a value match only themselves" \
  "$(jig_secret_values=('[a]*?' '\') && jig_redact_text 'a aXY [a]*? \ b')" "a aXY [REDACTED] [REDACTED] b"
printf '%s\n' '{"msg":"say a\"b\\c/&"}' 'raw a"b\c/&' 'other a\"b\c' >"$tmp/secrets/json"
equals "a value with a backslash or a quote is also looked for as JSON writes it, under the same name" \
  "$( (jig_secret_names=() && jig_secret_values=() && jig_add_secret QUOTED 'a"b\c/&' && jig_add_secret PLAIN 'a/&' &&
    printf '%s\n' "${jig_secret_names[@]}" "${jig_secret_values[@]}" "$(jig_values_found "$(jig_all_secrets)")" &&
    jig_redact_file "$tmp/secrets/json" && cat "$tmp/secrets/json") 2>&1)" \
  'QUOTED
QUOTED
PLAIN
a\"b\\c/&
a"b\c/&
a/&
the QUOTED and PLAIN values were
{"msg":"say [REDACTED]"}
raw [REDACTED]
other a\"b\c'
equals "values are kept longest first, values of one length in the order they were added" \
  "$( (jig_secret_names=() && jig_secret_values=() && jig_add_secret A abc && jig_add_secret B xabcx &&
    jig_add_secret C xyz && jig_add_secret D lo && jig_add_secret E 'q"' && printf '%s ' "${jig_secret_names[@]}" "${jig_secret_values[@]}") 2>&1)" \
  'B A C E D E xabcx abc xyz q\" lo q" '
printf '1 xabcx 2 abc 3\n' >"$tmp/secrets/overlap"
equals "the longer of two overlapping values is replaced first in a file, a stream and a text, whatever order they came in" \
  "$( (jig_secret_names=() && jig_secret_values=() && jig_add_secret SHORT abc && jig_add_secret LONG xabcx &&
    jig_redact_stream <"$tmp/secrets/overlap" && jig_redact_text "$(cat "$tmp/secrets/overlap")" && echo &&
    jig_redact_file "$tmp/secrets/overlap" && cat "$tmp/secrets/overlap") 2>&1)" \
  "1 [REDACTED] 2 [REDACTED] 3
1 [REDACTED] 2 [REDACTED] 3
1 [REDACTED] 2 [REDACTED] 3"
mkdir "$tmp/secrets/run"
printf 'a e2e0dummy0token\n' >"$tmp/secrets/run/a.log"
printf 'b %s\n' "$secret" >"$tmp/secrets/run/b.log"
printf 'c clean\n' >"$tmp/secrets/run/c.log"
printf 'd e2e0dummy0token\n' >"$tmp/secrets/run/d.log"
equals "redacted files are named with the values found in them" \
  "$(jig_redact_files "$tmp/secrets/run" a.log b.log c.log 2>&1)" \
  "jig: WARNING: the NPM_TOKEN and CLAUDE_CODE_OAUTH_TOKEN values were found in a.log b.log and replaced with [REDACTED] in $tmp/secrets/run"
equals "the redacted files keep the rest" "$(cat "$tmp/secrets/run/a.log" "$tmp/secrets/run/b.log" "$tmp/secrets/run/c.log")" \
  "a [REDACTED]
b [REDACTED]
c clean"
equals "a file that cannot be redacted is removed and named" \
  "$( (jig_redact_file() { return 1; } && jig_redact_files "$tmp/secrets/run" d.log c.log) 2>&1; ls "$tmp/secrets/run")" \
  "jig: WARNING: the CLAUDE_CODE_OAUTH_TOKEN value was found in d.log, which could not be redacted and were removed from $tmp/secrets/run
a.log
b.log
c.log"
equals "a file that cannot be scanned is named with every value" \
  "$(jig_redact_files "$tmp/secrets/run" missing.log 2>&1 | grep '^jig:')" \
  "jig: WARNING: could not scan $tmp/secrets/run/missing.log for the NPM_TOKEN and CLAUDE_CODE_OAUTH_TOKEN values"
equals "without secrets no file is touched" \
  "$( (jig_secret_names=() && jig_secret_values=() && jig_redact_files "$tmp/secrets" log) 2>&1; cat "$tmp/secrets/log")" \
  "token e2e0dummy0token here
npm $secret and $secret
plain line
$near"
jig_secret_names=()
jig_secret_values=()

read_secrets() {
  (profile_build_secrets=("$@") && jig_read_build_secrets && printf '%s|' "${jig_secret_names[@]}" "${jig_secret_values[@]}") 2>&1
}
export E2E_A='acme:ghp_x/y&z' E2E_B='[a]*?\12' E2E_EMPTY='' E2E_LINE='a
b' E2E_TAB='a	b' E2E_CR=$'a\rb'
unset E2E_UNSET
equals "build secrets join the secrets with their values, a backslash also in its JSON form" "$(read_secrets E2E_A E2E_B)" \
  "E2E_A|E2E_B|E2E_B|acme:ghp_x/y&z|[a]*?\\\\12|[a]*?\\12|"
equals "no build secrets add nothing" "$( (profile_build_secrets=() && jig_read_build_secrets && echo "${#jig_secret_values[@]}") 2>&1)" 0
equals "a build secret leaves jig's environment once read, and jig keeps its value for the build" \
  "$( (export E2E_KEEP=unrelated && profile_build_secrets=(E2E_A E2E_B) && jig_read_build_secrets &&
    printf '%s|' "${E2E_A-unset}" "${E2E_B-unset}" "$(env | grep -c -e '^E2E_A=' -e '^E2E_B=')" "${E2E_KEEP-unset}" "${jig_build_values[@]}") 2>&1)" \
  'unset|unset|0|unrelated|acme:ghp_x/y&z|[a]*?\12|'
exits_2 "an unset build secret stops jig and names it" \
  "jig: the profile's build-secret E2E_UNSET is not set: export E2E_UNSET before jig builds (jig hands its value only to docker compose, for the build)" \
  read_secrets E2E_A E2E_UNSET
exits_2 "an empty build secret counts as unset" "jig: the profile's build-secret E2E_EMPTY is not set" read_secrets E2E_EMPTY
for name in E2E_LINE E2E_TAB E2E_CR; do
  exits_2 "a build secret with a control character stops jig: $name" \
    "jig: the value of the build secret $name has a line break or another control character, which jig cannot look for in its logs" \
    read_secrets "$name"
done
equals "the refusal does not print the value" "$(read_secrets E2E_LINE | grep -c -e '^b' -e 'a	b')" 0
exits_2 "a build secret shorter than 8 characters stops jig and names it" \
  "jig: the value of the build secret E2E_SHORT is shorter than 8 characters: jig replaces it with [REDACTED] wherever it appears in its logs, and so short a value would hide ordinary text" \
  env E2E_SHORT=a2c4e6g bash -c "$(declare -f read_secrets jig_read_build_secrets jig_add_secret jig_insert_secret jig_fail); jig_name=jig; read_secrets E2E_SHORT"
equals "the short value is not printed" "$(E2E_SHORT=a2c4e6g read_secrets E2E_SHORT | grep -c a2c4e6g)" 0
equals "8 characters are enough" "$(E2E_EIGHT=a2c4e6g8 read_secrets E2E_EIGHT)" "E2E_EIGHT|a2c4e6g8|"
unset E2E_A E2E_B E2E_EMPTY E2E_LINE E2E_TAB E2E_CR E2E_SHORT E2E_EIGHT

docker() {
  printf '%s\n' "$*" >>"$tmp/docker.calls"
  case "$1 $2" in
    "context show") [ "$docker_context" != fail ] && echo "$docker_context" ;;
    *) return 1 ;;
  esac
}
builder() {
  rm -f "$tmp/docker.calls"
  (jig_use_builder && printf '%s|%s|%s' "$BUILDX_BUILDER" "$jig_builder_text" "$(env | grep '^BUILDX_BUILDER=')") 2>&1
}
docker_context=desktop-linux
equals "without BUILDX_BUILDER jig builds with the Docker context's own builder, for its own commands" "$(env -u BUILDX_BUILDER bash -c true; unset BUILDX_BUILDER; builder)" \
  "desktop-linux|desktop-linux, the builder of the Docker context|BUILDX_BUILDER=desktop-linux"
equals "jig only asks Docker for the context" "$(cat "$tmp/docker.calls")" "context show"
equals "an empty BUILDX_BUILDER counts as unset" "$(BUILDX_BUILDER='' builder)" \
  "desktop-linux|desktop-linux, the builder of the Docker context|BUILDX_BUILDER=desktop-linux"
equals "a BUILDX_BUILDER that is set is left alone" "$(BUILDX_BUILDER=mybuilder builder; echo "|$(cat "$tmp/docker.calls" 2>/dev/null)")" \
  "mybuilder|mybuilder from BUILDX_BUILDER|BUILDX_BUILDER=mybuilder|"
equals "the builder's name is printable" "$(BUILDX_BUILDER=$'my\033builder' builder | cut -d'|' -f2)" "my?builder from BUILDX_BUILDER"
docker_context=fail
exits_2 "a context that cannot be read stops jig" \
  "jig: could not read the current Docker context (docker context show), whose builder jig builds with: set BUILDX_BUILDER to a builder" \
  env -u BUILDX_BUILDER bash -c "$(declare -f docker jig_use_builder jig_fail printable); jig_name=jig tmp='$tmp' docker_context=fail; jig_use_builder"
unset docker_context

gib=1048576
df() {
  printf '%s\n' "$*" >>"$tmp/df.calls"
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  case "$2" in
    "$tmp/docker-root") echo "/dev/vm 100 50 $root_kib 50% /var/lib/docker" ;;
    *) echo "/dev/disk3s5 100 50 $home_kib 50% /System/Volumes/Data" ;;
  esac
}
docker() {
  printf '%s\n' "$*" >>"$tmp/docker.calls"
  case "$1" in
    info) [ "$docker_root" != fail ] && echo "$docker_root" ;;
    *) return 1 ;;
  esac
}
disk() {
  rm -f "$tmp/df.calls" "$tmp/docker.calls"
  (jig_home="$tmp/home/.jig" && jig_check_disk) 2>&1
}
mkdir "$tmp/docker-root"
unset JIG_MIN_FREE_GB
home_kib=$(( 20 * gib )) root_kib=$(( 20 * gib )) docker_root=/var/lib/docker
equals "20 GiB free passes the default" "$(disk)" ""
equals "a JIG_HOME that does not exist yet is checked on its nearest directory" "$(cat "$tmp/df.calls")" "-Pk $tmp"
equals "Docker's data root is asked for" "$(cat "$tmp/docker.calls")" "info --format {{.DockerRootDir}}"
home_kib=$(( 20 * gib - 1 ))
exits_2 "less than 20 GiB free under JIG_HOME stops jig, saying how much is free and what to do" \
  "jig: the filesystem of JIG_HOME ($tmp/home/.jig) has 19.9 GiB free, less than JIG_MIN_FREE_GB=20. Free space before jig builds (docker system df shows what Docker holds, docker builder prune removes its build cache), or lower JIG_MIN_FREE_GB (0 turns the check off)" \
  disk
home_kib=$(( 3 * gib / 2 ))
exits_2 "JIG_MIN_FREE_GB sets the limit" "has 1.5 GiB free, less than JIG_MIN_FREE_GB=2." env JIG_MIN_FREE_GB=2 bash -c "$(declare -f df docker disk jig_check_disk jig_check_free jig_free_kib jig_fail printable); jig_name=jig tmp='$tmp' home_kib=$home_kib root_kib=$root_kib docker_root=$docker_root jig_min_free_re='$jig_min_free_re'; disk"
equals "JIG_MIN_FREE_GB=1 passes 1.5 GiB" "$(JIG_MIN_FREE_GB=1 disk)" ""
equals "JIG_MIN_FREE_GB=0 turns the check off" "$(JIG_MIN_FREE_GB=0 home_kib=0 disk; cat "$tmp/df.calls" "$tmp/docker.calls" 2>/dev/null)" ""
equals "an empty JIG_MIN_FREE_GB is the default" "$(JIG_MIN_FREE_GB='' home_kib=$(( 19 * gib )) disk | grep -c 'JIG_MIN_FREE_GB=20\.')" 1
for value in abc -1 1.5 01 ' 5' '5 ' 1234567 0x10 '5;id'; do
  exits_2 "JIG_MIN_FREE_GB must be a whole number: $value" \
    "jig: JIG_MIN_FREE_GB must be a whole number of GiB (0 turns the check off)" env JIG_MIN_FREE_GB="$value" \
    bash -c "$(declare -f df docker disk jig_check_disk jig_check_free jig_free_kib jig_fail printable); jig_name=jig tmp='$tmp' home_kib=$home_kib jig_min_free_re='$jig_min_free_re'; disk"
done
equals "the largest JIG_MIN_FREE_GB is accepted" "$(JIG_MIN_FREE_GB=999999 home_kib=$(( 999999 * gib )) disk)" ""
home_kib=$(( 20 * gib )) docker_root="$tmp/docker-root"
equals "Docker's data root on the host is checked too" "$(disk; cat "$tmp/df.calls")" "-Pk $tmp
-Pk $tmp/docker-root"
root_kib=$(( 5 * gib ))
exits_2 "Docker's data root with too little space stops jig" \
  "jig: the filesystem of Docker's data root ($tmp/docker-root) has 5.0 GiB free, less than JIG_MIN_FREE_GB=20." disk
docker_root=/nonexistent/var/lib/docker
equals "a data root inside Docker Desktop's VM is skipped" "$(disk; cat "$tmp/df.calls")" "-Pk $tmp"
docker_root=fail
exits_2 "Docker that does not answer stops jig" "jig: Docker is not running" disk
docker_root=/var/lib/docker home_kib=n/a
exits_2 "df output without a number stops jig" "jig: could not read the free space of the filesystem of JIG_HOME ($tmp/home/.jig) (df -Pk $tmp)" disk
unset -f df

mkdir "$tmp/compose"
cat >"$tmp/compose/build.json" <<'EOF'
{
  "name": "jig-run_acme_shop_x",
  "networks": {
    "default": {
      "name": "jig-run_acme_shop_x_default",
      "ipam": {}
    }
  },
  "secrets": {
    "E2E_SECRET": {
      "name": "jig-run_acme_shop_x_E2E_SECRET",
      "environment": "E2E_SECRET"
    }
  },
  "services": {
    "app": {
      "build": {
        "context": "/srv/profile/.jig",
        "dockerfile": "Dockerfile",
        "args": {
          "E2E_SECRET": "uid"
        },
        "labels": {
          "E2E_SECRET": "label"
        },
        "secrets": [
          {
            "source": "E2E_SECRET"
          }
        ]
      },
      "command": [
        "sleep",
        "infinity"
      ],
      "environment": {
        "E2E_OTHER": "x",
        "HOME": "/tmp",
        "JIG_BASE": "0123"
      },
      "image": "acme-shop-jig",
      "labels": {
        "E2E_SECRET": "service label"
      },
      "networks": {
        "default": null
      }
    },
    "db.1": {
      "environment": {}
    },
    "worker": {
      "build": {
        "context": "/srv/profile/.jig"
      },
      "environment": {
        "MULTI": "a\nb \"E2E_SECRET\": x"
      }
    }
  }
}
EOF
sed 's/"HOME": "\/tmp",/"E2E_SECRET": "@E2E_SECRET@",\
        "HOME": "\/tmp",/' "$tmp/compose/build.json" >"$tmp/compose/env_name.json"
sed 's/"HOME": "\/tmp",/"TOKEN": "x@E2E_SECRET@y",/' "$tmp/compose/build.json" >"$tmp/compose/env_value.json"
sed 's/"E2E_SECRET": "uid"/"UID": "@E2E_SECRET@"/' "$tmp/compose/build.json" >"$tmp/compose/arg_value.json"
sed 's/"HOME": "\/tmp",/"OTHER_TOKEN": "real:$$v\/\\u0026\\u003c\\"x\\\\1\\u003e",/' "$tmp/compose/build.json" >"$tmp/compose/value_go.json"
sed 's/"HOME": "\/tmp",/"OTHER_TOKEN": "real:$v\/\&<\\"x\\\\1>",/' "$tmp/compose/build.json" >"$tmp/compose/value_json.json"
sed 's/"E2E_SECRET": "service label"/"KEY": "a real-E2E_KEY-value b"/' "$tmp/compose/build.json" >"$tmp/compose/value_raw.json"
sed 's/"HOME": "\/tmp",/"OTHER_TOKEN": "real:$$v\/\\u0026\\u003c\\"x\\\\2\\u003e real:$v\/\&<\\"x\\\\2> real-E2E_KEY-valu",/' "$tmp/compose/build.json" >"$tmp/compose/value_near.json"
sed '/"worker": {/,/^    }$/d; s/^    "db.1": {/    "worker": {/; /^      "build": {/,/^      },$/d' "$tmp/compose/build.json" >"$tmp/compose/no_build.json"
sed 's/"app": {/"web": {/' "$tmp/compose/build.json" >"$tmp/compose/no_app.json"
sed -e 's/^  "name": "jig-run_acme_shop_x",$/  "configs": {\
    "c_key": {\
      "name": "jig-run_acme_shop_x_c_key",\
      "environment": "E2E_KEY"\
    },\
    "c_other": {\
      "name": "jig-run_acme_shop_x_c_other",\
      "environment": "E2E_OTHER"\
    }\
  },\
&/' -e 's/^      "environment": "E2E_SECRET"$/&\
    },\
    "s_other": {\
      "name": "jig-run_acme_shop_x_s_other",\
      "environment": "E2E_OTHER"\
    },\
    "s_file": {\
      "name": "jig-run_acme_shop_x_s_file",\
      "file": "\/srv\/E2E_SECRET"/' -e 's/^      "image": "acme-shop-jig",$/&\
      "secrets": [\
        {\
          "source": "s_other",\
          "target": "\/run\/secrets\/s_other"\
        },\
        {\
          "source": "s_file",\
          "target": "\/run\/secrets\/s_file"\
        }\
      ],/' -e 's/^    "db.1": {$/&\
      "configs": [\
        {\
          "source": "c_other"\
        }\
      ],/' "$tmp/compose/build.json" >"$tmp/compose/runtime.json"
sed 's/"source": "s_other",/"source": "E2E_SECRET",/' "$tmp/compose/runtime.json" >"$tmp/compose/runtime_secret.json"
sed '/^    "db.1": {$/,/^    }/s/"source": "c_other"/"source": "c_key"/' "$tmp/compose/runtime.json" >"$tmp/compose/runtime_config.json"
sed 's/"db.1": {/"db 1": {/' "$tmp/compose/build.json" >"$tmp/compose/bad_name.json"
sed 's/"services": {/"services":{/' "$tmp/compose/build.json" >"$tmp/compose/no_services.json"
docker() {
  printf '%s|E2E_SECRET=%s\n' "$*" "${E2E_SECRET-unset}" >>"$tmp/docker.calls"
  case "$1 ${*: -3}" in
    "compose config --format json")
      [ "$fixture" != fail ] || return 1
      config_text="$(cat "$tmp/compose/$fixture.json")"
      printf '%s\n' "${config_text//@E2E_SECRET@/${E2E_SECRET-}}" ;;
    *) return 1 ;;
  esac
}
inspect() {
  rm -f "$tmp/docker.calls" "$tmp/compose/compose.build.yml"
  (
    jig_project=jig-run_acme_shop_x gh_repo=acme/shop
    jig_compose_files=(-f /srv/profile/.jig/compose.yml -f /srv/compose.profile.yml)
    read -r -a profile_build_secrets <<<"${inspect_names-E2E_SECRET E2E_KEY}"
    jig_build_values=()
    for name in "${profile_build_secrets[@]}"; do
      case "$name" in
        E2E_SECRET) jig_build_values+=('real:$v/&<"x\1>') ;;
        *) jig_build_values+=("real-$name-value") ;;
      esac
    done
    if jig_check_compose "$tmp/compose"; then
      printf 'ok|%s|%s' "${jig_build_services[*]-}" "${jig_compose_files[*]}"
    else
      printf 'refused|%s' "$jig_compose_problem"
    fi
  ) 2>&1
}
fixture=build
equals "services that build are found and get jig's label file" "$(inspect)" \
  "ok|app worker|-f /srv/profile/.jig/compose.yml -f /srv/compose.profile.yml -f $tmp/compose/compose.build.yml"
equals "the config is read with markers in place of the build secrets' values" "$(cat "$tmp/docker.calls")" \
  "compose -p jig-run_acme_shop_x -f /srv/profile/.jig/compose.yml -f /srv/compose.profile.yml config --format json|E2E_SECRET=jig_build_secret_marker_E2E_SECRET_end"
equals "the label file labels each service that builds with the repository and names the image of one the profile leaves unnamed" \
  "$(cat "$tmp/compose/compose.build.yml")" 'services:
  "app":
    build:
      labels:
        jig.repo: "acme/shop"
  "worker":
    image: "jig-acme_shop-worker"
    build:
      labels:
        jig.repo: "acme/shop"'
image_names() {
  local service
  for service in "$@"; do
    jig_image_name "$service"
    echo
  done
}
equals "an image name keeps lowercase names and turns others into lowercase, digits and dashes with a checksum of the original" \
  "$(gh_repo=Acme.Inc/My_Repo image_names app Web.API Web-API _ db-1)" \
  "jig-acme-inc-2169544754_my-repo-3261712207-app
jig-acme-inc-2169544754_my-repo-3261712207-web-api-1602141869
jig-acme-inc-2169544754_my-repo-3261712207-web-api-2221479482
jig-acme-inc-2169544754_my-repo-3261712207-397289535
jig-acme-inc-2169544754_my-repo-3261712207-db-1"
equals "image names are valid Docker repository names" \
  "$(gh_repo=x/.-_ image_names A -a- a..b 9 | LC_ALL=C grep -c -v -E '^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*$')" 0
fixture=no_build
equals "without a service that builds there is no label file" "$(inspect; [ -e "$tmp/compose/compose.build.yml" ] && echo ' file')" \
  "ok||-f /srv/profile/.jig/compose.yml -f /srv/compose.profile.yml"
fixture=env_name
equals "a build secret's name in a service's environment is refused" "$(inspect)" \
  "refused|the build secret E2E_SECRET is in the environment of the service app (docker compose config): jig never passes a build secret into a container. Remove it from the service's environment and env_file; the build gets it from a top-level secret with environment: E2E_SECRET"
fixture=env_value
equals "a build secret's value in another variable is refused" "$(inspect)" \
  "refused|the value of the build secret E2E_SECRET reaches the compose project (docker compose config resolves \${E2E_SECRET} in it: in an environment value, a build arg, a label or elsewhere): jig never passes a build secret into a container. The build gets it from a top-level secret with environment: E2E_SECRET"
equals "a build secret whose name starts another's is not named for the other's marker" "$(inspect_names='E2E_SEC E2E_SECRET' inspect | cut -d: -f1)" \
  "refused|the value of the build secret E2E_SECRET reaches the compose project (docker compose config resolves \${E2E_SECRET} in it"
fixture=arg_value
equals "a build secret's value in a build arg is refused" "$(inspect | cut -d: -f1)" \
  "refused|the value of the build secret E2E_SECRET reaches the compose project (docker compose config resolves \${E2E_SECRET} in it"
fixture=runtime
equals "runtime secrets and configs that take no build secret pass" "$(inspect)" \
  "ok|app worker|-f /srv/profile/.jig/compose.yml -f /srv/compose.profile.yml -f $tmp/compose/compose.build.yml"
fixture=runtime_secret
equals "a runtime secret that takes a build secret is refused" "$(inspect)" \
  "refused|the build secret E2E_SECRET reaches the service app as its runtime secret E2E_SECRET (the top-level secret E2E_SECRET takes environment: E2E_SECRET): jig never passes a build secret into a container. Remove E2E_SECRET from the service's secrets; the build gets it under build: secrets:"
fixture=runtime_config
equals "a config that takes a build secret is refused" "$(inspect)" \
  "refused|the build secret E2E_KEY reaches the service db.1 as its runtime config c_key (the top-level config c_key takes environment: E2E_KEY): jig never passes a build secret into a container. Remove c_key from the service's configs; the build gets it under build: secrets:"
fixture=value_go
equals "a build secret's value in the config as compose writes it, \$ doubled and JSON-escaped, from an env_file for example, is refused" "$(inspect)" \
  "refused|the value of the build secret E2E_SECRET is in the compose project that docker compose config resolves (an env_file or another variable holds it): jig never passes a build secret into a container. Remove the value from there; the build gets it from a top-level secret with environment: E2E_SECRET"
fixture=value_json
equals "a build secret's value in the config with only its backslash and quote escaped and a single \$ is refused" "$(inspect | cut -d'(' -f1)" \
  "refused|the value of the build secret E2E_SECRET is in the compose project that docker compose config resolves "
fixture=value_raw
equals "a build secret's value as it is, in a label, is refused" "$(inspect | cut -d'(' -f1)" \
  "refused|the value of the build secret E2E_KEY is in the compose project that docker compose config resolves "
fixture=value_near
equals "near misses of the values pass" "$(inspect | cut -d'|' -f1)" ok
equals "a search that fails is refused" "$(grep() { return 2; } && inspect)" \
  "refused|could not search docker compose config for the build secrets' values"
fixture=no_app
equals "a project without the app service is refused" "$(inspect)" "refused|docker compose config shows no service app"
fixture=bad_name
equals "a service name out of shape is refused" "$(inspect)" "refused|could not read the services from docker compose config --format json"
fixture=no_services
equals "a config without the services block is refused" "$(inspect)" "refused|could not read the services from docker compose config --format json"
fixture=fail
equals "a failing docker compose config is refused" "$(inspect)" "refused|docker compose config failed on the profile's compose files and jig's"
unset fixture config_text

docker() {
  printf '%s%s\n' "$*" "$( [ "${NPM_TOKEN-}" != "$secret" ] || printf ' (NPM_TOKEN set)')" >>"$tmp/docker.calls"
  case "$1 $2" in
    "compose -p")
      printf 'build step 1\nbuild sees %s\n' "$secret"
      return "$build_status" ;;
    "image prune")
      [ "$prune" != fail ] || { echo "prune failed"; return 1; }
      [ "$prune" = none ] || printf 'Deleted Images:\ndeleted: sha256:0123\n\n'
      echo "Total reclaimed space: 1.5MB" ;;
    *) return 1 ;;
  esac
}
build() {
  rm -f "$tmp/docker.calls" "$tmp/compose/build.log"
  (
    jig_project=jig-run_acme_shop_x gh_repo=acme/shop jig_builder_text="desktop-linux, the builder of the Docker context"
    jig_compose_files=(-f /srv/compose.yml)
    jig_secret_names=(NPM_TOKEN) jig_secret_values=("$secret")
    profile_build_secrets=(NPM_TOKEN) jig_build_values=("$secret")
    jig_build_services=("$@")
    jig_build "$tmp/compose/build.log"
    echo "status $?"
    [ -z "${NPM_TOKEN+set}" ] || echo "NPM_TOKEN stays set after the build"
  ) 2>&1
}
build_status=0 prune=some
equals "the build runs with the redacted output on the terminal, then prunes" "$(build app worker)" \
  "jig: building app worker with desktop-linux, the builder of the Docker context (log: $tmp/compose/build.log)
build step 1
build sees [REDACTED]
jig: removed the dangling images labelled jig.repo=acme/shop (reclaimed 1.5MB)
status 0"
equals "docker builds the project with the build secret in its environment and prunes only the repository's dangling images without it" \
  "$(cat "$tmp/docker.calls")" \
  "compose -p jig-run_acme_shop_x -f /srv/compose.yml build (NPM_TOKEN set)
image prune -f --filter label=jig.repo=acme/shop"
equals "build.log has the redacted build output and the prune output" "$(cat "$tmp/compose/build.log")" "build step 1
build sees [REDACTED]
Deleted Images:
deleted: sha256:0123

Total reclaimed space: 1.5MB"
equals "without a service that builds nothing runs and no build.log is written" \
  "$(build; cat "$tmp/docker.calls" 2>/dev/null; [ -e "$tmp/compose/build.log" ] && echo log)" "status 0"
prune=none
equals "a prune that removes nothing is not announced" "$(build app | sed -n '4,$p')" "status 0"
prune=fail
equals "a failing prune is a warning" "$(build app | sed -n '4,$p')" \
  "jig: WARNING: could not remove the dangling images of acme/shop (docker image prune): see $tmp/compose/build.log
status 0"
equals "the prune's error is in build.log" "$(tail -n 1 "$tmp/compose/build.log")" "prune failed"
build_status=17 prune=some
equals "a failing build returns its code and prunes nothing" "$(build app | tail -n 1; cat "$tmp/docker.calls")" "status 17
compose -p jig-run_acme_shop_x -f /srv/compose.yml build (NPM_TOKEN set)"
unset -f docker
unset build_status prune

mkdir "$tmp/argv" "$tmp/argv-run"
for command in awk cat cksum cut env grep head mv rm sed sort tail tee tr wc; do
  real="$(command -v "$command")" || continue
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >>"%s/argv.log"\nexec "%s" "$@"\n' "$command" "$tmp" "$real" >"$tmp/argv/$command"
  chmod +x "$tmp/argv/$command"
done
docker() {
  printf 'docker %s\n' "$*" >>"$tmp/argv.log"
  case "$1 ${*: -1}" in
    "compose json") cat "$tmp/compose/build.json" ;;
    "compose build") printf 'build sees %s\n' "${E2E_ARGV-}" ;;
    "image label=jig.repo=acme/shop") printf 'Deleted Images:\nTotal reclaimed space: 1B\n' ;;
    *) return 1 ;;
  esac
}
argv_token=e2e0argv0credential0value
argv_value='acme:ghp_argv/x&y"z\1'
printf 'token %s\nvalue %s\nclean\n' "$argv_token" "$argv_value" >"$tmp/argv-run/a.log"
(
  PATH="$tmp/argv:$PATH"
  jig_secret_names=() jig_secret_values=()
  jig_add_secret CLAUDE_CODE_OAUTH_TOKEN "$argv_token"
  export E2E_ARGV="$argv_value"
  profile_build_secrets=(E2E_ARGV)
  jig_read_build_secrets
  jig_contains_secret "$tmp/argv-run/a.log"
  jig_secrets_in "$tmp/argv-run/a.log"
  jig_redact_text "x $argv_value"
  printf 'x %s\n' "$argv_value" | jig_redact_stream
  jig_redact_files "$tmp/argv-run" a.log
  jig_project=jig-run_acme_shop_x gh_repo=acme/shop jig_builder_text=desktop-linux jig_compose_files=(-f /srv/compose.yml)
  jig_check_compose "$tmp/argv-run" && jig_build "$tmp/argv-run/build.log"
) >"$tmp/argv-run/out" 2>&1
unset -f docker
equals "the scan, the redaction, the compose check and the build ran grep, awk, sed, tee and docker" \
  "$(for command in grep awk sed tee docker; do grep -c "^$command " "$tmp/argv.log" | sed "s/^0$/no $command/;s/^[0-9]*$/$command/"; done | tr '\n' ' ')" \
  "grep awk sed tee docker "
equals "no secret value is on the command line of a command they run, the credential's included" \
  "$(LC_ALL=C grep -c -F -f <(printf '%s\n' "$argv_token" "$argv_value" 'acme:ghp_argv/x&y\"z\\1') "$tmp/argv.log")" 0

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
