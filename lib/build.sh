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
