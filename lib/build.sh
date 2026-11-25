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
