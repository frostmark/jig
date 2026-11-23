jig_interrupted=0

jig_fail() {
  echo "$jig_name: $*" >&2
  exit 2
}

jig_check_host() {
  if [ "$(id -u)" = 0 ]; then
    jig_fail "run it as a regular user, not root"
  fi
  case "$(git clone -h 2>&1 || true)" in
    *"revision <rev>"*) ;;
    *) jig_fail "needs git 2.49 or newer (git clone --revision)" ;;
  esac
}

jig_set_home() {
  jig_home="${JIG_HOME:-$HOME/.jig}"
  case "$jig_home" in
    /*) ;;
    *) jig_fail "JIG_HOME must be an absolute path" ;;
  esac
}

printable() {
  local s="$1" LC_ALL=C
  s="${s//[^[:print:]]/?}"
  printf '%s' "${s//\`/?}"
}

jig_say() {
  local line
  while IFS= read -r line; do
    echo "$jig_name: $line"
  done < <("$@")
}

jig_warn() {
  local line
  jig_warnings=""
  while IFS= read -r line; do
    line="WARNING: $(printable "$line")"
    echo "$jig_name: $line" >&2
    jig_warnings="$jig_warnings$line
"
  done < <("$@")
}

jig_docker_name() {
  printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9-' '-'
}

jig_repo_identity() {
  local name_re='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' part origin_url
  origin_url="$(git -C "$repo_root" remote get-url origin)" || jig_fail "$repo_root has no remote origin"
  gh_repo="$(gh repo view "$origin_url" --json nameWithOwner --jq .nameWithOwner)" ||
    jig_fail "gh repo view failed for the origin remote of $repo_root: jig needs gh logged in to github.com and origin on GitHub"
  [[ $gh_repo =~ $name_re ]] || jig_fail "gh repo view gave an unexpected repository name"
  gh_owner="${gh_repo%%/*}"
  gh_name="${gh_repo#*/}"
  for part in "$gh_owner" "$gh_name"; do
    [ "$part" != . ] && [ "$part" != .. ] || jig_fail "gh repo view gave an unexpected repository name"
  done
  docker_repo="$(jig_docker_name "$gh_owner")_$(jig_docker_name "$gh_name")"
}

jig_clone() {
  local rev="$1" dest="$2"
  git clone --quiet --no-local -c advice.detachedHead=false --revision="$rev" "$repo_root" "$dest"
}

jig_extract_profile() {
  local rev="$1" dest="$2"
  mkdir "$dest" && git -C "$repo_root" archive --format=tar "$rev" .jig | tar -x -f - -C "$dest" || return 1
  jig_compose_files=(-f "$dest/.jig/compose.yml")
}

jig_compose() {
  docker compose -p "$jig_project" "${jig_compose_files[@]}" "$@"
}

jig_use_workspace() {
  export JIG_WORKSPACE="$1" JIG_UID="$(id -u)" JIG_GID="$(id -g)"
}

# docker compose turns SIGINT back on even when the caller ignores it, so down runs in its own
# process group, out of reach of a Ctrl-C on the terminal. A Ctrl-C meanwhile sets jig_interrupted=1.
# Inside an EXIT trap bash interrupts wait without running the INT handler, so the loop asks the process itself.
jig_down() {
  local saved pid status again
  saved="$(trap -p INT TERM HUP)"
  trap 'jig_interrupted=1' INT TERM HUP
  set -m
  jig_compose down -v --remove-orphans </dev/null &
  pid=$!
  set +m
  while :; do
    status=0
    wait "$pid" || status=$?
    [ "$status" -gt 128 ] && kill -0 "$pid" 2>/dev/null || break
  done
  if [ "$status" -gt 128 ]; then
    again=0
    wait "$pid" 2>/dev/null || again=$?
    [ "$again" = 127 ] || status=$again
  fi
  trap - INT TERM HUP
  eval "$saved"
  return "$status"
}
