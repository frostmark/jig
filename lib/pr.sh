jig_pr_body_max=65536

jig_pr_render() {
  printf -v jig_pr_text '%s\n\n%s\n\n%s\n\n</details>\n\n%s\n' "$1" "$2" "$3" "$4"
}

# Sizes are counted in bytes, which are never fewer than the characters GitHub counts.
# The fence is longer than any backtick run in the plan, so no line of the plan can close it.
jig_pr_body() {
  local plan="$1" head="$2" tail="$3" LC_ALL=C
  local fence text open note max
  fence="$(LC_ALL=C awk '{ s = $0; while (match(s, /`+/)) { if (RLENGTH > m) m = RLENGTH; s = substr(s, RSTART + RLENGTH) } }
    END { for (n = (m < 3 ? 3 : m + 1); n > 0; n--) printf "`" }' "$plan")" || return 1
  text="$(cat "$plan")" || return 1
  jig_pr_render "$head" '<details><summary>Plan</summary>' "${fence}markdown
$text
$fence" "$tail"
  [ "${#jig_pr_text}" -gt "$jig_pr_body_max" ] || { printf '%s' "$jig_pr_text"; return 0; }
  open='<details><summary>Plan (cut)</summary>'
  note="*The plan is cut here: it has $(LC_ALL=C wc -c <"$plan" | tr -d ' ') bytes, the whole plan is in \`$plan\`.*"
  jig_pr_render "$head" "$open" "${fence}markdown

$fence

$note" "$tail"
  max=$(( jig_pr_body_max - ${#jig_pr_text} + 1 ))
  text="$(LC_ALL=C awk -v max="$max" '{ n += length($0) + 1; if (n > max) exit; print }' "$plan")" || return 1
  if [ -n "$text" ]; then
    jig_pr_render "$head" "$open" "${fence}markdown
$text
$fence

$note" "$tail"
  else
    jig_pr_render "$head" "$open" "$note" "$tail"
  fi
  printf '%s' "$jig_pr_text"
}
