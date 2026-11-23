# jig

`jig run <plan>` takes a plan file, has Claude Code implement it in a Docker container and opens a pull
request on the target repository. Code enters the container as a clone and leaves it as a branch; the
container gets no GitHub access, and the only secret jig hands it is the model credential. The profile's
files, the overlay's included, are readable in the container, so they must not hold secrets.

jig is the engine. Each target repository's environment is described by a profile: the repository's
`.jig/` directory, your personal overlay outside the repository, or both (see
[Repository profile](#repository-profile)). What the agent is told comes from the
repository's own instructions, the engine rules and your personal overlay (see [Harness](#harness)).

## Install

1. Docker (Docker Desktop or any Docker with `docker compose`) is running; git 2.49 or newer (`git --version`).
2. `gh auth login`: jig pushes the branch with a plain `git push origin` using the host's git credentials
   (`gh` can serve them as a credential helper) and opens the PR with `gh pr create`. It finds the
   repository's `<owner>/<name>` once, from the `origin` remote (`gh repo view <origin URL>`), and passes
   it as `--repo` to every later `gh` call, so in a fork the PR goes to the fork, never to the upstream
   repository that `gh` would pick on its own.
3. Link `bin/jig` into a directory on `PATH`: `ln -s /path/to/jig/bin/jig ~/.local/bin/jig`. jig
   follows the link (and chains of links) back to its checkout to find `lib/`.
4. Model credential, exactly one variable.

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
| `setup` | required, once | Script that prepares the environment (installs dependencies, creates databases). A path relative to the repository root: parts of latin letters, digits, `.`, `_`, `-` joined by `/`, no `.` or `..` parts, not starting with `-`. jig runs it before the agent starts, with `/workspace` as the working directory: a path under `.jig/` is a profile file and runs as `/jig/profile/<rest>` (see [Paths in the config](#paths-in-the-config)), any other path runs as `./<path>`. |
| `verify` | required, once | The check that decides green or red (tests, linters, build). Same rules as `setup`. The agent is asked to get it green; jig runs it again on the committed branch after the agent. |
| `protect` | any number | Paths the agent must not change. A glob of latin letters, digits, `.`, `_`, `-`, `/` and `*`, not starting with `/`. `*` matches any characters including `/`: `deploy/*` covers everything under `deploy/`, `*/CLAUDE.md` every nested `CLAUDE.md`. A branch that changes a protected path becomes a draft PR. `.jig/`, the `setup` and `verify` scripts and the run's plan `plans/<slug>.md` are always protected and need no line here; `JIG_BLOCKED.md` at the repository root is always allowed. |

An unknown key, a missing required key, a repeated `base`, `setup` or `verify`, or a value outside its
character set stops jig with exit code 2 before anything runs; the message names the file and the line,
for example `jig: origin/main:.jig/config:4: unknown key colour` (or the overlay's `config` with its
path). jig also stops with code 2 when the profile lacks `compose.yml` or a `setup` or `verify` script.

### Paths in the config

A `setup` or `verify` value under `.jig/` names a file of the profile: the overlay's file of that name if
there is one, otherwise the base commit's. jig mounts the whole profile read-only at `/jig/profile` in
the `app` service and runs `.jig/setup` as `/jig/profile/setup`, always with `/workspace` as the
working directory, so a script finds the repository through the working directory, not through its own
path (`cd "$(dirname "$0")/.."` leads to `/jig`). Any other value is a repository file: it must exist
in the base commit and runs as `./<path>` from the clone. The engine rules give the agent the `verify`
command with its working directory, `cd /workspace && /jig/profile/verify` or
`cd /workspace && ./scripts/verify`, so it runs in the right place even after the agent changed directory.

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
key, and parsed with the same rules. So the overlay can replace a `Dockerfile` and nothing else, or hold the whole
profile of a repository that has no `.jig/` at all:

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
or a link to a directory, for example), or a path that is a file in one layer and a directory in the other stops jig with exit
code 2 before anything runs.

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
`$JIG_PROFILES/acme/shop/...` instead of host paths.

### Compose contract

`.jig/compose.yml` has a service `app` that:

- mounts `${JIG_WORKSPACE}` (the clone) at `/workspace` and works there;
- takes the `JIG_UID` and `JIG_GID` build args and runs as a non-root user with that uid and gid, so the
  files it writes in the clone belong to you;
- has `git`, `node`, `claude` (Claude Code) and `timeout` on `PATH`: jig commits the plan with git, runs
  the agent under `timeout` and reads its log with node;
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
the profile at `/jig/profile` (in `jig run` and `jig smoke`), and in `jig run` the harness (see
[Harness](#harness)). Keep that path free in the image.

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
result, do not weaken tests, do not touch the protected paths or `.github/`, never print the
environment, add a dependency only if the plan names it, write the final message as What changes,
Behaviour changes, Not done, How to check (it becomes the PR description), and write `JIG_BLOCKED.md` when
the plan cannot be done. jig fills in the `verify` command with its working directory
(`cd /workspace && ./<path>`, or `cd /workspace && /jig/profile/<rest>` for a path under `.jig/`) and the
run's protected paths: `.jig/*`, the `setup` and `verify` scripts,
`plans/<slug>.md` and the `protect` list of the profile's config, leaving out an entry that an earlier
one already covers; the rules say that `JIG_BLOCKED.md` is allowed even when a
pattern matches it. The draft decision below checks the same list. The prompt itself only names the plan
file.

### Personal overlay

The overlay holds harness and profile files you are trying out before they move into the repository
(profile files: see [Profile files from the overlay](#profile-files-from-the-overlay)). Its root is
`JIG_PROFILES` (an absolute path, `$JIG_HOME/profiles` by default, so `~/.jig/profiles`); keep it as a
private git repository of its own. Each target repository has a directory `<owner>/<repo>/` there, named
like its run directories (the GitHub owner and name as `gh repo view` reports them):

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
`compose.yml`, so the profile needs no change. It mounts `system-prompt.md` at `/jig/system-prompt.md`
and `plugin/` at `/jig/overlay` in `app`, both read-only and outside `/workspace`, and starts the agent
with `--append-system-prompt-file /jig/system-prompt.md` and, when there is a plugin,
`--plugin-dir /jig/overlay`. The plugin directory is mounted as it is on disk, so edits to it during a
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
branch `jig/<slug>` and the file `plans/<slug>.md` in the branch. The file can live anywhere and does not
need to be committed to `base`: jig puts the plan in as the first commit of the branch. The plan's
`# ...` heading becomes the PR title.

## Usage

```sh
cd ~/src/shop
jig smoke                                          # build the image, run setup and verify on HEAD
jig run plans/add-health-check.md
JIG_TIMEOUT=30 jig run plans/add-health-check.md   # the agent's limit in minutes, 60 by default
jig run ~/plans/add-health-check.md --repo ~/src/shop
```

`--repo` defaults to the git checkout of the current directory. The plan path is relative to the
current directory. `JIG_HOME` (an absolute path, `~/.jig` by default) holds run and smoke directories;
`JIG_PROFILES` (an absolute path, `$JIG_HOME/profiles` by default) is the overlay root.

What `jig run` does: precondition checks → the overlay lookup → the base and the profile (`.jig/` of
`origin/<base>` with the overlay's profile files over it) → the profile and harness sources printed →
the profile, the system prompt and the compose overrides written to the run directory → a
clone of that commit in `$JIG_HOME/runs/<owner>/<repo>/<slug>/repo` → compose project
`jig-run_<owner>_<repo>_<slug>` (no ports on the host; owner and repo lowercased, characters other than
latin letters, digits and `-` turned into `-`) → the plan commit and `setup` in the container →
`claude -p` under the time limit → the branch leaves the container as a bundle → uncommitted changes are
discarded (`git checkout -f`, `git clean -fd`, also in the middle of an abandoned merge or rebase) and
`verify` runs on the committed branch → `docker compose down -v` (always: on errors and on Ctrl-C, even a
repeated one) and removal of the clone → on the host: fetch the branch, check it, `git push origin`,
`gh pr create --base <base>`.

The PR is opened as a draft if `verify` is red, the time limit hit, the agent exited with an error, left
`JIG_BLOCKED.md` or uncommitted changes, changed a protected path (`.jig/`, the `setup` and `verify`
scripts, the plan file, and the `protect` list of the profile's config; `JIG_BLOCKED.md` is never one), or
changed nothing but the plan. The reasons are listed in the PR description under "Needs attention".

jig pushes nothing (exit code 3, the local branch `jig/<slug>` is deleted):

- if the model credential's value is found in the objects that would be pushed (`branch.objects`: whole
  commits with any headers, trees and files), in the branch diff (`branch.patch`), in the agent's final
  message, in an uncommitted `JIG_BLOCKED.md` or in the PR description; `branch.bundle` is then deleted;
- if the branch touches `.github/` in any commit or in its final diff against `base` (a pushed workflow
  would run with the repository's secrets and write access). The credential is checked first, so a branch
  with both `.github/` and the token loses `branch.bundle` too.

A commit with a NUL byte fails fsck when the branch is fetched from the bundle: that is also exit code 3
without a push, but `branch.bundle` stays. If the value is found only in local files of the run
directory (`claude.log` and others), jig replaces it there with `[REDACTED]` and deletes a file it could
not clean; either way it warns loudly which files were affected and goes on.

Exit codes of `jig run`:

| Code | Meaning |
|---|---|
| 0 | the PR is open and ready for review |
| 1 | the PR is open as a draft |
| 2 | invalid call, invalid profile or an unmet precondition; nothing ran |
| 3 | a failure or a refusal to push before the PR was opened; the message says where to look, the run directory is kept |
| 130 | interrupted by Ctrl-C at any step after the preconditions; logs are kept, the compose project is removed and the clone deleted, except for a Ctrl-C while cloning (see below) |

Code 1 means only "the PR is a draft", 130 only Ctrl-C (or SIGTERM): a repeated Ctrl-C while the
project is being removed does not interrupt `docker compose down`.

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

- `claude.log`: the agent's full output (`stream-json`);
- `setup.log`, `verify.log`: the environment setup and `verify`;
- `collect.log`: errors of the commands jig uses to take the status, `JIG_BLOCKED.md` and the branch out
  of the container;
- `status.txt`: `git status --porcelain` after the agent;
- `pr-body.md`: the PR description; `summary.md`: the agent's final message;
- `branch.bundle`, `branch.patch`: the branch as it left the container, and its diff;
- `branch.objects`: every object of the branch that is not in `base` (`git cat-file --batch`), scanned
  for the credential's value;
- `profile/.jig/`: the profile that compose ran from and that was mounted at `/jig/profile`: `.jig/` of
  the base commit with the overlay's profile files over it;
- `compose.profile.yml`: the compose file jig added for the profile mount;
- `system-prompt.md`: the engine rules and the overlay rules, as the agent got them;
- `compose.harness.yml`: the compose file jig added for the harness mounts.

The clone `repo/` is gone after the run: it holds the agent's `.git`, whose hooks and config any
git-aware prompt or editor on the host would run. The exception is a Ctrl-C while the clone is still
being created (before the compose project starts): then `repo/` stays; delete it with `rm -rf` without
running git in it or opening it in an editor. Look at `branch.patch`, the logs and `git log -p jig/<slug>`
in the target repository. To run the same slug again, delete the run directory and the branch:
`rm -rf $JIG_HOME/runs/<owner>/<repo>/<slug>`, `git branch -D jig/<slug>` (and the branch on GitHub if
it was pushed).

## Rules the profile cannot change

- The first commit of the branch adds exactly `plans/<slug>.md`, as jig copied it; the plan cannot
  already exist on `base`.
- `JIG_BLOCKED.md` at the repository root is how the agent says the plan cannot be done.
- The engine rules are in the agent's system prompt in every run.
- `.jig/`, the `setup` and `verify` scripts and the plan file are protected whatever the `protect` list
  says: a branch that changes them becomes a draft PR, so the agent cannot turn its own check green by
  editing it.
- Changes under `.github/` are never pushed.
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
- The agent's final message goes into the PR description as is: keywords like `Fixes #12` close the issue
  on merge, and `@name` notifies a person. Read the description before merging.
- Opening the PR (`pull_request`) runs the repository's CI on the branch's code: a workflow that puts
  secrets in the environment of a `pull_request` job runs agent-written code with them. Check the target
  repository's workflows before the first run. Pushing a `jig/*` branch alone triggers only workflows that
  run on any push.

## Tests

`test/profile_test.sh` checks the `.jig/config` parser, the protected-path matching, loading the
profile from a commit, the overlay's profile files (listed by git in an overlay repository, by the
directory otherwise) and their validation, finding the base on a local bare `origin` (also from an
overlay config), building the profile from both layers, the profile report with the overlay commit, and
starting `bin/jig` through a symlink. `test/harness_test.sh` checks the
overlay lookup and its validation (a relative `JIG_PROFILES` stops `jig run` before the credential check),
the rendered engine rules, the system prompt, the compose override, the agent's arguments, the name
warnings and the harness report on the terminal and in the PR.
Both need bash and git 2.28 or newer, work offline and leave nothing behind: `bash test/profile_test.sh`,
`bash test/harness_test.sh`.
