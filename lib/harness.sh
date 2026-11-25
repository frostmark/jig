jig_rules_file="$engine_root/lib/rules.md"
jig_prompt_target=/jig/system-prompt.md
jig_plugin_target=/jig/overlay
jig_plan_target=/jig/plan.md
jig_plan_prompt="Implement the plan in $jig_plan_target."

jig_set_profiles() {
  overlay_root="${JIG_PROFILES:-$jig_home/profiles}"
  case "$overlay_root" in
    /*) ;;
    *) jig_fail "JIG_PROFILES must be an absolute path" ;;
  esac
}

jig_find_overlay() {
  overlay_dir="$overlay_root/$gh_owner/$gh_name"
  overlay_rules=""
  overlay_plugin=""
  overlay_files=()
  overlay_config=""
  overlay_git=""
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
  jig_find_overlay_profile
}

jig_harness_sources() {
  local rules="$1" overlay="$2"
  echo "engine rules: $rules"
  if [ -n "$overlay_rules" ]; then
    echo "overlay rules: $overlay/rules.md"
  else
    echo "overlay rules: none (no $overlay/rules.md)"
  fi
  if [ -n "$overlay_plugin" ]; then
    echo "overlay plugin: $overlay/plugin"
  else
    echo "overlay plugin: none (no $overlay/plugin)"
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

jig_harness_report() {
  jig_say jig_harness_sources "$jig_rules_file" "$overlay_dir"
  jig_warn jig_harness_shadows
  jig_harness_md="## Harness

\`\`\`
$(jig_harness_sources "jig's lib/rules.md" "\$JIG_PROFILES/$gh_owner/$gh_name")
$jig_warnings\`\`\`
"
}

jig_protected_list() {
  local entry pattern covered listed=()
  jig_protected_patterns
  for entry in "${protected_patterns[@]}"; do
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
  local text protected verify
  text="$(cat "$jig_rules_file")" || return 1
  protected="$(jig_protected_list)"
  verify="cd /workspace && $(jig_profile_command "$profile_verify")"
  text="${text//@VERIFY@/$verify}"
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
    echo "      - type: bind"
    echo "        source: \${JIG_PLAN:?jig sets JIG_PLAN}"
    echo "        target: $jig_plan_target"
    echo "        read_only: true"
    if [ -n "$overlay_plugin" ]; then
      echo "      - type: bind"
      echo "        source: \${JIG_OVERLAY_PLUGIN:?jig sets JIG_OVERLAY_PLUGIN}"
      echo "        target: $jig_plugin_target"
      echo "        read_only: true"
    fi
  } >"$1"
}

jig_check_agent_env() {
  [ -z "${JIG_MODEL:-}" ] || jig_valid_model "$JIG_MODEL" || jig_fail "JIG_MODEL $jig_model_rule"
  [ -z "${JIG_EFFORT:-}" ] || jig_valid_effort "$JIG_EFFORT" || jig_fail "JIG_EFFORT $jig_effort_rule"
}

jig_agent_options() {
  jig_model="${JIG_MODEL:-$profile_model}"
  jig_model_source=JIG_MODEL
  [ -n "${JIG_MODEL:-}" ] || jig_model_source="the profile"
  jig_effort="${JIG_EFFORT:-$profile_effort}"
  jig_effort_source=JIG_EFFORT
  [ -n "${JIG_EFFORT:-}" ] || jig_effort_source="the profile"
  jig_agent_args=()
  [ -z "$jig_model" ] || jig_agent_args+=(--model "$jig_model")
  [ -z "$jig_effort" ] || jig_agent_args+=(--effort "$jig_effort")
}

jig_setting() {
  if [ -n "$1" ]; then printf '%s (from %s)' "$1" "$2"; else printf default; fi
}

jig_agent_settings() {
  printf 'model: %s, effort: %s' "$(jig_setting "$jig_model" "$jig_model_source")" "$(jig_setting "$jig_effort" "$jig_effort_source")"
}

jig_agent_report() {
  local meta="$1" models="$2" main others text
  main="${models%% *}"
  others=""
  [ "$models" = "$main" ] || others="${models#* }"
  [ -n "$main" ] || main=unknown
  if [ -z "$jig_model" ]; then
    text="model: $main (default)"
  elif [ "$jig_model" = "$main" ]; then
    text="model: $main (from $jig_model_source)"
  else
    text="model: $main ($jig_model from $jig_model_source)"
  fi
  [ -z "$others" ] || text="$text, also ${others// / and }"
  text="$text, effort: $(jig_setting "$jig_effort" "$jig_effort_source")"
  [ -z "$meta" ] || text="$meta, $text"
  printf '%s' "$text"
}

jig_use_harness() {
  local compose_file="$1" prompt_file="$2" plan_file="$3"
  jig_write_system_prompt "$prompt_file" || return 1
  jig_write_harness_compose "$compose_file" || return 1
  export JIG_SYSTEM_PROMPT="$prompt_file" JIG_PLAN="$plan_file"
  jig_harness_args=(--append-system-prompt-file "$jig_prompt_target")
  if [ -n "$overlay_plugin" ]; then
    export JIG_OVERLAY_PLUGIN="$overlay_plugin"
    jig_harness_args+=(--plugin-dir "$jig_plugin_target")
  fi
  jig_compose_files+=(-f "$compose_file")
}
