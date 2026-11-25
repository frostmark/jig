#!/bin/bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"
engine_root="$root"
jig_name=jig
. "$root/lib/common.sh"
. "$root/lib/profile.sh"
. "$root/lib/harness.sh"
. "$root/lib/pr.sh"

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

fill() {
  printf "%$1s" '' | tr ' ' "$2"
}
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

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
