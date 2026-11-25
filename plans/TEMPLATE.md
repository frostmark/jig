<!--
Plan template for jig. Copy it to plans/<slug>.md (the slug is lowercase latin letters, digits and
dashes; it also names the branch jig/<slug>), fill in the sections and delete the comments.

The agent knows about the task only what is written here and in the repository's own instructions
(CLAUDE.md and the like), and it cannot ask questions. Write down everything it must not decide by itself.
Done for the agent = every acceptance criterion is pinned by a test that fails without the change,
and the profile's verify command is green.
-->

# <The outcome, in one sentence>

Issue: <ref>

<!--
The issue this plan implements: #123 for an issue of this repository (the PR description then starts
with "Fixes #123", so merging the PR into the default branch closes it), or a tracker ID such as ABC-123
(written at the top of the PR description as is). Delete the line when there is none. It stays right
under the title.
-->

<!-- Why it is needed and what is wrong now. Two or three sentences. -->

## Product decisions

<!--
What the user sees and does: fields, behaviour, empty states and errors, texts.
Everything the agent would otherwise choose by itself.
-->

- 

## Architecture decisions

<!--
Only what is already decided: where the rule lives, which endpoint or model changes,
whether a migration or a new dependency is needed. The agent chooses the rest by the repository's instructions.
-->

- 

## Acceptance criteria

<!--
Checkable statements. The agent pins each one with a test that fails without the change.
Example: "GET /health answers 200 with the application version".
Mark what only a browser can show with "(check on the preview)": a person checks it in the PR.
-->

- [ ] 
- [ ] verify is green

## Out of scope

<!-- What not to do, even if it looks close and easy. -->

- 

## Links

<!-- Files and places in the code, related issues, earlier PRs, external documents. -->

- 
