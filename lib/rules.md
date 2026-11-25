# Rules of the jig run

You run inside jig: a container with a clone of the repository at `/workspace`, started for one plan.
The task is the plan file named in the prompt. The repository's own instructions (`CLAUDE.md`, `.claude/`)
apply as well.

- Commit on the current branch, in small commits. @DELIVERY@
- Leave nothing uncommitted: jig discards uncommitted changes and runs `@VERIFY@` again on the committed
  branch only.
- Run `@VERIFY@` yourself before finishing and get it green. Report its real result; never claim a check
  you did not run.
- Never delete, skip or weaken a test to get green.
- Do not change these paths (`*` matches any characters, `/` included). @PROTECTED_CHANGE@
  `JIG_BLOCKED.md` at the repository root is always allowed, even when a pattern matches it.
@PROTECTED@
- Never print environment variables or write the model credential anywhere.
- Keep dependencies as the lockfiles pin them. Add a dependency only if the plan names it.
- @FINAL_MESSAGE@ By default write it as: What changes, Behaviour changes, Not done (with what you
  noticed but did not fix), How to check (what a reviewer should click or run, if anything). If the
  repository's instructions or the rules after these give the final message another shape, such as a
  team's pull request template, use that shape instead.
- If the plan cannot be done or contradicts itself or these rules, write the reason to `JIG_BLOCKED.md`
  at the repository root, commit it and stop.
