jig_rules_file="$engine_root/lib/rules.md"
jig_prompt_target=/jig/system-prompt.md
jig_plugin_target=/jig/overlay

jig_find_overlay() {
  local root="${JIG_PROFILES:-$jig_home/profiles}"
  case "$root" in
    /*) ;;
    *) jig_fail "JIG_PROFILES must be an absolute path" ;;
  esac
  overlay_dir="$root/$gh_owner/$gh_name"
  overlay_rules=""
  overlay_plugin=""
  [ -e "$overlay_dir" ] || [ -L "$overlay_dir" ] || return 0
  [ -d "$overlay_dir" ] || jig_fail "the overlay $overlay_dir must be a directory"
  if [ -e "$overlay_dir/rules.md" ] || [ -L "$overlay_dir/rules.md" ]; then
    [ -f "$overlay_dir/rules.md" ] && [ -r "$overlay_dir/rules.md" ] ||
      jig_fail "the overlay rules $overlay_dir/rules.md must be a readable regular file"
    overlay_rules="$overlay_dir/rules.md"
  fi
  if [ -e "$overlay_dir/plugin" ] || [ -L "$overlay_dir/plugin" ]; then
    [ -d "$overlay_dir/plugin" ] || jig_fail "the overlay plugin $overlay_dir/plugin must be a directory"
    overlay_plugin="$overlay_dir/plugin"
  fi
}

jig_harness_sources() {
  echo "engine rules: $jig_rules_file"
  if [ -n "$overlay_rules" ]; then
    echo "overlay rules: $overlay_rules"
  else
    echo "overlay rules: none (no $overlay_dir/rules.md)"
  fi
  if [ -n "$overlay_plugin" ]; then
    echo "overlay plugin: $overlay_plugin"
  else
    echo "overlay plugin: none (no $overlay_dir/plugin)"
  fi
}

jig_harness_shadows() {
  local name
  [ -n "$overlay_plugin" ] || return 0
  while IFS= read -r -d '' name; do
    [ -d "$overlay_plugin/skills/$name" ] &&
      echo "the overlay plugin's skill $name has the same name as .claude/skills/$name in the repository; the agent sees both"
  done < <(git -C "$repo_root" ls-tree -z --name-only "$base:.claude/skills" 2>/dev/null)
  while IFS= read -r -d '' name; do
    case "$name" in
      *.md) [ -f "$overlay_plugin/agents/$name" ] &&
        echo "the overlay plugin's agent ${name%.md} has the same name as .claude/agents/$name in the repository; the agent sees both" ;;
    esac
  done < <(git -C "$repo_root" ls-tree -z --name-only "$base:.claude/agents" 2>/dev/null)
  return 0
}

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
  {
    jig_engine_rules || return 1
    if [ -n "$overlay_rules" ]; then
      echo
      cat "$overlay_rules" || return 1
    fi
  } >"$1"
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
    if [ -n "$overlay_plugin" ]; then
      echo "      - type: bind"
      echo "        source: \${JIG_OVERLAY_PLUGIN:?jig sets JIG_OVERLAY_PLUGIN}"
      echo "        target: $jig_plugin_target"
      echo "        read_only: true"
    fi
  } >"$1"
}

jig_use_harness() {
  local compose_file="$1" prompt_file="$2"
  jig_write_system_prompt "$prompt_file" || return 1
  jig_write_harness_compose "$compose_file" || return 1
  export JIG_SYSTEM_PROMPT="$prompt_file"
  jig_harness_args=(--append-system-prompt-file "$jig_prompt_target")
  if [ -n "$overlay_plugin" ]; then
    export JIG_OVERLAY_PLUGIN="$overlay_plugin"
    jig_harness_args+=(--plugin-dir "$jig_plugin_target")
  fi
  jig_compose_files+=(-f "$compose_file")
}
