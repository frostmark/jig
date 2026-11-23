jig_valid_branch() {
  local re='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
  [[ $1 =~ $re ]] && git check-ref-format "refs/heads/$1"
}

jig_valid_path() {
  local re='^[A-Za-z0-9._][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)*$'
  [[ $1 =~ $re ]] || return 1
  case "/$1/" in
    */./* | */../*) return 1 ;;
  esac
}

jig_valid_pattern() {
  local re='^[A-Za-z0-9._*-][A-Za-z0-9._/*-]*$'
  [[ $1 =~ $re ]]
}

jig_parse_profile() {
  local label="$1" line key value n=0 base_line=0 setup_line=0 verify_line=0 LC_ALL=C
  local skip_re='^[[:blank:]]*(#|$)' line_re='^([a-z]+)[[:blank:]]+([^[:blank:]]+)[[:blank:]]*$'
  profile_base="" profile_setup="" profile_verify=""
  profile_protect=()
  while IFS= read -r line || [ -n "$line" ]; do
    n=$(( n + 1 ))
    [[ $line =~ $skip_re ]] && continue
    [[ $line =~ $line_re ]] || jig_fail "$label:$n: expected a line \"<key> <value>\" with no spaces in the value"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      base)
        [ "$base_line" = 0 ] || jig_fail "$label:$n: base is already set on line $base_line"
        jig_valid_branch "$value" ||
          jig_fail "$label:$n: base must be a git branch name of latin letters, digits and . _ / -"
        base_line=$n
        profile_base="$value" ;;
      setup | verify)
        if [ "$key" = setup ]; then
          [ "$setup_line" = 0 ] || jig_fail "$label:$n: setup is already set on line $setup_line"
          setup_line=$n
        else
          [ "$verify_line" = 0 ] || jig_fail "$label:$n: verify is already set on line $verify_line"
          verify_line=$n
        fi
        jig_valid_path "$value" ||
          jig_fail "$label:$n: $key must be a path relative to the repo root: latin letters, digits and . _ - in parts joined by /, no . or .. parts, no leading -"
        if [ "$key" = setup ]; then profile_setup="$value"; else profile_verify="$value"; fi ;;
      protect)
        jig_valid_pattern "$value" ||
          jig_fail "$label:$n: protect must be a pattern of latin letters, digits, . _ - / and *, not starting with /"
        profile_protect+=("$value") ;;
      *)
        jig_fail "$label:$n: unknown key $key (known keys: base, setup, verify, protect)" ;;
    esac
  done
  [ "$base_line" != 0 ] || jig_fail "$label: missing the required key base"
  [ "$setup_line" != 0 ] || jig_fail "$label: missing the required key setup"
  [ "$verify_line" != 0 ] || jig_fail "$label: missing the required key verify"
}

jig_profile_target=/jig/profile

jig_overlay_git() {
  local root top
  root="$(cd "$overlay_root" && pwd -P)" || jig_fail "could not resolve the overlay root $overlay_root"
  overlay_git=none
  top="$(git -C "$overlay_root" rev-parse --show-toplevel 2>/dev/null)" && [ "$top" = "$root" ] || return 0
  overlay_git=outside
  top="$(git -C "$overlay_dir" rev-parse --show-toplevel 2>/dev/null)" && [ "$top" = "$root" ] || return 0
  overlay_git=inside
}

jig_list_overlay() {
  if [ "$overlay_git" = inside ]; then
    git -C "$overlay_dir" ls-files -z -c -o --exclude-standard
  else
    (cd "$overlay_dir" && LC_ALL=C find . -mindepth 1 ! -type d -print0)
  fi && printf '\0'
}

jig_find_overlay_profile() {
  local f listed=0
  jig_overlay_git
  while IFS= read -r -d '' f; do
    if [ -z "$f" ]; then
      listed=1
      continue
    fi
    f="${f#./}"
    case "$f" in
      rules.md | plugin | plugin/*) continue ;;
    esac
    [ -e "$overlay_dir/$f" ] || [ -L "$overlay_dir/$f" ] || continue
    jig_valid_path "$f" ||
      jig_fail "the overlay file $(printable "$overlay_dir/$f") must have a name of latin letters, digits and . _ - in parts joined by /"
    [ -f "$overlay_dir/$f" ] && [ -r "$overlay_dir/$f" ] ||
      jig_fail "the overlay file $overlay_dir/$f must be a readable regular file"
    overlay_files+=("$f")
    [ "$f" != config ] || overlay_config="$overlay_dir/config"
  done < <(jig_list_overlay)
  [ "$listed" = 1 ] || jig_fail "could not list the files of the overlay $overlay_dir"
}

jig_in_overlay() {
  local f
  for f in ${overlay_files[@]+"${overlay_files[@]}"}; do
    [ "$f" != "$1" ] || return 0
  done
  return 1
}

jig_profile_has() {
  local rev="$1" f="$2"
  case "$f" in
    .jig/*) ! jig_in_overlay "${f#.jig/}" || return 0 ;;
  esac
  [ "$(git -C "$repo_root" cat-file -t "$rev:$f" 2>/dev/null)" = blob ]
}

jig_load_profile() {
  local rev="$1" label="$2" text f r
  profile_repo_files=()
  if [ "$(git -C "$repo_root" cat-file -t "$rev:.jig" 2>/dev/null)" = tree ]; then
    while IFS= read -r -d '' f; do
      profile_repo_files+=("$f")
    done < <(git -C "$repo_root" ls-tree -r -z --name-only "$rev:.jig")
  fi
  for f in ${overlay_files[@]+"${overlay_files[@]}"}; do
    for r in ${profile_repo_files[@]+"${profile_repo_files[@]}"}; do
      [[ $f != "$r"/* && $r != "$f"/* ]] ||
        jig_fail "the overlay file $overlay_dir/$f and $label:.jig/$(printable "$r") cannot both be in the profile: one of them is a directory of the other"
    done
  done
  if [ -n "$overlay_config" ]; then
    jig_parse_profile "$overlay_config" <"$overlay_config"
  else
    [ "$(git -C "$repo_root" cat-file -t "$rev:.jig/config" 2>/dev/null)" = blob ] ||
      jig_fail "$label has no file .jig/config and the overlay $overlay_dir has no config: $repo_root has no jig profile"
    text="$(git -C "$repo_root" show "$rev:.jig/config")" || jig_fail "could not read $label:.jig/config"
    jig_parse_profile "$label:.jig/config" <<<"$text"
  fi
  for f in .jig/compose.yml "$profile_setup" "$profile_verify"; do
    jig_profile_has "$rev" "$f" && continue
    case "$f" in
      .jig/*) jig_fail "the profile needs $f, but neither $label nor the overlay $overlay_dir has it" ;;
      *) jig_fail "$label has no file $f, which the profile needs" ;;
    esac
  done
}

jig_profile_command() {
  case "$1" in
    .jig/*) printf '%s/%s' "$jig_profile_target" "${1#.jig/}" ;;
    *) printf './%s' "$1" ;;
  esac
}

jig_write_profile_compose() {
  {
    echo "services:"
    echo "  app:"
    echo "    volumes:"
    echo "      - type: bind"
    echo "        source: \${JIG_PROFILE_DIR:?jig sets JIG_PROFILE_DIR}"
    echo "        target: $jig_profile_target"
    echo "        read_only: true"
  } >"$1"
}

jig_extract_profile() {
  local rev="$1" dir="$2" f
  local profile="$dir/profile/.jig"
  mkdir "$dir/profile" "$profile" || return 1
  if [ "${#profile_repo_files[@]}" -gt 0 ]; then
    git -C "$repo_root" archive --format=tar "$rev:.jig" | tar -x -f - -C "$profile" || return 1
  fi
  for f in ${overlay_files[@]+"${overlay_files[@]}"}; do
    mkdir -p "$(dirname "$profile/$f")" && rm -f "$profile/$f" && cp "$overlay_dir/$f" "$profile/$f" || return 1
  done
  jig_write_profile_compose "$dir/compose.profile.yml" || return 1
  export JIG_PROFILE_DIR="$profile"
  jig_compose_files=(-f "$profile/compose.yml" -f "$dir/compose.profile.yml")
}

jig_overlay_version() {
  local changes
  overlay_commit=""
  overlay_changes=""
  [ -d "$overlay_dir" ] || return 0
  case "$overlay_git" in
    none) overlay_changes=unrecorded; return 0 ;;
    outside) overlay_changes=outside; return 0 ;;
  esac
  if ! overlay_commit="$(git -C "$overlay_root" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"; then
    overlay_commit=""
    overlay_changes=unrecorded
  elif ! changes="$(git -C "$overlay_dir" status --porcelain --untracked-files=all -- . 2>/dev/null)"; then
    overlay_changes=unknown
  elif [ -n "$changes" ]; then
    overlay_changes=uncommitted
  fi
}

jig_overlay_warnings() {
  case "$overlay_changes" in
    unrecorded) echo "JIG_PROFILES is not a git repository with a commit, so the PR cannot name the overlay's version" ;;
    outside) echo "the overlay $gh_owner/$gh_name is outside the git repository JIG_PROFILES, so the PR cannot name its version" ;;
    unknown) echo "could not check the overlay $gh_owner/$gh_name for uncommitted changes (git status failed)" ;;
    uncommitted) echo "the overlay has uncommitted changes in $gh_owner/$gh_name, and this run uses them" ;;
  esac
}

jig_profile_sources() {
  local overlay="$1" f
  [ -z "$overlay_commit" ] || echo "overlay commit: $overlay_commit"
  {
    for f in ${profile_repo_files[@]+"${profile_repo_files[@]}"}; do
      jig_in_overlay "$f" || echo "profile .jig/$(printable "$f"): repository"
    done
    for f in ${overlay_files[@]+"${overlay_files[@]}"}; do
      echo "profile .jig/$f: overlay $overlay/$f"
    done
  } | LC_ALL=C sort
}

jig_profile_warnings() {
  local f
  jig_overlay_warnings
  for f in ${profile_repo_files[@]+"${profile_repo_files[@]}"}; do
    ! jig_in_overlay "$f" || echo "the overlay's $f replaces the repository's .jig/$f"
  done
}

jig_profile_report() {
  jig_overlay_version
  jig_say jig_profile_sources "$overlay_dir"
  jig_warn jig_profile_warnings
  jig_profile_md="## Profile

\`\`\`
$(jig_profile_sources "\$JIG_PROFILES/$gh_owner/$gh_name")
$jig_warnings\`\`\`
"
}

jig_fetch_branch() {
  git -C "$repo_root" fetch --quiet --no-tags origin "+refs/heads/$1:refs/remotes/origin/$1" ||
    jig_fail "git fetch origin $1 failed"
  fetched_rev="$(git -C "$repo_root" rev-parse --verify --quiet "refs/remotes/origin/$1^{commit}")" ||
    jig_fail "git fetch origin $1 did not update origin/$1"
}

jig_resolve_base() {
  local origin_head default_branch named_base fetched_rev
  if [ -n "$overlay_config" ]; then
    jig_parse_profile "$overlay_config" <"$overlay_config"
    named_base="$profile_base"
  else
    origin_head="$(git -C "$repo_root" ls-remote --symref origin HEAD)" ||
      jig_fail "git ls-remote --symref origin HEAD failed"
    default_branch="$(printf '%s\n' "$origin_head" | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' | sed -n 1p)"
    [ -n "$default_branch" ] && jig_valid_branch "$default_branch" ||
      jig_fail "could not find the default branch of origin (git ls-remote --symref origin HEAD)"
    jig_fetch_branch "$default_branch"
    jig_load_profile "$fetched_rev" "origin/$default_branch"
    named_base="$profile_base"
  fi
  if [ -n "$overlay_config" ] || [ "$named_base" != "$default_branch" ]; then
    jig_fetch_branch "$named_base"
    jig_load_profile "$fetched_rev" "origin/$named_base"
    [ "$profile_base" = "$named_base" ] ||
      jig_fail "origin/$default_branch:.jig/config names base $named_base, but origin/$named_base:.jig/config names base $profile_base"
  fi
  base="$fetched_rev"
  base_branch="$profile_base"
}

jig_protected_patterns() {
  protected_patterns=(".jig/*" "$profile_setup" "$profile_verify" "plans/$slug.md" ${profile_protect[@]+"${profile_protect[@]}"})
}

jig_protected() {
  local p
  [ "$1" != JIG_BLOCKED.md ] || return 1
  jig_protected_patterns
  for p in "${protected_patterns[@]}"; do
    [[ $1 == $p ]] && return 0
  done
  return 1
}
