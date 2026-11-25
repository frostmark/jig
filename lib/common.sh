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

jig_secret_names=()
jig_secret_values=()

jig_add_secret() {
  local escaped
  jig_secret_names+=("$1")
  jig_secret_values+=("$2")
  escaped="$(printf '%s' "$2" | LC_ALL=C sed 's/[\\"]/\\&/g')"
  [ "$escaped" = "$2" ] || {
    jig_secret_names+=("$1")
    jig_secret_values+=("$escaped")
  }
}

jig_contains_secret() {
  [ "${#jig_secret_values[@]}" -gt 0 ] || return 1
  LC_ALL=C grep -a -F -q -f <(printf '%s\n' "${jig_secret_values[@]}") -- "$1"
}

jig_secrets_in() {
  local i
  for i in ${jig_secret_values[@]+"${!jig_secret_values[@]}"}; do
    if LC_ALL=C grep -a -F -q -e "${jig_secret_values[i]}" -- "$@" 2>/dev/null; then
      printf '%s\n' "${jig_secret_names[i]}"
    fi
  done
  return 0
}

jig_values_of() {
  local listed=$'\n'"$1"$'\n' seen=$'\n' name joined="" names=()
  for name in ${jig_secret_names[@]+"${jig_secret_names[@]}"}; do
    case "$seen" in
      *$'\n'"$name"$'\n'*) continue ;;
    esac
    seen="$seen$name"$'\n'
    case "$listed" in
      *$'\n'"$name"$'\n'*) names+=("$name") ;;
    esac
  done
  case "${#names[@]}" in
    0) printf 'a secret value' ;;
    1) printf 'the %s value' "${names[0]}" ;;
    *)
      for name in "${names[@]:0:${#names[@]}-1}"; do
        joined="$joined, $name"
      done
      printf 'the %s and %s values' "${joined#, }" "${names[${#names[@]}-1]}" ;;
  esac
}

jig_values_found() {
  local phrase
  phrase="$(jig_values_of "$1")"
  case "$phrase" in
    *values) printf '%s were' "$phrase" ;;
    *) printf '%s was' "$phrase" ;;
  esac
}

jig_all_secrets() {
  printf '%s\n' ${jig_secret_names[@]+"${jig_secret_names[@]}"}
}

jig_redact_awk='NR == FNR { if ($0 != "") v[++n] = $0; next }
!sorted {
  for (i = 2; i <= n; i++)
    for (j = i; j > 1 && length(v[j]) > length(v[j - 1]); j--) { t = v[j]; v[j] = v[j - 1]; v[j - 1] = t }
  sorted = 1
}
{
  line = $0
  for (i = 1; i <= n; i++) {
    out = ""
    while ((p = index(line, v[i])) > 0) {
      out = out substr(line, 1, p - 1) "[REDACTED]"
      line = substr(line, p + length(v[i]))
    }
    line = out line
  }
  print line
}'

jig_redact_file() {
  LC_ALL=C awk "$jig_redact_awk" <(printf '%s\n' "${jig_secret_values[@]}") "$1" >"$1.redacted" && mv -f "$1.redacted" "$1"
}

jig_redact_text() {
  local text="$1" value LC_ALL=C
  for value in ${jig_secret_values[@]+"${jig_secret_values[@]}"}; do
    text="${text//"$value"/[REDACTED]}"
  done
  printf '%s' "$text"
}

jig_redact_stream() {
  local line value LC_ALL=C
  while IFS= read -r line || [ -n "$line" ]; do
    for value in ${jig_secret_values[@]+"${jig_secret_values[@]}"}; do
      line="${line//"$value"/[REDACTED]}"
    done
    printf '%s\n' "$line"
  done
}

jig_redact_files() {
  local dir="$1" f status redacted="" removed="" redacted_names="" removed_names="" names
  shift
  [ "${#jig_secret_values[@]}" -gt 0 ] || return 0
  for f in "$@"; do
    status=0
    jig_contains_secret "$dir/$f" || status=$?
    case "$status" in
      0)
        names="$(jig_secrets_in "$dir/$f")"
        if jig_redact_file "$dir/$f" && { jig_contains_secret "$dir/$f"; [ "$?" = 1 ]; }; then
          redacted="$redacted $f"
          redacted_names="$redacted_names$names"$'\n'
        else
          rm -f "$dir/$f" "$dir/$f.redacted"
          removed="$removed $f"
          removed_names="$removed_names$names"$'\n'
        fi ;;
      1) ;;
      *) echo "$jig_name: WARNING: could not scan $dir/$f for $(jig_values_of "$(jig_all_secrets)")" >&2 ;;
    esac
  done
  [ -z "$redacted" ] ||
    echo "$jig_name: WARNING: $(jig_values_found "$redacted_names") found in$redacted and replaced with [REDACTED] in $dir" >&2
  [ -z "$removed" ] ||
    echo "$jig_name: WARNING: $(jig_values_found "$removed_names") found in$removed, which could not be redacted and were removed from $dir" >&2
}

# The clone holds a .git that ran the repository's scripts, and in jig run the agent: its hooks and config would run in any git-aware prompt or editor on the host.
jig_remove_clone() {
  [ -e "$1" ] || return 0
  chmod -R u+rwX "$1" 2>/dev/null || true
  rm -rf "$1" ||
    echo "$jig_name: WARNING: could not remove $1; delete it without running git or opening it in an editor" >&2
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
    [[ $part =~ $part_re ]] || return 1
    case "$part" in
      . | .. | .[Gg][Ii][Tt]) return 1 ;;
    esac
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
