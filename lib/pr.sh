jig_pr_body_max=65536

# Sizes are counted in bytes, which are never fewer than the characters GitHub counts.
jig_pr_body() {
  local plan="$1" rest="$2" LC_ALL=C
  local open='<details><summary>Plan</summary>' text note room
  text="$(cat "$plan")" || return 1
  room=$(( jig_pr_body_max - ${#rest} - 1 ))
  if [ $(( ${#open} + ${#text} + 16 )) -gt "$room" ]; then
    open='<details><summary>Plan (cut)</summary>'
    note="*The plan is cut here: it has $(wc -c <"$plan" | tr -d ' ') bytes, the whole plan is in \`$plan\`.*"
    text="$(LC_ALL=C awk -v max=$(( room - ${#open} - ${#note} - 17 )) '{ n += length($0) + 1; if (n > max) exit; print }' "$plan")" ||
      return 1
    text="${text:+$text

}$note"
  fi
  printf '%s\n\n%s\n\n</details>\n\n%s\n' "$open" "$text" "$rest"
}
