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

jig_parse_profile cfg <<<"base main
setup bin/setup
verify scripts/verify"

protected ".jig/config"
protected ".jig/docker/Dockerfile"
protected "bin/setup"
protected "scripts/verify"
not_protected "plans/add-health-check.md"
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
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$tmp"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
work="$tmp/work"
target="$tmp/target"
gh_owner=acme
gh_name=shop
jig_home="$tmp/home"
export JIG_PROFILES="$tmp/home/profiles"
overlay="$JIG_PROFILES/acme/shop"
jig_set_profiles
jig_find_overlay

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
write_profile "$(profile_of main 'deploy/*')"
rm "$work/.jig/compose.yml"
w add -A && w commit -q -m "no compose.yml"
exits_2 "no .jig/compose.yml" "the profile needs .jig/compose.yml, but neither HEAD nor the overlay $overlay has it" load_head
for f in bin/setup scripts/verify; do
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

overlay_listed() {
  (jig_find_overlay && printf '%s\n' ${overlay_files[@]+"${overlay_files[@]}"} | LC_ALL=C sort | tr '\n' ' ' &&
    printf '|%s' "$overlay_config") 2>&1
}

mkdir -p "$overlay/docker" "$overlay/empty" "$tmp/plugin/skills/review"
for f in config compose.yml docker/Dockerfile .env rules.md; do
  printf 'overlay %s\n' "$f" >"$overlay/$f"
done
: >"$tmp/plugin/skills/review/SKILL.md"
ln -s "$tmp/plugin" "$overlay/plugin"
printf 'shared setup\n' >"$tmp/shared-setup"
ln -s "$tmp/shared-setup" "$overlay/setup"
equals "without git, the overlay's profile files are all its files but rules.md and plugin, file links included" \
  "$(overlay_listed)" ".env compose.yml config docker/Dockerfile setup |$overlay/config"
: >"$overlay/x"
mkdir "$overlay/x
."
: >"$overlay/x
./config"
exits_2 "an overlay file name with a newline" "the overlay file $overlay/x?./config must have a name of latin letters" jig_find_overlay
rm -r "$overlay/x" "$overlay/x
."
mkdir "$tmp/shared-dir"
: >"$tmp/shared-dir/entry.sh"
ln -s "$tmp/shared-dir" "$overlay/docker/shared"
exits_2 "an overlay link to a directory" "the overlay file $overlay/docker/shared must be a readable regular file" jig_find_overlay
rm "$overlay/docker/shared"
mkdir "$overlay/locked"
: >"$overlay/locked/entry.sh"
chmod 000 "$overlay/locked"
exits_2 "an overlay directory that cannot be listed" "could not list the files of the overlay $overlay" jig_find_overlay
chmod 755 "$overlay/locked"
rm -r "$overlay/locked" "$overlay/plugin"
rm "$overlay/config"
equals "an overlay without config" "$(overlay_listed)" ".env compose.yml docker/Dockerfile setup |"
ln -s "$tmp/missing" "$overlay/docker/entry.sh"
exits_2 "an overlay file is a dangling link" "the overlay file $overlay/docker/entry.sh must be a readable regular file" jig_find_overlay
rm "$overlay/docker/entry.sh"
printf 'x\n' >"$overlay/docker/entry.sh"
chmod 000 "$overlay/docker/entry.sh"
exits_2 "an overlay file is not readable" "the overlay file $overlay/docker/entry.sh must be a readable regular file" jig_find_overlay
rm -f "$overlay/docker/entry.sh"
mkfifo "$overlay/docker/entry.sh"
exits_2 "an overlay file is a fifo" "the overlay file $overlay/docker/entry.sh must be a readable regular file" jig_find_overlay
rm "$overlay/docker/entry.sh"
: >"$overlay/docker/my notes.txt"
exits_2 "an overlay file name with a space" "the overlay file $overlay/docker/my notes.txt must have a name of latin letters" jig_find_overlay
rm -r "$JIG_PROFILES"

git init -q -b main "$JIG_PROFILES"
printf '.env\n*.swp\n' >"$JIG_PROFILES/.gitignore"
mkdir -p "$overlay/docker" "$overlay/plugin/skills/review"
for f in config compose.yml docker/Dockerfile docker/old.sh .env rules.md plugin/skills/review/SKILL.md; do
  printf 'overlay %s\n' "$f" >"$overlay/$f"
