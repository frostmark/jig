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

tmp="$(mktemp -d "${TMPDIR:-/tmp}/jig-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

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

jig_write_system_prompt "$tmp/prompt.md"
equals "the system prompt is the engine rules" "$(cat "$tmp/prompt.md")" "$rules"

jig_write_harness_compose "$tmp/harness.yml"
equals "the compose override mounts the system prompt read-only" "$(cat "$tmp/harness.yml")" 'services:
  app:
    volumes:
      - type: bind
        source: ${JIG_SYSTEM_PROMPT:?jig sets JIG_SYSTEM_PROMPT}
        target: /jig/system-prompt.md
        read_only: true'

used() {
  jig_compose_files=(-f profile.yml)
  jig_use_harness "$tmp/harness.yml" "$tmp/prompt.md" &&
    printf '%s|%s|%s' "${jig_harness_args[*]}" "${jig_compose_files[*]}" "$JIG_SYSTEM_PROMPT"
}
equals "agent arguments and compose files" "$(used 2>&1)" \
  "--append-system-prompt-file /jig/system-prompt.md|-f profile.yml -f $tmp/harness.yml|$tmp/prompt.md"

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
