#!/bin/bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"
jig_name=jig
. "$root/lib/common.sh"
. "$root/lib/profile.sh"

failures=0
checks=0

fail() {
  failures=$(( failures + 1 ))
  echo "FAIL: $*"
}

parses() {
  local name="$1" text="$2" out status
  checks=$(( checks + 1 ))
  out="$( (jig_parse_profile cfg <<<"$text") 2>&1)"
  status=$?
  [ "$status" = 0 ] || fail "$name: refused with exit $status: $out"
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

parse_text() {
  jig_parse_profile cfg <<<"$1"
}

refused() {
  exits_2 "$1" "$3" parse_text "$2"
}

equals() {
  local name="$1" got="$2" want="$3"
  checks=$(( checks + 1 ))
  [ "$got" = "$want" ] || fail "$name: got \"$got\", expected \"$want\""
}

protected() {
  checks=$(( checks + 1 ))
  jig_protected "$1" || fail "$1 must be protected"
}

not_protected() {
  checks=$(( checks + 1 ))
  if jig_protected "$1"; then fail "$1 must not be protected"; fi
}

valid='base main
setup .jig/setup
verify scripts/verify'

parses "minimal profile" "$valid"
parses "comments, blank lines, tabs and trailing blanks" "# profile

base	main
  # indented comment
setup .jig/setup
verify scripts/verify
protect *.md"
parses "branch with slashes and dots" "base release/2.0
setup s
verify v"
parses "no newline at the end" "$(printf 'base main\nsetup s\nverify v')"

jig_parse_profile cfg <<<"# header
base	develop
setup .jig/setup
verify scripts/verify
protect CLAUDE.md
protect */CLAUDE.md
protect deploy/*"
equals "base" "$profile_base" develop
equals "setup" "$profile_setup" .jig/setup
equals "verify" "$profile_verify" scripts/verify
equals "protect count" "${#profile_protect[@]}" 3
equals "protect order" "${profile_protect[*]}" "CLAUDE.md */CLAUDE.md deploy/*"

refused "unknown key" "$valid
colour red" "cfg:4: unknown key colour"
refused "missing base" "setup s
verify v" "cfg: missing the required key base"
refused "missing setup" "base main
verify v" "cfg: missing the required key setup"
refused "missing verify" "base main
setup s" "cfg: missing the required key verify"
refused "empty file" "" "missing the required key base"
refused "repeated base" "base main
base develop
setup s
verify v" "cfg:2: base is already set on line 1"
refused "repeated setup" "$valid
setup other" "cfg:4: setup is already set on line 2"
refused "repeated verify" "$valid
verify other" "cfg:4: verify is already set on line 3"
refused "key without value" "base" "cfg:1: expected a line"
refused "value with a space" "base main
setup .jig/setup --fast" "cfg:2: expected a line"
refused "indented key" " base main" "cfg:1: expected a line"
refused "upper-case key" "Base main" "cfg:1: expected a line"
refused "inline comment" "base main # the default" "cfg:1: expected a line"
refused "shell in base" 'base main;rm' "cfg:1: base must be"
refused "command substitution in base" 'base $(id)' "cfg:1: base must be"
refused "base starting with a dash" "base -main" "cfg:1: base must be"
refused "base with .." "base a..b" "cfg:1: base must be"
refused "base ending with .lock" "base main.lock" "cfg:1: base must be"
refused "carriage return" "$(printf 'base main\r\nsetup s\nverify v')" "cfg:1: base must be"
refused "setup escaping the repo" "base main
setup ../outside" "cfg:2: setup must be"
refused "setup with a . part" "base main
setup .jig/./setup" "cfg:2: setup must be"
refused "absolute setup" "base main
setup /usr/bin/env" "cfg:2: setup must be"
refused "setup starting with a dash" "base main
setup -x" "cfg:2: setup must be"
refused "setup with a trailing slash" "base main
setup .jig/" "cfg:2: setup must be"
refused "setup with a double slash" "base main
setup .jig//setup" "cfg:2: setup must be"
refused "verify with a variable" 'base main
setup s
verify bin/$HOME' "cfg:3: verify must be"
refused "verify that is just .." "base main
setup s
verify .." "cfg:3: verify must be"
refused "absolute protect" "$valid
protect /deploy/*" "cfg:4: protect must be"
refused "protect with a bracket class" "$valid
protect deploy/[a-z]*" "cfg:4: protect must be"
refused "protect with ?" "$valid
protect deploy/?" "cfg:4: protect must be"
refused "protect with a backslash" "$valid
protect deploy\\*" "cfg:4: protect must be"

slug=add-health-check
jig_parse_profile cfg <<<"base main
setup bin/setup
verify scripts/verify"

protected ".jig/config"
protected ".jig/docker/Dockerfile"
protected "bin/setup"
protected "scripts/verify"
protected "plans/add-health-check.md"
not_protected "plans/other.md"
not_protected "CLAUDE.md"
not_protected "jig/config"
not_protected "app/.jig/config"
not_protected "bin/setup.d/db"
not_protected "scripts/verify-fast"

jig_parse_profile cfg <<<"$valid
protect CLAUDE.md
protect */CLAUDE.md
protect .claude/*
protect deploy/*
protect infra/Dockerfile
protect config/secrets/*
protect *.lock"

protected "CLAUDE.md"
protected "services/api/CLAUDE.md"
protected ".claude/settings.json"
protected "deploy/production.yml"
protected "deploy/k8s/base/app.yml"
protected "infra/Dockerfile"
protected "config/secrets/test.key"
protected "web/yarn.lock"
not_protected "src/app/models/user.rb"
not_protected "deploy"
not_protected "deployment/notes.md"
not_protected "infra/Dockerfile.dev"
not_protected "CLAUDE.mdx"
not_protected "docs/CLAUDE.md.bak"
not_protected "config/secrets.yml"
not_protected "web/.claude/settings.json"
not_protected "yarn.lock.bak"

jig_parse_profile cfg <<<"$valid
protect *"

not_protected "JIG_BLOCKED.md"
protected "docs/JIG_BLOCKED.md"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/jig-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
work="$tmp/work"
target="$tmp/target"

w() {
  git -C "$work" "$@"
}

new_origin() {
  rm -rf "$tmp/origin.git" "$work" "$target"
  git init -q --bare -b main "$tmp/origin.git"
  git init -q -b main "$work"
  w remote add origin "$tmp/origin.git"
}

write_profile() {
  (cd "$work" && rm -rf .jig bin scripts)
  mkdir -p "$work/.jig" "$work/bin" "$work/scripts"
  printf '%s\n' "$1" >"$work/.jig/config"
  : >"$work/.jig/compose.yml"
  : >"$work/bin/setup"
  : >"$work/scripts/verify"
}

publish() {
  w add -A
  w commit -q --allow-empty -m "$1"
  w push -q -f origin "HEAD:refs/heads/$1"
  last="$(w rev-parse HEAD)"
}

load_head() {
  repo_root="$work"
  jig_load_profile HEAD HEAD
}

resolve() {
  repo_root="$target"
  jig_resolve_base
}

resolved() {
  ( resolve >/dev/null && printf '%s %s %s' "$base" "$base_branch" "${profile_protect[*]-}" ) 2>&1
}

profile_of() {
  printf 'base %s\nsetup bin/setup\nverify scripts/verify\nprotect %s' "$1" "$2"
}

new_origin
write_profile "$(profile_of main 'deploy/*')"
publish main
equals "a complete profile loads" "$( (load_head && printf '%s %s %s' "$profile_base" "$profile_setup" "$profile_verify") 2>&1)" \
  "main bin/setup scripts/verify"
rm -r "$work/.jig"
w add -A && w commit -q -m "no profile"
exits_2 "no .jig/config" "HEAD has no file .jig/config" load_head
mkdir -p "$work/.jig/config"
: >"$work/.jig/config/base"
w add -A && w commit -q -m "config is a directory"
exits_2 ".jig/config is a directory" "HEAD has no file .jig/config" load_head
for f in .jig/compose.yml bin/setup scripts/verify; do
  write_profile "$(profile_of main 'deploy/*')"
  rm "$work/$f"
  w add -A && w commit -q -m "no $f"
  exits_2 "no $f" "HEAD has no file $f, which the profile needs" load_head
done
write_profile "$(profile_of main 'deploy/*')"
rm "$work/scripts/verify"
mkdir -p "$work/scripts/verify"
: >"$work/scripts/verify/run"
w add -A && w commit -q -m "verify is a directory"
exits_2 "verify is a directory" "HEAD has no file scripts/verify" load_head

new_origin
write_profile "$(profile_of main 'deploy/*')"
publish main
git clone -q "$tmp/origin.git" "$target"
equals "the default branch names itself" "$(resolved)" "$last main deploy/*"

new_origin
w commit -q --allow-empty -m "no profile"
publish main
git clone -q "$tmp/origin.git" "$target"
exits_2 "the default branch has no profile" "origin/main has no file .jig/config" resolve

new_origin
write_profile "$(profile_of develop 'deploy/*')"
publish main
git clone -q "$tmp/origin.git" "$target"
exits_2 "base names a branch missing on origin" "git fetch origin develop failed" resolve

new_origin
write_profile "$(profile_of develop 'deploy/*')"
publish main
write_profile "$(profile_of main 'deploy/*')"
publish develop
git clone -q "$tmp/origin.git" "$target"
exits_2 "base names a branch whose profile names another base" \
  "origin/main:.jig/config names base develop, but origin/develop:.jig/config names base main" resolve

new_origin
write_profile "$(profile_of develop 'deploy/*')"
publish main
write_profile "$(profile_of develop 'old/*')"
publish develop
git clone -q --single-branch -b main "$tmp/origin.git" "$target"
git -C "$target" fetch -q origin "refs/heads/develop:refs/remotes/origin/develop"
write_profile "$(profile_of develop 'new/*')"
publish develop
equals "a stale origin/develop is not used" "$(resolved)" "$last develop new/*"

new_origin
write_profile "$(profile_of develop 'deploy/*')"
publish main
write_profile "$(profile_of develop 'old/*')"
publish develop
w push -q origin "HEAD:refs/tags/develop"
write_profile "$(profile_of develop 'new/*')"
publish develop
git clone -q "$tmp/origin.git" "$target"
equals "a tag named like the base branch is not used" "$(resolved)" "$last develop new/*"

mkdir "$tmp/bin" "$tmp/links"
ln -s "$root/bin/jig" "$tmp/links/jig"
ln -s ../links/jig "$tmp/bin/jig"
checks=$(( checks + 1 ))
out="$("$tmp/bin/jig" 2>&1)"
status=$?
if [ "$status" != 2 ] || [[ $out != *"usage: jig run"* ]]; then
  fail "jig through a chain of symlinks: exit $status, expected 2 with the usage (output: $out)"
fi

echo "$checks checks, $failures failed"
[ "$failures" = 0 ]
