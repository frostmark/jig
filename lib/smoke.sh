jig_check_host
jig_set_home
jig_set_profiles
jig_check_disk
jig_use_builder
head="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || jig_fail "$repo_root has no commits"
jig_repo_identity
jig_find_overlay
jig_load_profile "$head" HEAD
jig_profile_report
jig_read_build_secrets

run="$jig_home/smoke/$gh_owner/$gh_name"
jig_project="jig-smoke_$docker_repo"
started=$(date +%s)

finish() {
  local status=$?
  trap '' INT TERM HUP
  set +e
  jig_down || [ "$status" -ne 0 ] || status=1
  if [ "$status" = 0 ]; then
    jig_remove_clone "$run/repo"
  elif [ -e "$run/repo" ]; then
    echo "$jig_name: the clone stays for a look until the next smoke: $run/repo. Its .git ran the repository's setup and verify, so a git-aware shell prompt or editor opened there can run its hooks and config: look at the files without git" >&2
  fi
  [ ! -f "$run/build.log" ] || jig_redact_files "$run" build.log
  echo "$jig_name: smoke exit $status after $(( $(date +%s) - started ))s"
  exit "$status"
}

jig_remove_clone "$run"
[ ! -e "$run" ] || jig_fail "smoke starts from an empty $run"
mkdir -p "$run"
jig_extract_profile "$head" "$run"
jig_use_workspace "$run/repo" "$head"
jig_check_compose "$run" || jig_fail "$jig_compose_problem"
jig_clone "$head" "$run/repo"

trap finish EXIT
jig_build "$run/build.log"
jig_compose up -d --wait --no-build
jig_compose exec -T -w /workspace app "$(jig_profile_command "$profile_setup")"
jig_compose exec -T -w /workspace app "$(jig_profile_command "$profile_verify")"

changes="$(jig_compose exec -T app git status --porcelain)"
if [ -n "$changes" ]; then
  echo "$jig_name: $profile_setup or $profile_verify left changes in the clone:" >&2
  echo "$changes" >&2
  exit 1
fi
