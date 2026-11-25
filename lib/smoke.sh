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
  [ ! -f "$run/build.log" ] || jig_redact_files "$run" build.log
  echo "$jig_name: smoke exit $status after $(( $(date +%s) - started ))s"
  exit "$status"
}

rm -rf "$run"
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