done
git -C "$JIG_PROFILES" add -A && git -C "$JIG_PROFILES" commit -q -m overlay
rm "$overlay/docker/old.sh"
printf 'untracked setup\n' >"$overlay/setup"
printf 'swap\n' >"$overlay/.config.swp"
equals "in a git overlay, the profile files are the tracked and untracked files git does not ignore, deleted ones left out" \
  "$(overlay_listed)" "compose.yml config docker/Dockerfile setup |$overlay/config"
rm -rf "$JIG_PROFILES"

overlay_file() {
  mkdir -p "$(dirname "$overlay/$1")"
  printf '%s\n' "$2" >"$overlay/$1"
}

loaded() {
  (jig_find_overlay && load_head && printf '%s %s %s %s' "$profile_base" "$profile_setup" "$profile_verify" "${profile_protect[*]-}") 2>&1
}

new_origin
mkdir -p "$work/scripts"
: >"$work/scripts/verify"
publish main
overlay_file config "$(printf 'base main\nsetup .jig/setup\nverify scripts/verify\nprotect deploy/*')"
overlay_file compose.yml services:
overlay_file setup 'echo setup'
equals "the overlay supplies the whole profile of a repository without .jig/" "$(loaded)" "main .jig/setup scripts/verify deploy/*"
rm "$overlay/setup"
exits_2 "a .jig/ script that neither layer has" "the profile needs .jig/setup, but neither HEAD nor the overlay $overlay has it" loaded
overlay_file setup 'echo setup'
overlay_file config "$(printf 'base main\nsetup .jig/setup\nverify bin/verify')"
overlay_file bin/verify 'echo verify'
exits_2 "a repository path is not looked up in the overlay" "HEAD has no file bin/verify, which the profile needs" loaded
rm -r "$overlay/bin"
overlay_file config 'colour red'
exits_2 "an invalid overlay config names the overlay file" "$overlay/config:1: unknown key colour" loaded

write_profile 'colour red'
publish main
overlay_file config "$(printf 'base main\nsetup bin/setup\nverify scripts/verify\nprotect overlay/*')"
equals "the overlay config replaces the repository's, which is not read" "$(loaded)" "main bin/setup scripts/verify overlay/*"

mkdir -p "$work/.jig"
: >"$work/.jig/docker"
publish main
overlay_file docker/Dockerfile 'FROM scratch'
exits_2 "an overlay directory where the repository has a file" \
  "the overlay file $overlay/docker/Dockerfile and HEAD:.jig/docker cannot both be in the profile" loaded
rm -r "$overlay/docker" "$work/.jig/docker"
mkdir -p "$work/.jig/docker"
: >"$work/.jig/docker/Dockerfile"
publish main
overlay_file docker 'FROM scratch'
exits_2 "an overlay file where the repository has a directory" \
  "the overlay file $overlay/docker and HEAD:.jig/docker/Dockerfile cannot both be in the profile" loaded
rm -r "$JIG_PROFILES"

new_origin
w commit -q --allow-empty -m "no profile"
publish main
mkdir -p "$work/scripts"
: >"$work/scripts/verify"
publish develop
git clone -q "$tmp/origin.git" "$target"
w commit -q --allow-empty -m "develop moves on"
publish develop
overlay_file config "$(printf 'base develop\nsetup .jig/setup\nverify scripts/verify\nprotect overlay/*')"
overlay_file compose.yml services:
overlay_file setup 'echo setup'
equals "the overlay config's base is fetched fresh from origin; the default branch has no profile" \
  "$( (jig_find_overlay && resolved) 2>&1)" "$last develop overlay/*"
overlay_resolve() {
  jig_find_overlay && resolve
}
overlay_file config "$(printf 'base release\nsetup .jig/setup\nverify scripts/verify')"
exits_2 "the overlay config's base is missing on origin" "git fetch origin release failed" overlay_resolve
rm -r "$JIG_PROFILES"

equals "commands of the profile's scripts" \
  "$(jig_profile_command .jig/setup) $(jig_profile_command .jig/docker/setup) $(jig_profile_command bin/setup)" \
  "/jig/profile/setup /jig/profile/docker/setup ./bin/setup"

