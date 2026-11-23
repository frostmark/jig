jig_check_host
jig_set_home
head="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || jig_fail "$repo_root has no commits"
jig_load_profile "$head" HEAD
jig_repo_identity

run="$jig_home/smoke/$gh_owner/$gh_name"
jig_project="jig-smoke_$docker_repo"
started=$(date +%s)

finish() {
  local status=$?
  trap '' INT TERM HUP
  set +e
  jig_down || [ "$status" -ne 0 ] || status=1
  echo "$jig_name: smoke exit $status after $(( $(date +%s) - started ))s"
  exit "$status"
}

rm -rf "$run"
mkdir -p "$run"
jig_extract_profile "$head" "$run/profile"
jig_clone "$head" "$run/repo"

jig_use_workspace "$run/repo"
trap finish EXIT
jig_compose up -d --build --wait
jig_compose exec -T app "./$profile_setup"
jig_compose exec -T app "./$profile_verify"

changes="$(jig_compose exec -T app git status --porcelain)"
if [ -n "$changes" ]; then
  echo "$jig_name: $profile_setup or $profile_verify left changes in the clone:" >&2
  echo "$changes" >&2
  exit 1
fi
