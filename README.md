# jig

`jig run <plan>` takes a plan file, has Claude Code implement it in a Docker container and opens a pull
request on the target repository, or, with `deliver branch`, leaves the branch in your checkout with a
report and pushes nothing. Code enters the container as a clone and leaves it as a branch; the
container gets no GitHub access, and the only secret jig hands it is the model credential. The profile's
files, the overlay's included, are readable in the container, so they must not hold secrets.

jig is the engine. Each target repository's environment is described by a profile: the repository's
`.jig/` directory, your personal overlay outside the repository, or both (see
[Repository profile](#repository-profile)). What the agent is told comes from the
repository's own instructions, the engine rules and your personal overlay (see [Harness](#harness)).

## Install

1. Docker (Docker Desktop or any Docker with `docker compose`) is running; git 2.49 or newer (`git --version`).
2. `origin` is the repository on GitHub. jig takes its `<owner>/<repo>` from the URL of `origin`
   (`git remote get-url origin`): `https://github.com/<owner>/<repo>`, `git@github.com:<owner>/<repo>`
   or `ssh://git@github.com/<owner>/<repo>`, with or without `.git`, a user, a port or a trailing `/`;
   the host may be in any case. An SSH host alias (`git@github-work:acme/shop.git`, also one that an
   `insteadOf` rule rewrites `origin` to, since jig reads the rewritten URL) and
   `ssh://git@ssh.github.com:443/...` are not accepted: keep `origin` at `git@github.com:<owner>/<repo>`
   and choose the key or the port in SSH instead, with `git -C <repo> config core.sshCommand
   'ssh -i ~/.ssh/<key>'` or a `Host github.com` block in `~/.ssh/config` (`Hostname ssh.github.com` and
   `Port 443` for the port). Owner and name keep the URL's spelling, and they name the overlay
   directory, the run directories and the compose projects, so use GitHub's spelling, as its clone button
   gives it. Any other `origin`, and an owner or name of `.`, `..` or `.git` in any case (they would name
   directories that are not the repository's), stops jig with exit code 2 before anything runs. jig fetches from `origin`
   and checks that `jig/<slug>` is not there yet with the host's git credentials. Its fetches update
   `origin/<base>` and never write `FETCH_HEAD`, so a `git pull` or `git merge FETCH_HEAD` of yours is not
   redirected by a run.
3. `gh auth login`, for `deliver pr` (the default) only: jig pushes the branch with a plain
   `git push origin` (`gh` can serve the git credentials as a credential helper) and opens the PR with
   `gh pr create`. Before anything runs it asks `gh repo view <origin URL>` for the repository's name,
   which must be the URL's `<owner>/<repo>` exactly (a repository renamed on GitHub or a URL in another
   case stops jig with exit code 2: set `origin` to GitHub's spelling), and passes it as `--repo` to
   `gh pr create`, so in a fork the PR goes to the fork, never to the upstream repository that `gh`
   would pick on its own. `deliver branch` and `jig smoke` never run `gh`.
4. Link `bin/jig` into a directory on `PATH`: `ln -s /path/to/jig/bin/jig ~/.local/bin/jig`. jig
   follows the link (and chains of links) back to its checkout to find `lib/`.
5. Model credential, exactly one variable.

   A subscription token kept in the macOS keychain:

   ```sh
   claude setup-token                                     # in a separate terminal, prints the token
   security add-generic-password -U -a "$USER" -s jig -w  # asks for the password: paste the token
   CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -a "$USER" -s jig -w)" \
     jig run plans/<slug>.md
   ```

   This keeps the token out of the shell history and out of the terminal's environment. On Linux:
   `export CLAUDE_CODE_OAUTH_TOKEN=<token>`. Or the API: `export ANTHROPIC_API_KEY=<key>` (billed
   separately from the subscription).

   If both are set, jig refuses to start: Claude Code would pick the API key. The value may contain only
   latin letters, digits, `_` and `-` (both the token and the key look like that); otherwise jig refuses
   to start too and does not print the value.

## Repository profile

A repository is ready for jig when it has `.jig/config`, or when your overlay supplies one (see
[Profile files from the overlay](#profile-files-from-the-overlay)). The profile is:

- `.jig/config`: settings, data only (below);
- `.jig/compose.yml` and whatever it builds (usually `.jig/Dockerfile`);
- the setup and verify scripts that `.jig/config` names.

### `.jig/config`

```
# .jig/config of acme/shop
base main
setup .jig/setup
verify scripts/verify
protect CLAUDE.md
protect */CLAUDE.md
protect .claude/*
protect deploy/*
```

Each line is `<key> <value>`, separated by spaces or tabs; blank lines and lines starting with `#` are
skipped. The value has no spaces, and there are no inline comments. jig never sources or evaluates the
file on the host.

| Key | | Value |
|---|---|---|
| `base` | required, once | The branch jig starts from and opens the PR against. Latin letters, digits, `.`, `_`, `/`, `-`, starting with a letter or digit, and a valid git branch name (`git check-ref-format`). |
| `setup` | required, once | Script that prepares the environment (installs dependencies, creates databases). A path relative to the repository root: parts of latin letters, digits, `.`, `_`, `-` joined by `/`, no `.` or `..` parts, not starting with `-`. jig runs it before the agent starts, with `/workspace` as the working directory: a path under `.jig/` is a profile file and runs as `/jig/profile/<rest>` (see [Paths in the config](#paths-in-the-config)), any other path runs as `./<path>`. What it gets: [What setup and verify get](#what-setup-and-verify-get). |
| `verify` | required, once | The check that decides green or red (tests, linters, build). Same rules as `setup`. The agent is asked to get it green; jig runs it again on the committed branch after the agent. |
| `protect` | any number | Paths the agent must not change. A glob of latin letters, digits, `.`, `_`, `-`, `/` and `*`, not starting with `/`. `*` matches any characters including `/`: `deploy/*` covers everything under `deploy/`, `*/CLAUDE.md` every nested `CLAUDE.md`. A branch that changes a protected path becomes a draft PR, or with `deliver branch` a run that needs attention (exit code 1). `.jig/` and the `setup` and `verify` scripts are always protected and need no line here; `JIG_BLOCKED.md` at the repository root is always allowed. |
| `model` | optional, once | The model the agent runs on, passed to Claude Code as `--model`: an alias such as `opus` or `sonnet[1m]`, or a full model name. Latin letters, digits, `.`, `_`, `:`, `@`, `/`, `[`, `]`, `-`, starting with a letter or digit, at most 100 characters. `JIG_MODEL` replaces it for one run. Without either, jig passes no `--model` and Claude Code's default applies. `jig smoke` checks the value and does not use it. |
| `effort` | optional, once | The reasoning effort, passed to Claude Code as `--effort`: `low`, `medium`, `high`, `xhigh` or `max`. `JIG_EFFORT` replaces it for one run. Without either, jig passes no `--effort` and Claude Code's default applies. |
| `deliver` | optional, once | How the branch is delivered: `pr` (the default) pushes it and opens a pull request, `branch` leaves it in your checkout with a report and pushes nothing (see [Branch delivery](#branch-delivery)). `jig smoke` checks the value and does not use it. |

An unknown key, a missing required key, a repeated `base`, `setup`, `verify`, `model`, `effort` or `deliver`, or a
value outside its character set stops jig with exit code 2 before anything runs; the message names the file and the line,
for example `jig: origin/main:.jig/config:4: unknown key colour` (or the overlay's `config` with its
path). jig also stops with code 2 when the profile lacks `compose.yml` or a `setup` or `verify` script.

`model` and `effort` (or `JIG_MODEL` and `JIG_EFFORT`) need a Claude Code in the profile's image that
has `--model` and `--effort`. jig does not check the version: with an older CLI the agent fails at
start, and the reason is in `claude.log`.

### Paths in the config

A `setup` or `verify` value under `.jig/` names a file of the profile: the overlay's file of that name if
there is one, otherwise the base commit's. jig mounts the whole profile read-only at `/jig/profile` in
the `app` service and runs `.jig/setup` as `/jig/profile/setup`, always with `/workspace` as the
working directory. Any other value is a repository file: it must exist in the base commit and runs as
`./<path>` from the clone. The engine rules give the agent the `verify` command with its working
directory, `cd /workspace && /jig/profile/verify` or `cd /workspace && ./scripts/verify`, so it runs in
the right place even after the agent changed directory.

This changes how existing profiles run: jig used to run `.jig/setup` as `./.jig/setup` in the clone.

- A script under `.jig/` must find the repository through the working directory, `/workspace`, not
  through its own path: `cd "$(dirname "$0")/.."` now leads to `/jig`. It reaches its sibling profile
  files as `"$(dirname "$0")/<file>"` (the merged profile, overlay files included); `./.jig/<file>` is the
  clone's copy from the base commit, as the agent may have changed it, never the overlay's.
- The `verify` that jig runs on the committed branch after the agent is the profile's copy, from the base
  commit or the overlay, not a `.jig/verify` the agent changed and committed (such a change still makes
  the PR a draft, or with `deliver branch` the run need attention).

### What setup and verify get

`setup`, `verify` and the agent's whole session (the agent runs `verify` itself) run in the `app` service
with:

- `/workspace` as the working directory: the clone, in `jig run` on the branch `jig/<slug>`, in
  `jig smoke` on the checked `HEAD` commit, detached. `setup` runs before the agent, while the branch
  still points at the base commit; the final `verify` runs on the branch's last commit with uncommitted
  changes discarded.
- `JIG_BASE`: the full sha of the base commit the branch starts from. It is always set, so a `verify`
  that cannot run the whole suite can check only what the branch changed, for example
  `git diff --name-only "$JIG_BASE" HEAD`. In `jig smoke` it is the `HEAD` commit that smoke checks, so
  that diff is empty there.

jig sets `JIG_BASE` in the `app` service's environment through the compose file it adds for the profile
(`compose.profile.yml`), so every command in that service sees the same value; a `JIG_BASE` that the
profile's `compose.yml` sets is replaced. Other services do not get it.

### Where jig reads the profile from

- `jig run` reads the repository's part from the base commit on `origin`, never from your working tree
  or local branches. Without an overlay `config`, it asks `origin` for its default branch
  (`git ls-remote --symref origin HEAD`), fetches it into `origin/<branch>` (whatever that ref held
  before is overwritten, so a stale one is never used) and reads `.jig/config` there. If `base` names
  another branch, jig fetches that branch and reads the profile again from it; that copy must name
  itself as `base`. With an overlay `config`, its `base` names the branch: jig fetches that branch the
  same way and takes the rest of the profile from it, without reading the default branch.
- `jig smoke` reads the repository's part from the `HEAD` commit of the checkout: commit profile changes
  in the repository before checking them. The overlay's files are read as they are on disk in both
  commands.

jig builds the profile in the run directory: `.jig/` of that commit (`git archive`), then the overlay's
profile files copied over it. It runs `docker compose` from that copy, so neither uncommitted files in
the repository on the host (a local `.jig/.env` included) nor the agent's edits in the clone feed the
compose project. The copy holds only the profile: `build.context: .` and relative mounts in
`compose.yml` see the profile and nothing else of the repository, so a Dockerfile cannot `COPY`
repository files (lockfiles, for example). Repository code reaches the container only through the
`${JIG_WORKSPACE}` mount.

### Profile files from the overlay

The overlay directory of a repository, `$JIG_PROFILES/<owner>/<repo>/` (see
[Personal overlay](#personal-overlay)), mirrors `.jig/`: its files other than `rules.md` and `plugin/`
(the harness) are profile files, at the same relative path as under `.jig/`. When `JIG_PROFILES` is the
top level of a git repository that holds the overlay directory, these are the files git lists there,
tracked and untracked but not ignored (`git ls-files -co --exclude-standard`): ignored files such as
`.env`, `.DS_Store` or editor swap files are left out, and so is a tracked file deleted from disk. Put such
patterns in the overlay repository's root `.gitignore`; a `.gitignore` inside `<owner>/<repo>/` is itself a
profile file. Otherwise every file in the directory is a profile file, dotfiles included. The agent can
read every profile file at `/jig/profile`, so secrets must not live in the overlay directory.

Each file comes from one layer: the overlay's file when it has one, otherwise the repository's, file by
file, also in subdirectories. `config` is no exception: it is taken whole from one layer, never merged by
key, and parsed with the same rules. So the overlay can replace a `Dockerfile` and nothing else, or hold
the whole profile of a repository that has no `.jig/` at all:

```
~/.jig/profiles/
  acme/shop/
    config          replaces .jig/config, or is the only one
    compose.yml
    Dockerfile
    setup           with "setup .jig/setup" in config
    rules.md        harness, not a profile file
    plugin/         harness, not a profile file
```

Overlay files are copied, so a link in the overlay becomes a regular file in the profile; the copy keeps
the overlay file's mode (make scripts executable there). An overlay file whose name is not latin letters,
digits, `.`, `_`, `-` in parts joined by `/`, one that is not a readable regular file (a dangling link
or a link to a directory, for example), or a path that is a file in one layer and a directory in the
other stops jig with exit code 2 before anything runs.

At start jig prints the source of every profile file and warns (on stderr) when an overlay file replaces
a repository file:

```
jig: overlay commit: 4f1c2e9a0b7d6c5e4f3a2b1c0d9e8f7a6b5c4d3e
jig: profile .jig/Dockerfile: overlay /home/you/.jig/profiles/acme/shop/Dockerfile
jig: profile .jig/compose.yml: repository
jig: profile .jig/config: repository
jig: profile .jig/setup: repository
jig: WARNING: the overlay's Dockerfile replaces the repository's .jig/Dockerfile
```

The overlay commit is `git -C $JIG_PROFILES rev-parse HEAD`, printed when the repository has an overlay
directory and `JIG_PROFILES` is the top level of a git repository; a directory inside another repository
(a dotfiles repository that ignores `~/.jig`, for example) does not count. When the overlay directory has
uncommitted changes or untracked files (`git status`; ignored files do not count), jig warns
`the overlay has uncommitted changes in acme/shop, and this run uses them`; when `JIG_PROFILES` is not a
git repository with a commit, or the overlay directory is a link out of it, it warns that the overlay's
version cannot be recorded. Neither stops the run. A link in the overlay is committed as a link, not as
the file it points to, so a change of that file is neither in the overlay commit nor warned about.
`jig run` puts the same lines in the PR description under "Profile", with the overlay's paths as
`$JIG_PROFILES/acme/shop/...` instead of host paths; there the sources and the warnings stop after 50
lines each with `... and <n> more`.

### Compose contract

`.jig/compose.yml` has a service `app` that:

- mounts `${JIG_WORKSPACE}` (the clone) at `/workspace` and works there;
- takes the `JIG_UID` and `JIG_GID` build args and runs as a non-root user with that uid and gid, so the
  files it writes in the clone belong to you;
- has `git`, `node`, `claude` (Claude Code) and `timeout` on `PATH`: jig creates and bundles the branch
  with git, runs the agent under `timeout` and reads its log with node;
- stays up (`command: ["sleep", "infinity"]`) and becomes healthy, because jig starts the project with
  `docker compose up --wait` and then runs commands with `docker compose exec`.

```yaml
services:
  app:
    build:
      context: .
      args:
        UID: ${JIG_UID:-1000}
        GID: ${JIG_GID:-1000}
    command: ["sleep", "infinity"]
    init: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - ${JIG_WORKSPACE:?JIG_WORKSPACE must point at the clone}:/workspace
```

The `app` service also gets read-only mounts under `/jig` from compose files jig adds after this one:
the profile at `/jig/profile` (in `jig run` and `jig smoke`), and in `jig run` the plan at `/jig/plan.md`
and the harness (see [Harness](#harness)). Keep that path free in the image. The same compose files set
`JIG_BASE` in the `app` service's environment (see
[What setup and verify get](#what-setup-and-verify-get)).

Other services (a database, a cache) are the profile's business. No ports need to reach the host. The
compose file runs on the host's Docker, so whoever can merge into `base` decides what the containers get
(mounts, privileges); review `.jig/` changes like CI changes.

## Harness

The harness is what the agent is told and can use: rules, skills, subagents, commands, hooks. In
`jig run` it comes from three places, and all of them apply at once:

1. The repository: `CLAUDE.md` and `.claude/` in the clone, loaded by Claude Code as in any checkout.
2. The engine rules, `lib/rules.md` of jig.
3. Your personal overlay, outside the repository: `rules.md` and `plugin/`.

### Engine rules

`lib/rules.md` is appended to the agent's system prompt in every run. It holds what jig relies on: commit
on the current branch and push nothing, leave nothing uncommitted, run `verify` and report its real
result, do not weaken tests, do not touch the protected paths, never print the environment, add a
dependency only if the plan names it, where the final message goes, and write `JIG_BLOCKED.md` when the
plan cannot be done. Three sentences follow the delivery mode. With `deliver pr`: jig pushes and opens the
pull request, a protected path makes it a draft and `.github/` stops the push, and the final message
becomes part of the PR description. With `deliver branch`: jig hands the branch to the owner, a protected
path or `.github/` marks it for the owner's attention, and the final message goes into the run report.
The final message's shape, What changes, Behaviour changes, Not done, How to check, is a default: the
rules say that a shape given by the repository's instructions or by the rules after them (the overlay's
`rules.md`, a team's PR template, for example) wins. The repository's own instructions are included on
purpose: a repository that has taken its harness over from the overlay carries its team's template in
its own `CLAUDE.md`. jig fills in the `verify` command with its working directory
(`cd /workspace && ./<path>`, or `cd /workspace && /jig/profile/<rest>` for a path under `.jig/`) and the
run's protected paths: `.jig/*`, the `setup` and `verify` scripts
and the `protect` list of the profile's config, leaving out an entry that an earlier
one already covers; the rules say that `JIG_BLOCKED.md` is allowed even when a
pattern matches it. The draft decision below (needs attention with `deliver branch`) checks the same list. The prompt itself only names the plan:
`Implement the plan in /jig/plan.md.`

### Personal overlay

The overlay holds harness and profile files you are trying out before they move into the repository
(profile files: see [Profile files from the overlay](#profile-files-from-the-overlay)). Its root is
`JIG_PROFILES` (an absolute path, `$JIG_HOME/profiles` by default, so `~/.jig/profiles`); keep it as a
private git repository of its own. Each target repository has a directory `<owner>/<repo>/` there, named
like its run directories (the owner and name from the URL of `origin`, see [Install](#install)) and
spelled exactly so: an owner or repository directory that differs only in case stops `jig run` and
`jig smoke` with exit code 2 and both spellings, on any filesystem, rather than being used on a
case-insensitive disk and silently skipped on a case-sensitive one:

```
~/.jig/profiles/
  acme/shop/
    rules.md
    plugin/
      .claude-plugin/plugin.json   optional: {"name": "..."}
      skills/<name>/SKILL.md
      agents/<name>.md
      commands/<name>.md
      hooks/hooks.json
```

- `rules.md` is appended to the system prompt after the engine rules.
- `plugin/` is one Claude Code plugin, loaded with `--plugin-dir`. Without `.claude-plugin/plugin.json`
  the plugin is named `overlay`, so its skills and agents appear as `overlay:<name>`; a manifest's `name`
  replaces that. Its hooks run as in any plugin, with `${CLAUDE_PLUGIN_ROOT}` set to `/jig/overlay`.
  Claude Code skips a plugin whose manifest is not valid JSON without an error; the `plugins` field of
  the `"subtype":"init"` line of `claude.log` lists the plugins that loaded.

Both are optional: without the overlay directory, or without one of them, the run goes on with what
there is. The other files in the directory are profile files, readable by the agent (see
[Profile files from the overlay](#profile-files-from-the-overlay)). An `<owner>/<repo>` that is not a
directory, a `rules.md` that is not a readable regular file or a `plugin` that is not a directory stops
jig with exit code 2 before anything runs.

jig writes `system-prompt.md` (the engine rules, then the overlay's `rules.md`) and
`compose.harness.yml` into the run directory and passes that compose file after the profile's
`compose.yml`, so the profile needs no change. It mounts `system-prompt.md` at `/jig/system-prompt.md`,
the plan's copy `plan.md` at `/jig/plan.md` and `plugin/` at `/jig/overlay` in `app`, all read-only and
outside `/workspace`, and starts the agent
with `--append-system-prompt-file /jig/system-prompt.md` and, when there is a plugin,
`--plugin-dir /jig/overlay`, followed by `--model` and `--effort` when they are set (see
[`.jig/config`](#jigconfig)). The plugin directory is mounted as it is on disk, so edits to it during a
run are visible in the container.

### What wins

The agent gets the repository's harness, the engine rules and the overlay together. In the system prompt
the overlay's rules come after the engine rules. Plugin skills and agents carry the plugin's prefix, so
an overlay skill named like one in the repository does not hide it: the agent sees both (`review` and
`overlay:review`).

Whole plugins are another matter. Claude Code tells plugins apart by the `name` in their manifest (an
overlay plugin without one is `overlay`), and a plugin loaded with `--plugin-dir`, as the overlay plugin
is, replaces an installed marketplace plugin or a skills-directory plugin
(`.claude/skills/<dir>/.claude-plugin/plugin.json`) of the same name
([name conflicts](https://code.claude.com/docs/en/plugins/loading#name-conflicts)). That is the case
when a plugin moves from the overlay into the repository under the same name while the overlay still
has it: the agent gets the overlay's copy and not the repository's. Remove the plugin from the overlay
when it moves; jig does not compare plugin names.

At start `jig run` prints where each item comes from and warns when an overlay skill or agent has the
same name as one in the base commit's `.claude/skills/<name>/` or `.claude/agents/<name>.md`:

```
jig: engine rules: /opt/jig/lib/rules.md
jig: overlay rules: none (no /home/you/.jig/profiles/acme/shop/rules.md)
jig: overlay plugin: /home/you/.jig/profiles/acme/shop/plugin
jig: WARNING: the overlay plugin's skill review has the same name as .claude/skills/review in the repository; the agent sees both
```

The PR description gets the same lines under "Harness" without host paths: the engine rules appear as
`jig's lib/rules.md` and the overlay items under `$JIG_PROFILES/acme/shop/`.

## Plan

Copy `plans/TEMPLATE.md` (from this repository, or the target repository's own template) to
`<slug>.md` and fill it in. The slug is lowercase latin letters, digits and dashes; it also names the
branch `jig/<slug>`. The file can live anywhere. At launch jig copies it to `plan.md` in the run
directory and mounts that copy read-only at `/jig/plan.md`; the prompt is
`Implement the plan in /jig/plan.md.` Changing the file after launch does not change the run.

Right under the title goes the issue the plan implements, as `Issue: <ref>`. jig reads it from the
first line after the plan's first `# ` heading that is not blank, so it must come before any other text.
With an issue of the repository, `#123`, the PR description starts with `Fixes #123`, and merging the PR
closes the issue (GitHub reads closing keywords only in PRs into the repository's default branch). Any
other reference, such as a tracker ID, opens the description as is: `Issue: ABC-123` (printable ASCII,
at most 200 bytes). A plan without the line, or with an empty one, gets neither. jig reads the line
from the plan's copy at launch and prints what it found: `jig: issue: Fixes #123`,
`jig: issue: ABC-123 (as text)` or `jig: issue: none`. A reference with `<` or `>`, such as the
template's `<ref>` left in, stops jig with code 2 before anything runs, and the run directory is
removed. Any other line that looks like an Issue line gets a warning naming it, because jig does not
read it: a line that starts with `issue` in any case, also indented or in bold (`**Issue:** #5`), or
one with `Issue:` after other text. Headings are not checked.

The plan is never committed: the branch holds only the agent's commits, and the reasoning behind a change
belongs in the issue and the PR description. The PR description ends with the plan text in a collapsed
"Plan" block, just before the attribution line. The plan sits in a fenced `markdown` code block whose
fence is longer than any run of backticks in the plan, so neither a cut nor the plan's own fences, HTML
comments or `</details>` can reach past the block. The plan's first `# ...` heading becomes the PR title.

jig holds the whole description within 65,536 bytes, which is never more characters than GitHub's limit
of 65,536 characters:

- the agent's final message is cut at 40,000 bytes, `JIG_BLOCKED.md` at 10,000 bytes once quoted, and
  each entry of the uncommitted-changes and protected-paths lists at 200 bytes (ending in `...`);
- the plan takes the room that is left. A cut plan keeps the whole lines that fit, the block is titled
  "Plan (cut)" and ends with the plan's size and the path of the whole copy;
- if even the plan's note does not fit, the description is cut before it and says so.

A cut text keeps the lines that fit, or in a single long line the whole UTF-8 characters that fit, and
says where the whole text is in the run directory.

## Usage

```sh
cd ~/src/shop
jig smoke                                          # build the image, run setup and verify on HEAD
jig run plans/add-health-check.md
JIG_TIMEOUT=30 jig run plans/add-health-check.md   # the agent's limit in minutes, 60 by default
JIG_MODEL=opus JIG_EFFORT=high jig run plans/add-health-check.md   # over the profile's model and effort
jig run ~/plans/add-health-check.md --repo ~/src/shop
```

`--repo` defaults to the git checkout of the current directory. The plan path is relative to the
current directory. `JIG_HOME` (an absolute path, `~/.jig` by default) holds run and smoke directories;
`JIG_PROFILES` (an absolute path, `$JIG_HOME/profiles` by default) is the overlay root. `JIG_MODEL` and
`JIG_EFFORT` replace the profile's `model` and `effort` for one run and follow the same rules; an empty
value counts as unset, and an invalid one stops jig with code 2 before anything runs.

What `jig run` does: precondition checks → the owner and name from the URL of `origin` → the overlay
lookup → the base and the profile (`.jig/` of `origin/<base>` with the overlay's profile files over it) →
with `deliver pr`, `gh`'s login and its name for the repository → the profile and harness sources printed →
the profile and the plan's copy written to the run directory → the plan's Issue line read and printed →
the system prompt and the compose overrides written to the run directory →
a clone of that commit in `$JIG_HOME/runs/<owner>/<repo>/<slug>/repo` → compose project
`jig-run_<owner>_<repo>_<slug>` (no ports on the host; owner and repo lowercased, characters other than
latin letters, digits and `-` turned into `-`) → the branch `jig/<slug>` and `setup` in the container →
`claude -p` under the time limit, with `--model` and `--effort` when set → the branch leaves the container as a bundle → uncommitted changes are
discarded (`git checkout -f`, `git clean -fd`, also in the middle of an abandoned merge or rebase) and
`verify` runs on the committed branch → `docker compose down -v` (always: on errors and on Ctrl-C, even a
repeated one) and removal of the clone → on the host: fetch the branch's commits from the bundle into the
target repository, check that they start from the base and scan them for the credential, and only then
create `jig/<slug>` there (a new ref only: its working tree, index and current branch stay as they are; a
run that stops before the scan leaves no branch) → with `deliver pr` `git push origin` and
`gh pr create --base <base>`; with `deliver branch` write `report.md`.

The PR description starts with the plan's issue line (`Fixes #123` or `Issue: ABC-123`, see
[Plan](#plan)), then the result of `verify`, the agent, the duration and the path of `claude.log`. The
agent line has the agent's exit code, the outcome, turns and estimated cost from `claude.log`, the model
the agent ran on and the effort:

```
- Agent: exit 0, success, turns: 15, estimated cost $1.23, model: claude-opus-5-5 (opus from the profile), effort: high (from JIG_EFFORT)
```

The model is the one `claude.log` names when the session starts, or `unknown` when it names none. In
parentheses: `default` when jig passed no `--model`, otherwise the value jig passed and where it came
from (`the profile` or `JIG_MODEL`), only the source when the log names the same model. Other models the
run used, by subagents for example, follow as `also <model>`: five at most, then `and N more`. The
agent can write to its own log, so jig takes from it only values of its own shape and leaves out the
rest: an outcome of lowercase letters and `_` (40 at most), whole turns, a cost below a million dollars,
and model names that follow the rule of the `model` key. The effort is not in the log: it is the value
jig passed with its source, or `default`. The terminal shows the
requested model and effort before the agent starts (`jig: agent model: ..., effort: ...`), on the line
after the delivery mode (`jig: deliver: pr (pushes jig/<slug> and opens a PR)` or `jig: deliver: branch`),
and the same text as the PR's agent line after it (`jig: agent: ...`), in a run without commits too. That line is
printed before the credential scan, so the credential's value in it (a model name the agent wrote into
its log, for example) is shown as `[REDACTED]`; the PR description or report that carries it is refused.

The PR is opened as a draft if `verify` is red, the time limit hit, the agent exited with an error, left
`JIG_BLOCKED.md` or uncommitted changes, changed a protected path (`.jig/`, the `setup` and `verify`
scripts, and the `protect` list of the profile's config; `JIG_BLOCKED.md` is never one), or made commits
that change nothing against `base` apart from `JIG_BLOCKED.md` (a change and its revert, for example).
The reasons are listed in the PR description under "Needs attention".

If the agent made no commits on the branch, there is nothing to push or review: jig skips the bundle and
the final `verify`, removes the compose project and the clone, prints the agent's result and where to
look (an uncommitted `JIG_BLOCKED.md` in `blocked-worktree.md`, uncommitted changes in `status.txt`, the
agent's final message in `summary.md`) and exits with code 3. No branch is created in the target
repository.

jig pushes nothing (exit code 3; the local branch `jig/<slug>` is deleted, or never created when the
branch itself carries the credential):

- if the model credential's value is found in the objects that would be pushed (`branch.objects`: whole
  commits with any headers, trees and files), in the branch diff (`branch.patch`), in the agent's final
  message, in an uncommitted `JIG_BLOCKED.md`, in the plan's copy (`plan.md`: its heading is the PR title
  even when the cut leaves it out of the description) or in the PR description; `branch.bundle` is then
  deleted;
- with `deliver pr`, if the branch touches `.github/` in any commit or in its final diff against `base` (a
  pushed workflow would run with the repository's secrets and write access). The credential is checked
  first, so a branch with both `.github/` and the token loses `branch.bundle` too. With `deliver branch`
  the branch is kept instead (see [Branch delivery](#branch-delivery)).

A commit with a NUL byte fails fsck when the branch is fetched from the bundle: that is also exit code 3
without a push, but `branch.bundle` stays. If the value is found only in local files of the run
directory (`claude.log` and others), jig replaces it there with `[REDACTED]` and deletes a file it could
not clean; either way it warns loudly which files were affected and goes on.

Exit codes of `jig run`:

| Code | Meaning |
|---|---|
| 0 | the PR is open and ready for review; with `deliver branch`: the branch is in the target repository and nothing needs attention |
| 1 | the PR is open as a draft; with `deliver branch`: the branch is in the target repository and the report lists what needs attention |
| 2 | invalid call, invalid profile or an unmet precondition; nothing ran |
| 3 | a failure, a refusal to push or to keep the branch, or an agent that made no commits, before the PR was opened or the branch handed over; the message says where to look, the run directory is kept |
| 130 | interrupted by Ctrl-C at any step after the preconditions; logs are kept, the compose project is removed and the clone deleted, except for a Ctrl-C while cloning (see below) |

Code 1 means only "the PR is a draft" (or "needs attention"), 130 only Ctrl-C (or SIGTERM): a repeated
Ctrl-C while the project is being removed does not interrupt `docker compose down`.

### Branch delivery

With `deliver branch` in the profile's config, jig fetches `jig/<slug>` into the target repository as with
`deliver pr` and stops there: no push, no `gh` call (`gh` need not be installed or logged in), and nothing
leaves the machine. The checks for an existing `jig/<slug>`, local or on `origin`, stay, so your push later
cannot collide. Review the branch and push it yourself.

`report.md` in the run directory takes the place of the PR description. It starts with the plan's title
as a heading (the PR title with `deliver pr`), then has the same parts: the plan's issue line
(`Fixes #123` or `Issue: ABC-123`), then the repository's path, the branch with its number of commits, the
base branch and commit, `verify`, the agent, the duration, the paths of `claude.log` and of the plan's copy
(not the plan text), the commands to read the branch, then "Needs attention", "Profile", "Harness" and the
agent's final message. There is no attribution line.

The report stays on your machine, so it uses host paths where the PR description writes
`$JIG_HOME/runs/...`: the repository in its lines and commands, and the run directory's files it names
(`claude.log`, `plan.md`, and `verify.log`, `summary.md`, `blocked-branch.md` or `blocked-worktree.md`
when an item points at them). The "Profile" and "Harness" sections are the PR's: the overlay's files as
`$JIG_PROFILES/<owner>/<repo>/...` and the engine rules as `jig's lib/rules.md`; the terminal printed
their host paths at launch.

````markdown
# Add a health check

Fixes #12

- Repository: /home/you/src/shop
- Branch: jig/add-health-check (2 commits)
- Base: main at 0123456789abcdef0123456789abcdef01234567
- .jig/verify: green
- Agent: exit 0, success, turns: 15, estimated cost $1.23, model: claude-opus-5-5 (default), effort: default
- Duration: 14m 2s in total, agent 11m 40s (limit 60 min)
- Log: `/home/you/.jig/runs/acme/shop/add-health-check/claude.log`
- Plan: `/home/you/.jig/runs/acme/shop/add-health-check/plan.md`

```sh
git -C /home/you/src/shop log --oneline 0123456789abcdef0123456789abcdef01234567..jig/add-health-check
git -C /home/you/src/shop diff 0123456789abcdef0123456789abcdef01234567...jig/add-health-check
```
````

A repository path with spaces or shell characters is quoted in the commands. The terminal ends with a short
summary:

```
jig: ready: jig/add-health-check in /home/you/src/shop
jig: .jig/verify: green
jig: report: /home/you/.jig/runs/acme/shop/add-health-check/report.md
jig: diff: git -C /home/you/src/shop diff 0123456789abcdef0123456789abcdef01234567...jig/add-health-check
```

What makes a draft PR with `deliver pr` makes the run "needs attention" with exit code 1, the reasons
in the first line (`jig: needs attention (.jig/verify red; uncommitted changes): jig/...`) and listed in
the report. A branch that changes `.github/` is kept: nothing is pushed, so your review before the push
is the gate, and a plan that really needs a CI change becomes possible. The change is the first item
under "Needs attention" and the first reason, with each path under `.github/` that a commit touched,
marked when the branch reverts it again; jig exits with code 1.

`report.md` and the plan's copy are scanned for the credential's value like the PR description: if
either holds it, jig deletes the branch and `branch.bundle` and exits with code 3, as when it refuses
to push.

### Smoke

`jig smoke` checks a profile without the agent: it builds the profile from `HEAD` and the overlay as
`jig run` does from the base commit (and prints the same profile lines), clones `HEAD` into
`$JIG_HOME/smoke/<owner>/<repo>/repo`, starts compose project `jig-smoke_<owner>_<repo>`, runs `setup`
and `verify`, and fails if they left changes in the clone. So an overlay profile, or overlay changes not
yet committed, can be checked before a run. The compose project is always removed; the
clone stays until the next smoke. Exit code 0 means green; any other code is the exit code of the step
that failed, and 2 means an invalid call, profile or host, or a `setup` or `verify` that itself exited
with 2 (the output above the last line tells which).

## Logs and what stays on disk

The run directory `$JIG_HOME/runs/<owner>/<repo>/<slug>/` stays after the run:

- `claude.log`: the agent's full output (`stream-json`), where jig finds the outcome, turns, cost and
  models for the agent line;
- `plan.md`: the copy of the plan that the agent read at `/jig/plan.md`;
- `setup.log`, `verify.log`: the environment setup and `verify` (no `verify.log` when the agent made no
  commits);
- `collect.log`: errors of the commands jig uses to take the status, `JIG_BLOCKED.md` and the branch out
  of the container;
- `status.txt`: `git status --porcelain` after the agent;
- `pr-body.md`: the PR description, which names these files as `$JIG_HOME/runs/<owner>/<repo>/<slug>/...`
  instead of host paths; with `deliver branch`, `report.md` instead, with host paths; `summary.md`: the
  agent's final message;
- `branch.bundle`, `branch.patch`: the branch as it left the container, and its diff;
- `branch.objects`: every object of the branch that is not in `base` (`git cat-file --batch`), scanned
  for the credential's value;
- `profile/.jig/`: the profile that compose ran from and that was mounted at `/jig/profile`: `.jig/` of
  the base commit with the overlay's profile files over it;
- `compose.profile.yml`: the compose file jig added for the profile mount and `JIG_BASE`;
- `system-prompt.md`: the engine rules and the overlay rules, as the agent got them;
- `compose.harness.yml`: the compose file jig added for the harness and plan mounts.

The clone `repo/` is gone after the run: it holds the agent's `.git`, whose hooks and config any
git-aware prompt or editor on the host would run. The exception is a Ctrl-C while the clone is still
being created (before the compose project starts): then `repo/` stays; delete it with `rm -rf` without
running git in it or opening it in an editor. Look at `branch.patch`, the logs and `git log -p jig/<slug>`
in the target repository. To run the same slug again, delete the run directory and the branch:
`rm -rf $JIG_HOME/runs/<owner>/<repo>/<slug>`, `git branch -D jig/<slug>` (and the branch on GitHub if
it was pushed).

## Rules the profile cannot change

- The plan is never committed: the agent reads jig's copy at `/jig/plan.md`, read-only.
- `JIG_BLOCKED.md` at the repository root is how the agent says the plan cannot be done.
- The engine rules are in the agent's system prompt in every run.
- `.jig/` and the `setup` and `verify` scripts are protected whatever the `protect` list
  says: a branch that changes them becomes a draft PR, or with `deliver branch` needs attention (exit
  code 1), so the agent cannot turn its own check green by editing it unnoticed.
- Changes under `.github/` are never pushed: `deliver pr` refuses the branch, `deliver branch` pushes
  nothing at all and lists them first under "Needs attention".
- The model credential's value never leaves the run directory unredacted, and a branch carrying it is
  not pushed.

## Known limitations

- Outbound network from the containers is open: the internet, `host.docker.internal` (services on the
  host) and the local network. There is no allow list.
- The agent sees everything in the repository, including any committed test secrets, the whole profile
  at `/jig/profile` (overlay files included), and its own model token in its environment.
- Needs git 2.49 or newer (`git clone --revision`).
- One run at a time; parallel runs are not supported.
- The image is built locally for the host's architecture, and the first build takes minutes; there is no
  build cache or prebuilt image in a registry.
- The agent's limit is 60 minutes by default (`JIG_TIMEOUT`); `verify` after the agent has no limit.
- No follow-up on review comments and no automatic fixing: a new run is a new plan and slug.
- `verify` is repeated on the committed branch, but ignored files (dependency directories, build caches)
  and everything the agent left outside `/workspace` in the container stay as the agent left them and are
  not checked again. A `.gitignore` change committed by the agent can also hide files it left from
  `status.txt`.
- The plan and the agent's final message go into the PR description as is: keywords like `Fixes #12`
  close the issue on merge, and `@name` notifies a person. Read the description before merging.
- Opening the PR (`pull_request`) runs the repository's CI on the branch's code: a workflow that puts
  secrets in the environment of a `pull_request` job runs agent-written code with them. Check the target
  repository's workflows before the first run. Pushing a `jig/*` branch alone triggers only workflows that
  run on any push.

## Tests

`test/profile_test.sh` checks the `.jig/config` parser (`model`, `effort` and `deliver` included), the protected-path matching, loading the
profile from a commit, the overlay's profile files (listed by git in an overlay repository, by the
directory otherwise) and their validation, finding the base on a local bare `origin` (also from an
overlay config, without writing `FETCH_HEAD`), building the profile from both layers, `JIG_BASE` in the profile's compose file, the
profile report with the overlay commit and its warnings per delivery mode, and starting `bin/jig` through a symlink.
`test/harness_test.sh` checks the repository's owner and name taken from the URL of `origin` (the URL
forms, other hosts and malformed names, `.git` among them, refused, the URL never printed) and the `gh` check of `deliver pr`
against a stand-in `gh`, the overlay lookup and its validation (an overlay directory spelled in another case, a relative `JIG_PROFILES`, an
invalid `JIG_MODEL` or `JIG_EFFORT` stops `jig run` before the credential check), the rendered engine
rules for both delivery modes, the delivery mode named at launch, the system prompt, the compose override with the plan mount, the agent's arguments and prompt,
`--model` and `--effort` from the profile and the environment, the agent line's model and effort and what it keeps from the log (values out of shape, more than five other models), the name warnings, the harness report on
the terminal and in the PR, and the PR description (`lib/pr.sh`): the plan block, its fence and where it
is cut, the caps on the agent's texts and lists, the last guard on the description's size, the
issue line read from the plan with its launch text, the refused placeholder and the warnings for Issue
lines that are not read, and the branch lines and the shell-quoted commands of `report.md` and the terminal.
Both need bash and git 2.29 or newer, work offline and leave nothing behind: `bash test/profile_test.sh`,
`bash test/harness_test.sh`.

`test/run_e2e.sh` runs `jig smoke` and fifteen `jig run`s end to end against a local bare repository that
`origin`, `git@github.com:acme/shop.git`, reaches through a fake `ssh` (`GIT_SSH_COMMAND`), with a
fake `claude` mounted over `/usr/local/bin/claude` (it records its arguments and names a model in its
log) and a fake `gh` on `PATH` that records its calls, so it needs no credential and no network. With
`deliver pr`: a clean run with `Fixes #12` and no model or effort, a run without commits and with a
misplaced Issue line, a plan with the
template's `<ref>` left in its Issue line (it stops before anything runs), a run with oversized agent output (a log with control characters in its outcome and 1,000 models among it) and a plan cut inside
its own code fence, a plan whose only heading carries the credential, a branch that changes `.github/`,
and a run with a model and an effort from an overlay config and `JIG_MODEL` and another tracker's issue.
With `deliver branch` from an overlay config, where the fake `gh` fails if it is called at all: a clean
run (the branch in the target checkout, nothing on `origin`, `report.md` and the terminal summary), a
`.github/` change, a `.github/` change reverted inside the branch next to uncommitted changes, a run
without commits, a branch that does not start from the base (no `jig/<slug>` is left in the target), an
uncommitted file named after the credential, which only the report would carry, a plan that carries the
credential, and a log that names the credential as the model (the terminal shows it as `[REDACTED]`).
After clean, refused and stopped runs alike, the target checkout's `FETCH_HEAD` is still the one the
test wrote before them. It also reads made-up
`claude.log`s with `lib/agent-log.js` in the image, values out of shape and past their limits among them. It runs only when
`JIG_E2E_IMAGE` names a local image with bash, git, node and `timeout` (it is never pulled) and Docker is
running, and skips otherwise: `JIG_E2E_IMAGE=<image> bash test/run_e2e.sh`. It needs what `jig run`
needs on the host (git 2.49 or newer) and removes its compose projects and files.
