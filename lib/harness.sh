jig_rules_file="$engine_root/lib/rules.md"
jig_prompt_target=/jig/system-prompt.md

jig_protected_list() {
  local entry pattern covered listed=()
  for entry in ".jig/*" "$profile_setup" "$profile_verify" ${profile_protect[@]+"${profile_protect[@]}"}; do
    covered=0
    for pattern in ${listed[@]+"${listed[@]}"}; do
      if [[ $entry == $pattern ]]; then
        covered=1
        break
      fi
    done
    [ "$covered" = 1 ] && continue
    listed+=("$entry")
    printf '  - `%s`\n' "$entry"
  done
}

jig_engine_rules() {
  local text protected
  text="$(cat "$jig_rules_file")" || return 1
  protected="$(jig_protected_list)"
  text="${text//@VERIFY@/$profile_verify}"
  printf '%s\n' "${text//@PROTECTED@/$protected}"
}

jig_write_system_prompt() {
  jig_engine_rules >"$1"
}

jig_write_harness_compose() {
  {
    echo "services:"
    echo "  app:"
    echo "    volumes:"
    echo "      - type: bind"
    echo "        source: \${JIG_SYSTEM_PROMPT:?jig sets JIG_SYSTEM_PROMPT}"
    echo "        target: $jig_prompt_target"
    echo "        read_only: true"
  } >"$1"
}

jig_use_harness() {
  local compose_file="$1" prompt_file="$2"
  jig_write_system_prompt "$prompt_file" || return 1
  jig_write_harness_compose "$compose_file" || return 1
  export JIG_SYSTEM_PROMPT="$prompt_file"
  jig_harness_args=(--append-system-prompt-file "$jig_prompt_target")
  jig_compose_files+=(-f "$compose_file")
}
