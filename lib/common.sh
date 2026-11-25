jig_interrupted=0
list_max=50

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

jig_github_forms="https://github.com/<owner>/<repo>, git@github.com:<owner>/<repo> or ssh://git@github.com/<owner>/<repo>, with or without .git"

jig_github_repo() {
  local url="$1" host owner name part LC_ALL=C
  local url_re='^(https?|ssh|git)://([^@/]+@)?([A-Za-z0-9.-]+)(:[0-9]+)?/([^/]+)/([^/]+)$'
  local scp_re='^([^@/:]+@)?([A-Za-z0-9.-]+):/?([^/]+)/([^/]+)$'
  local part_re='^[A-Za-z0-9._-]+$'
  url="${url%/}"
  if [[ $url =~ $url_re ]]; then
    host="${BASH_REMATCH[3]}" owner="${BASH_REMATCH[5]}" name="${BASH_REMATCH[6]}"
  elif [[ $url =~ $scp_re ]]; then
    host="${BASH_REMATCH[2]}" owner="${BASH_REMATCH[3]}" name="${BASH_REMATCH[4]}"
  else
    return 1
  fi
  [ "$(printf '%s' "$host" | tr 'A-Z' 'a-z')" = github.com ] || return 1
  name="${name%.git}"
  for part in "$owner" "$name"; do
    [[ $part =~ $part_re ]] && [ "$part" != . ] && [ "$part" != .. ] || return 1
  done
  printf '%s/%s' "$owner" "$name"
}

jig_repo_identity() {
  origin_url="$(git -C "$repo_root" remote get-url origin)" || jig_fail "$repo_root has no remote origin"
  gh_repo="$(jig_github_repo "$origin_url")" ||
    jig_fail "the origin remote of $repo_root is not a GitHub repository URL; jig takes <owner>/<repo> from $jig_github_forms"
  gh_owner="${gh_repo%%/*}"
  gh_name="${gh_repo#*/}"
  docker_repo="$(jig_docker_name "$gh_owner")_$(jig_docker_name "$gh_name")"
}

jig_check_gh() {
  local named
  gh auth status --hostname github.com >/dev/null 2>&1 ||
    jig_fail "gh is not logged in to github.com: run gh auth login (deliver pr opens the PR with gh; deliver branch needs no gh)"
  named="$(gh repo view "$origin_url" --json nameWithOwner --jq .nameWithOwner)" ||
    jig_fail "gh repo view failed for the origin remote of $repo_root"
  [ "$named" = "$gh_repo" ] ||
    jig_fail "the origin URL of $repo_root names the repository $gh_repo, but GitHub names it $(printable "$named"): set origin to GitHub's spelling (git -C $repo_root remote set-url origin <URL>), which also names the overlay and the run directories"
}

jig_clone() {
  local rev="$1" dest="$2"
  git clone --quiet --no-local -c advice.detachedHead=false --revision="$rev" "$repo_root" "$dest"
}

jig_compose() {
  docker compose -p "$jig_project" "${jig_compose_files[@]}" "$@"
}

jig_use_workspace() {
  export JIG_WORKSPACE="$1" JIG_BASE="$2" JIG_UID="$(id -u)" JIG_GID="$(id -g)"
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