files_in() {
  (cd "$1" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
}

extracted() {
  rm -rf "$tmp/run"
  mkdir "$tmp/run"
  (jig_find_overlay && load_head && jig_extract_profile HEAD "$tmp/run" &&
    printf '%s|%s' "${jig_compose_files[*]}" "$JIG_PROFILE_DIR") 2>&1
}

new_origin
write_profile "$(profile_of main 'deploy/*')"
mkdir -p "$work/.jig/docker"
printf 'repo Dockerfile\n' >"$work/.jig/Dockerfile"
printf 'repo entry\n' >"$work/.jig/docker/entry.sh"
printf 'repo setup\n' >"$work/.jig/setup"
publish main
overlay_file Dockerfile 'overlay Dockerfile'
overlay_file setup 'overlay setup'
chmod +x "$overlay/setup"
overlay_file docker/extra.sh 'overlay extra'
ln -s "$tmp/shared-setup" "$overlay/docker/linked.sh"
overlay_file rules.md 'rules'
overlay_file plugin/skills/review/SKILL.md 'skill'
equals "the profile is the repository's .jig/ with the overlay's files over it" \
  "$(extracted)" "-f $tmp/run/profile/.jig/compose.yml -f $tmp/run/compose.profile.yml|$tmp/run/profile/.jig"
equals "the merged profile's files" "$(files_in "$tmp/run/profile/.jig")" \
  "./Dockerfile ./compose.yml ./config ./docker/entry.sh ./docker/extra.sh ./docker/linked.sh ./setup "
equals "an overlay file replaces the repository's" "$(cat "$tmp/run/profile/.jig/Dockerfile")" "overlay Dockerfile"
checks=$(( checks + 1 ))
[ -x "$tmp/run/profile/.jig/setup" ] || fail "an overlay script keeps its executable mode over a repository file without it"
rm -r "$JIG_PROFILES"

new_origin
mkdir -p "$work/scripts"
: >"$work/scripts/verify"
publish main
overlay_file config "$(printf 'base main\nsetup .jig/setup\nverify scripts/verify')"
overlay_file compose.yml services:
overlay_file setup 'echo setup'
extracted >/dev/null
equals "a repository without .jig/ gets the overlay's files only" "$(files_in "$tmp/run/profile/.jig")" \
  "./compose.yml ./config ./setup "
rm -r "$JIG_PROFILES"

reported() {
  (jig_find_overlay && load_head && jig_profile_report >"$tmp/out" 2>"$tmp/err" &&
    printf '%s\n--\n%s\n--\n%s' "$(cat "$tmp/out")" "$(cat "$tmp/err")" "$jig_profile_md") 2>&1
}

new_origin
write_profile "$(profile_of main 'deploy/*')"
mkdir -p "$work/.jig/x\`y"
: >"$work/.jig/x\`y/notes"
publish main
equals "the profile report without an overlay" "$(reported)" "jig: profile .jig/compose.yml: repository
jig: profile .jig/config: repository
jig: profile .jig/x?y/notes: repository
--

--
## Profile

\`\`\`
profile .jig/compose.yml: repository
profile .jig/config: repository
profile .jig/x?y/notes: repository
\`\`\`"

git init -q -b main "$JIG_PROFILES"
overlay_file config "$(profile_of main 'overlay/*')"
overlay_file Dockerfile 'FROM scratch'
overlay_file rules.md 'rules'
git -C "$JIG_PROFILES" add -A && git -C "$JIG_PROFILES" commit -q -m overlay
overlay_commit="$(git -C "$JIG_PROFILES" rev-parse HEAD)"
mkdir -p "$JIG_PROFILES/acme/other"
: >"$JIG_PROFILES/acme/other/config"
equals "the profile report with a committed overlay that shadows the repository's config" "$(reported)" "jig: overlay commit: $overlay_commit
jig: profile .jig/Dockerfile: overlay $overlay/Dockerfile
jig: profile .jig/compose.yml: repository
jig: profile .jig/config: overlay $overlay/config
jig: profile .jig/x?y/notes: repository
--
jig: WARNING: the overlay's config replaces the repository's .jig/config
--
## Profile

\`\`\`
overlay commit: $overlay_commit
profile .jig/Dockerfile: overlay \$JIG_PROFILES/acme/shop/Dockerfile
profile .jig/compose.yml: repository
profile .jig/config: overlay \$JIG_PROFILES/acme/shop/config
profile .jig/x?y/notes: repository
WARNING: the overlay's config replaces the repository's .jig/config
\`\`\`"

warned() {
  (jig_find_overlay && load_head && jig_profile_report >/dev/null 2>"$tmp/err" && cat "$tmp/err") 2>&1
}

overlay_file Dockerfile 'FROM debian'
equals "a changed overlay file" "$(warned)" "jig: WARNING: the overlay has uncommitted changes in acme/shop, and this run uses them
jig: WARNING: the overlay's config replaces the repository's .jig/config"
git -C "$JIG_PROFILES" checkout -q -- acme/shop/Dockerfile
overlay_file compose.yml 'services:'
equals "an untracked overlay file" "$(warned)" "jig: WARNING: the overlay has uncommitted changes in acme/shop, and this run uses them
jig: WARNING: the overlay's compose.yml replaces the repository's .jig/compose.yml
jig: WARNING: the overlay's config replaces the repository's .jig/config"
equals "the PR section caps its lists" \
  "$( (list_max=2 && jig_find_overlay && load_head && jig_profile_report >/dev/null 2>&1 && printf '%s' "$jig_profile_md") 2>&1)" \
  "## Profile

\`\`\`
overlay commit: $overlay_commit
profile .jig/Dockerfile: overlay \$JIG_PROFILES/acme/shop/Dockerfile
... and 3 more
WARNING: the overlay has uncommitted changes in acme/shop, and this run uses them
WARNING: the overlay's compose.yml replaces the repository's .jig/compose.yml
... and 1 more
\`\`\`"
rm "$overlay/compose.yml"
rm -rf "$JIG_PROFILES/.git"
equals "an overlay root that is not a git repository" "$(reported)" "jig: profile .jig/Dockerfile: overlay $overlay/Dockerfile
jig: profile .jig/compose.yml: repository
jig: profile .jig/config: overlay $overlay/config
jig: profile .jig/x?y/notes: repository
--
jig: WARNING: JIG_PROFILES is not a git repository with a commit, so the PR cannot name the overlay's version
jig: WARNING: the overlay's config replaces the repository's .jig/config
--
## Profile

\`\`\`
profile .jig/Dockerfile: overlay \$JIG_PROFILES/acme/shop/Dockerfile
profile .jig/compose.yml: repository
profile .jig/config: overlay \$JIG_PROFILES/acme/shop/config
profile .jig/x?y/notes: repository
WARNING: JIG_PROFILES is not a git repository with a commit, so the PR cannot name the overlay's version
WARNING: the overlay's config replaces the repository's .jig/config
\`\`\`"
git init -q -b main "$JIG_PROFILES"
equals "an overlay repository without a commit" "$(warned)" "jig: WARNING: JIG_PROFILES is not a git repository with a commit, so the PR cannot name the overlay's version
jig: WARNING: the overlay's config replaces the repository's .jig/config"
rm -rf "$JIG_PROFILES/.git"
git init -q -b main "$jig_home"
printf 'profiles/\n' >"$jig_home/.gitignore"
git -C "$jig_home" add .gitignore && git -C "$jig_home" commit -q -m dotfiles
equals "an overlay root inside another git repository" "$(warned)" "jig: WARNING: JIG_PROFILES is not a git repository with a commit, so the PR cannot name the overlay's version
jig: WARNING: the overlay's config replaces the repository's .jig/config"
rm -rf "$jig_home/.git" "$jig_home/.gitignore"

told() {
  (jig_find_overlay && load_head && jig_profile_report 2>&1) 2>&1
}

git init -q -b main "$JIG_PROFILES"
git -C "$JIG_PROFILES" commit -q --allow-empty -m empty
mv "$overlay" "$tmp/shop-overlay"
ln -s "$tmp/shop-overlay" "$overlay"
equals "an overlay directory outside the overlay repository has no overlay commit" "$(told)" "jig: profile .jig/Dockerfile: overlay $overlay/Dockerfile
jig: profile .jig/compose.yml: repository
jig: profile .jig/config: overlay $overlay/config
jig: profile .jig/x?y/notes: repository
jig: WARNING: the overlay acme/shop is outside the git repository JIG_PROFILES, so the PR cannot name its version
jig: WARNING: the overlay's config replaces the repository's .jig/config"
rm "$overlay"
mv "$tmp/shop-overlay" "$overlay"
git -C "$JIG_PROFILES" add -A && git -C "$JIG_PROFILES" commit -q -m overlay
tree="$(git -C "$JIG_PROFILES" rev-parse 'HEAD^{tree}')"
rm "$JIG_PROFILES/.git/objects/${tree:0:2}/${tree:2}"
equals "git status fails in the overlay" "$(warned)" "jig: WARNING: could not check the overlay acme/shop for uncommitted changes (git status failed)
jig: WARNING: the overlay's config replaces the repository's .jig/config"
rm -rf "$JIG_PROFILES"

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
