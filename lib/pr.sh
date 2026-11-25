jig_pr_body_max=65536
jig_pr_line_max=200
jig_pr_summary_max=40000
jig_pr_blocked_max=10000
jig_pr_cut_mark="*The description is cut here to stay within GitHub's limit.*"

# Prints at most $1 bytes of $2: up to the last line break that fits, or else up to the last whole UTF-8 character.
jig_cut() {
  local max="$1" text="$2" LC_ALL=C
  [ "$max" -gt 0 ] || return 0
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
    return 0
  fi
  text="${text:0:max+1}"
  case "$text" in
    *$'\n'*)
      printf '%s' "${text%$'\n'*}"
      return 0 ;;
  esac
  while [ "$max" -gt 0 ] && [[ ${text:max:1} == [$'\x80'-$'\xbf'] ]]; do
    max=$(( max - 1 ))
  done
  printf '%s' "${text:0:max}"
}

jig_pr_line() {
  local line LC_ALL=C
  line="$(printable "$1")"
  [ "${#line}" -le "$jig_pr_line_max" ] || line="${line:0:jig_pr_line_max-3}..."
  printf '%s' "$line"
}

# Prints the file with $3 before each line, in at most $1 bytes; a cut text ends with the note $4.
jig_pr_excerpt() {
  local max="$1" file="$2" prefix="$3" note="$4" text LC_ALL=C
  text="$(LC_ALL=C head -c $(( max + 1 )) "$file" | LC_ALL=C awk -v p="$prefix" '{ print p $0 }')" || return 1
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
    return 0
  fi
  printf '%s\n%s' "$(jig_cut $(( max - ${#note} - 1 )) "$text")" "$note"
}

jig_plan_issue() {
  local out ref re='^#[1-9][0-9]*$' LC_ALL=C
  out="$(LC_ALL=C awk '{ sub(/\r$/, "") }
    !seen && title && !/^[[:space:]]*$/ { seen = 1; if (sub(/^Issue:[[:blank:]]*/, "")) { ref = $0; next } }
    /^# / { title = 1 }
    /^#+ / { next }
    { l = tolower($0) }
    l ~ /^[[:blank:]]*[*_]*issue/ || l ~ /(^|[^a-z])issue[*_]*:/ { strays = strays NR ":" $0 "\n" }
    END { print ref; printf "%s", strays }' "$1")" || return 1
  ref="${out%%$'\n'*}"
  issue_strays=""
  [ "$out" = "$ref" ] || issue_strays="${out#*$'\n'}"
  ref="${ref%"${ref##*[![:space:]]}"}"
  issue_line=""
  issue_text=none
  [ -n "$ref" ] || return 0
  case "$ref" in
    *[\<\>]*) return 2 ;;
  esac
  if [[ $ref =~ $re ]]; then
    issue_line="Fixes $ref"
    issue_text="$issue_line"
  else
    issue_line="Issue: $(jig_pr_line "$ref")"
    issue_text="$(jig_pr_line "$ref") (as text)"
  fi
}

jig_issue_warnings() {
  local line
  [ -n "$issue_strays" ] || return 0
  while IFS= read -r line; do
    printf "the plan's line %s is not read as its Issue line: %s (jig reads \"Issue: <ref>\" only as the first line under the title)\n" \
      "${line%%:*}" "$(jig_pr_line "${line#*:}")"
  done <<<"$issue_strays"
}

jig_pr_render() {
  printf -v jig_pr_text '%s\n\n%s\n\n%s\n\n</details>\n\n%s\n' "$1" "$2" "$3" "$4"
}

# Sizes are counted in bytes, which are never fewer than the characters GitHub counts.
# The fence is longer than any backtick run in the plan, so no line of the plan can close it.
jig_pr_body() {
  local plan="$1" shown="$2" head="$3" tail="$4" LC_ALL=C
  local fence text open note max
  fence="$(LC_ALL=C awk '{ s = $0; while (match(s, /`+/)) { if (RLENGTH > m) m = RLENGTH; s = substr(s, RSTART + RLENGTH) } }
    END { for (n = (m < 3 ? 3 : m + 1); n > 0; n--) printf "`" }' "$plan")" || return 1
  text="$(cat "$plan")" || return 1
  jig_pr_render "$head" '<details><summary>Plan</summary>' "${fence}markdown
$text
$fence" "$tail"
  [ "${#jig_pr_text}" -gt "$jig_pr_body_max" ] || { printf '%s' "$jig_pr_text"; return 0; }
  open='<details><summary>Plan (cut)</summary>'
  note="*The plan is cut here: it has $(LC_ALL=C wc -c <"$plan" | tr -d ' ') bytes, the whole plan is in \`$shown\`.*"
  jig_pr_render "$head" "$open" "$note" "$tail"
  if [ "${#jig_pr_text}" -gt "$jig_pr_body_max" ]; then
    max=$(( jig_pr_body_max - ${#jig_pr_text} + ${#head} - ${#jig_pr_cut_mark} - 2 ))
    jig_pr_render "$(jig_cut "$max" "$head")

$jig_pr_cut_mark" "$open" "$note" "$tail"
    printf '%s' "$jig_pr_text"
    return 0
  fi
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

jig_shell_word() {
  local re='^[A-Za-z0-9_./=:@%+,-]+$' rest out="" LC_ALL=C
  if [[ $1 =~ $re ]]; then
    printf '%s' "$1"
  else
    rest="$1"
    while [[ $rest == *\'* ]]; do
      out="$out${rest%%\'*}'\\''"
      rest="${rest#*\'}"
    done
    printf "'%s%s'" "$out" "$rest"
  fi
}

jig_branch_commands() {
  local repo="$1" base="$2" branch="$3"
  printf 'git -C %s log --oneline %s..%s\n' "$(jig_shell_word "$repo")" "$base" "$branch"
  printf 'git -C %s diff %s...%s\n' "$(jig_shell_word "$repo")" "$base" "$branch"
}

jig_report_branch() {
  local repo="$1" branch="$2" commits="$3" base_branch="$4" base="$5" commit_word=commits
  [ "$commits" != 1 ] || commit_word=commit
  printf -- '- Repository: %s\n' "$repo"
  printf -- '- Branch: %s (%s %s)\n' "$branch" "$commits" "$commit_word"
  printf -- '- Base: %s at %s\n' "$base_branch" "$base"
}
