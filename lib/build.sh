jig_min_free_re='^(0|[1-9][0-9]{0,5})$'
jig_build_services=()
jig_build_values=()
jig_compose_problem=""

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
    jig_build_values+=("$value")
    unset "$name"
  done
}

jig_with_build_secrets() (
  local i
  for i in ${profile_build_secrets[@]+"${!profile_build_secrets[@]}"}; do
    export "${profile_build_secrets[i]}=${jig_build_values[i]}"
  done
  "$@"
)

jig_build_secret_marker() {
  printf 'jig_build_secret_marker_%s_end' "$1"
}

jig_config_forms() {
  local value
  for value in "$1" "${1//\$/\$\$}"; do
    printf '%s\n' "$value"
    printf '%s\n' "$value" | LC_ALL=C sed -e 's/[\\"]/\\&/g' -e p -e 's/&/\\u0026/g' -e 's/</\\u003c/g' -e 's/>/\\u003e/g'
  done
}

jig_config_has_value() {
  printf '%s\n' "$1" | LC_ALL=C grep -a -F -f <(jig_config_forms "$2") >/dev/null
}

jig_is_build_secret() {
  local name
  for name in ${profile_build_secrets[@]+"${profile_build_secrets[@]}"}; do
    [ "$name" != "$1" ] || return 0
  done
  return 1
}

jig_compose_facts_awk='/^  "[^"]+": \{$/ { block = $0; sub(/^  "/, "", block); sub(/": \{$/, "", block); if (block == "services") found = 1; next }
/^  }/ { block = ""; next }
block == "secrets" || block == "configs" {
  if ($0 ~ /^    "[A-Za-z0-9._-]+": \{$/) { key = $0; sub(/^    "/, "", key); sub(/": \{$/, "", key) }
  else if ($0 ~ /^      "environment": "[^"\\]+",?$/) { name = $0; sub(/^      "environment": "/, "", name); sub(/",?$/, "", name); source[block, key] = name }
  next
}
block != "services" { next }
/^    "[A-Za-z0-9._-]+": \{$/ { svc = $0; sub(/^    "/, "", svc); sub(/": \{$/, "", svc); env = 0; list = ""; print "service " svc; next }
/^    [^ }]/ { bad = 1; next }
/^      "build": \{/ { print "build " svc; next }
$0 == "      \"environment\": {" { env = 1; next }
env && /^      }/ { env = 0; next }
env && /^        "[^"\\]+": / { key = $0; sub(/^        "/, "", key); sub(/": .*$/, "", key); print "env " svc " " key; next }
$0 == "      \"secrets\": [" || $0 == "      \"configs\": [" { list = $0; sub(/^      "/, "", list); sub(/": \[$/, "", list); next }
list && /^      ]/ { list = ""; next }
list && /^          "source": "[A-Za-z0-9._-]+",?$/ { key = $0; sub(/^          "source": "/, "", key); sub(/",?$/, "", key); uses[++n] = list " " svc " " key }
END {
  if (!found || bad) exit 1
  for (i = 1; i <= n; i++) {
    split(uses[i], u, " ")
    if ((u[1], u[3]) in source) print "runtime " u[2] " " u[1] " " u[3] " " source[u[1], u[3]]
  }
}'

jig_write_build_compose() {
  local service
  {
    echo "services:"
    for service in "${jig_build_services[@]}"; do
      echo "  \"$service\":"
      echo "    build:"
      echo "      labels:"
      echo "        jig.repo: \"$gh_repo\""
    done
  } >"$1"
}

jig_check_compose() {
  local dir="$1" config facts kind service name source variable status i app=0
  jig_build_services=()
  jig_compose_problem=""
  config="$(
    for name in ${profile_build_secrets[@]+"${profile_build_secrets[@]}"}; do
      export "$name=$(jig_build_secret_marker "$name")"
    done
    jig_compose config --format json
  )" || {
    jig_compose_problem="docker compose config failed on the profile's compose files and jig's"
    return 1
  }
  facts="$(printf '%s\n' "$config" | LC_ALL=C awk "$jig_compose_facts_awk")" || {
    jig_compose_problem="could not read the services from docker compose config --format json"
    return 1
  }
  while IFS=' ' read -r kind service name source variable; do
    case "$kind" in
      service) [ "$service" != app ] || app=1 ;;
      build) jig_build_services+=("$service") ;;
      env)
        if jig_is_build_secret "$name"; then
          jig_compose_problem="the build secret $name is in the environment of the service $service (docker compose config): jig never passes a build secret into a container. Remove it from the service's environment and env_file; the build gets it from a top-level secret with environment: $name"
          return 1
        fi ;;
      runtime)
        if jig_is_build_secret "$variable"; then
          jig_compose_problem="the build secret $variable reaches the service $service as its runtime ${name%s} $source (the top-level ${name%s} $source takes environment: $variable): jig never passes a build secret into a container. Remove $source from the service's $name; the build gets it under build: secrets:"
          return 1
        fi ;;
    esac
  done <<<"$facts"
  [ "$app" = 1 ] || {
    jig_compose_problem="docker compose config shows no service app"
    return 1
  }
  for name in ${profile_build_secrets[@]+"${profile_build_secrets[@]}"}; do
    case "$config" in
      *"$(jig_build_secret_marker "$name")"*)
        jig_compose_problem="the value of the build secret $name reaches the compose project (docker compose config resolves \${$name} in it: in an environment value, a build arg, a label or elsewhere): jig never passes a build secret into a container. The build gets it from a top-level secret with environment: $name"
        return 1 ;;
    esac
  done
  for i in ${profile_build_secrets[@]+"${!profile_build_secrets[@]}"}; do
    status=0
    jig_config_has_value "$config" "${jig_build_values[i]}" || status=$?
    case "$status" in
      0)
        jig_compose_problem="the value of the build secret ${profile_build_secrets[i]} is in the compose project that docker compose config resolves (an env_file or another variable holds it): jig never passes a build secret into a container. Remove the value from there; the build gets it from a top-level secret with environment: ${profile_build_secrets[i]}"
        return 1 ;;
      1) ;;
      *)
        jig_compose_problem="could not search docker compose config for the build secrets' values"
        return 1 ;;
    esac
  done
  [ "${#jig_build_services[@]}" -gt 0 ] || return 0
  jig_write_build_compose "$dir/compose.build.yml" || {
    jig_compose_problem="could not write $dir/compose.build.yml"
    return 1
  }
  jig_compose_files+=(-f "$dir/compose.build.yml")
}

jig_prune_images() {
  local log="$1" out
  if ! out="$(docker image prune -f --filter "label=jig.repo=$gh_repo" 2>&1)"; then
    printf '%s\n' "$out" >>"$log"
    echo "$jig_name: WARNING: could not remove the dangling images of $gh_repo (docker image prune): see $log" >&2
    return 0
  fi
  printf '%s\n' "$out" >>"$log"
  case "$out" in
    *"Deleted Images:"*)
      echo "$jig_name: removed the dangling images labelled jig.repo=$gh_repo ($(printf '%s\n' "$out" | sed -n 's/^Total reclaimed space: /reclaimed /p'))" ;;
  esac
}

jig_build() {
  local log="$1" status=0
  [ "${#jig_build_services[@]}" -gt 0 ] || return 0
  echo "$jig_name: building ${jig_build_services[*]} with $jig_builder_text (log: $log)"
  jig_with_build_secrets jig_compose build 2>&1 | jig_redact_stream | tee "$log" || status=$?
  [ "$status" = 0 ] || return "$status"
  jig_prune_images "$log"
}
