jig_min_free_re='^(0|[1-9][0-9]{0,5})$'

jig_use_builder() {
  if [ -n "${BUILDX_BUILDER:-}" ]; then
    jig_builder_text="$(printable "$BUILDX_BUILDER") from BUILDX_BUILDER"
    return 0
  fi
  BUILDX_BUILDER="$(docker context show 2>/dev/null)" && [ -n "$BUILDX_BUILDER" ] ||
    jig_fail "could not read the current Docker context (docker context show), whose builder jig builds with: set BUILDX_BUILDER to a builder"
  export BUILDX_BUILDER
  jig_builder_text="$(printable "$BUILDX_BUILDER"), the builder of the Docker context"
}

jig_free_kib() {
  local kib
  kib="$(df -Pk "$1" 2>/dev/null | LC_ALL=C awk 'NR == 2 { print $4 }')" && [[ $kib =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$kib"
}

jig_check_free() {
  local dir="$1" what="$2" min="$3" kib
  kib="$(jig_free_kib "$dir")" || jig_fail "could not read the free space of $what (df -Pk $dir)"
  [ "$kib" -lt $(( min * 1048576 )) ] || return 0
  jig_fail "$what has $(LC_ALL=C awk -v k="$kib" 'BEGIN { printf "%.1f", int(k * 10 / 1048576) / 10 }') GiB free, less than JIG_MIN_FREE_GB=$min. Free space before jig builds (docker system df shows what Docker holds, docker builder prune removes its build cache), or lower JIG_MIN_FREE_GB (0 turns the check off)"
}

jig_check_disk() {
  local min="${JIG_MIN_FREE_GB:-20}" dir root
  [[ $min =~ $jig_min_free_re ]] || jig_fail "JIG_MIN_FREE_GB must be a whole number of GiB (0 turns the check off)"
  [ "$min" != 0 ] || return 0
  dir="$jig_home"
  until [ -d "$dir" ]; do
    dir="$(dirname "$dir")"
  done
  jig_check_free "$dir" "the filesystem of JIG_HOME ($jig_home)" "$min"
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || jig_fail "Docker is not running"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  jig_check_free "$root" "the filesystem of Docker's data root ($(printable "$root"))" "$min"
}

jig_read_build_secrets() {
  local name value LC_ALL=C
  for name in ${profile_build_secrets[@]+"${profile_build_secrets[@]}"}; do
    value="${!name:-}"
    [ -n "$value" ] ||
      jig_fail "the profile's build-secret $name is not set: export $name before jig builds (jig hands its value only to docker compose, for the build)"
    [[ $value != *[[:cntrl:]]* ]] ||
      jig_fail "the value of the build secret $name has a line break or another control character, which jig cannot look for in its logs"
    jig_add_secret "$name" "$value"
  done
}
