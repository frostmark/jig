#!/bin/bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"
engine_root="$root"
jig_name=jig
. "$root/lib/common.sh"
. "$root/lib/profile.sh"
. "$root/lib/harness.sh"

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

gh_owner=acme
gh_name=shop
jig_home="$tmp/home"
profiles="$tmp/profiles"
overlay="$profiles/acme/shop"

find_in() {
  JIG_PROFILES="$1"
  jig_find_overlay
}

found() {
  (find_in "$1" && printf '%s|%s|%s' "$overlay_dir" "$overlay_rules" "$overlay_plugin") 2>&1
}

unset JIG_PROFILES
equals "the overlay root defaults to JIG_HOME/profiles" \
  "$( (jig_find_overlay && printf '%s|%s|%s' "$overlay_dir" "$overlay_rules" "$overlay_plugin") 2>&1)" \
  "$tmp/home/profiles/acme/shop||"
equals "no overlay directory: no rules, no plugin" "$(found "$profiles")" "$overlay||"
exits_2 "a relative JIG_PROFILES" "JIG_PROFILES must be an absolute path" find_in profiles

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
: >"$overlay/plugin"
exits_2 "plugin is a file" "the overlay plugin $overlay/plugin must be a directory" find_in "$profiles"
rm "$overlay/plugin"
rmdir "$overlay"
: >"$overlay"
exits_2 "the repository's overlay is a file" "the overlay $overlay must be a directory" find_in "$profiles"
rm "$overlay"

overlay_dir="$overlay"
overlay_rules=""
overlay_plugin=""
equals "sources without an overlay" "$(jig_harness_sources)" "engine rules: $root/lib/rules.md
overlay rules: none (no $overlay/rules.md)
overlay plugin: none (no $overlay/plugin)"
overlay_rules="$overlay/rules.md"
overlay_plugin="$overlay/plugin"
equals "sources with an overlay" "$(jig_harness_sources)" "engine rules: $root/lib/rules.md
overlay rules: $overlay/rules.md
overlay plugin: $overlay/plugin"

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

rules="$(jig_engine_rules)"
checks=$(( checks + 1 ))
[[ $rules == *'Run `./bin/verify` yourself'* ]] || fail "the engine rules name the verify command: $rules"
checks=$(( checks + 1 ))
[[ $rules == *'draft if any of them changes, and pushes nothing if `.github/` changes.
  - `.jig/*`
  - `bin/verify`'* ]] || fail "the engine rules list the protected paths under their rule: $rules"
checks=$(( checks + 1 ))
[[ $rules != *@VERIFY@* && $rules != *@PROTECTED@* ]] || fail "the engine rules keep a placeholder: $rules"
checks=$(( checks + 1 ))
[[ $rules == *JIG_BLOCKED.md* && $rules == *"What changes, Behaviour"* ]] ||
  fail "the engine rules carry JIG_BLOCKED.md and the final message format: $rules"

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
equals "the compose override without a plugin mounts only the system prompt" "$(cat "$tmp/harness.yml")" 'services:
  app:
    volumes:
      - type: bind
        source: ${JIG_SYSTEM_PROMPT:?jig sets JIG_SYSTEM_PROMPT}
        target: /jig/system-prompt.md
        read_only: true'
overlay_plugin="$overlay/plugin"
jig_write_harness_compose "$tmp/harness.yml"
equals "the compose override with a plugin mounts it read-only" "$(cat "$tmp/harness.yml")" 'services:
  app:
    volumes:
      - type: bind
        source: ${JIG_SYSTEM_PROMPT:?jig sets JIG_SYSTEM_PROMPT}
        target: /jig/system-prompt.md
        read_only: true
      - type: bind
        source: ${JIG_OVERLAY_PLUGIN:?jig sets JIG_OVERLAY_PLUGIN}
        target: /jig/overlay
        read_only: true'

used() {
  jig_compose_files=(-f profile.yml)
  jig_use_harness "$tmp/harness.yml" "$tmp/prompt.md" &&
    printf '%s|%s|%s|%s' "${jig_harness_args[*]}" "${jig_compose_files[*]}" "$JIG_SYSTEM_PROMPT" "${JIG_OVERLAY_PLUGIN-unset}"
}
overlay_plugin=""
equals "agent arguments without a plugin" "$( (unset JIG_OVERLAY_PLUGIN; used) 2>&1)" \
  "--append-system-prompt-file /jig/system-prompt.md|-f profile.yml -f $tmp/harness.yml|$tmp/prompt.md|unset"
overlay_plugin="$overlay/plugin"
equals "agent arguments with a plugin" "$( (unset JIG_OVERLAY_PLUGIN; used) 2>&1)" \
  "--append-system-prompt-file /jig/system-prompt.md --plugin-dir /jig/overlay|-f profile.yml -f $tmp/harness.yml|$tmp/prompt.md|$overlay/plugin"

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

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
