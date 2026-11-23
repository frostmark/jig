# jig

`jig run <plan>` takes a plan file, has Claude Code implement it in a Docker container and opens a pull
request on the target repository. Code enters the container as a clone and leaves it as a branch; the
container gets no GitHub access and no secrets other than the model credential.

jig is the engine. Each target repository describes its own environment in a profile, the `.jig/`
directory (see [Repository profile](#repository-profile)).

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

A repository is ready for jig when it has `.jig/config`. The profile is:

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
| `setup` | required, once | Script that prepares the environment (installs dependencies, creates databases). A path relative to the repository root: parts of latin letters, digits, `.`, `_`, `-` joined by `/`, no `.` or `..` parts, not starting with `-`. jig runs it as `./<path>` in `/workspace` before the agent starts. |
| `verify` | required, once | The check that decides green or red (tests, linters, build). Same rules as `setup`. The agent is asked to get it green; jig runs it again on the committed branch after the agent. |
| `protect` | any number | Paths the agent must not change. A glob of latin letters, digits, `.`, `_`, `-`, `/` and `*`, not starting with `/`. `*` matches any characters including `/`: `deploy/*` covers everything under `deploy/`, `*/CLAUDE.md` every nested `CLAUDE.md`. A branch that changes a protected path becomes a draft PR. `.jig/` and the `setup` and `verify` scripts are always protected and need no line here. |

An unknown key, a missing required key, a repeated `base`, `setup` or `verify`, or a value outside its
character set stops jig with exit code 2 before anything runs; the message names the file and the line,
for example `jig: origin/main:.jig/config:4: unknown key colour`. jig also stops with code 2 when the
commit lacks `.jig/compose.yml` or the `setup` or `verify` script.

### Where jig reads the profile from

- `jig run` reads it from the base commit on `origin`, never from your working tree or local branches.
  It asks `origin` for its default branch (`git ls-remote --symref origin HEAD`), fetches it into
  `origin/<branch>` (whatever that ref held before is overwritten, so a stale one is never used) and reads
  `.jig/config` there. If `base` names another branch, jig fetches that branch and reads the profile
  again from it; that copy must name itself as `base`.
- `jig smoke` reads it from the `HEAD` commit of the checkout: commit profile changes before checking them.

jig extracts `.jig/` of that commit into the run directory (`git archive`) and runs `docker compose`
from the copy, so neither uncommitted files on the host (a local `.jig/.env` included) nor the agent's
edits in the clone feed the compose project. The copy holds only `.jig/`: `build.context: .` and relative
mounts in `compose.yml` see `.jig/` and nothing else of the repository, so a Dockerfile cannot `COPY`
repository files (lockfiles, for example). Repository code reaches the container only through the
`${JIG_WORKSPACE}` mount.

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

Other services (a database, a cache) are the profile's business. No ports need to reach the host. The
compose file runs on the host's Docker, so whoever can merge into `base` decides what the containers get
(mounts, privileges); review `.jig/` changes like CI changes.

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
current directory. `JIG_HOME` (an absolute path, `~/.jig` by default) holds run and smoke directories.

What `jig run` does: precondition checks → the profile from `origin/<base>` → a clone of that commit in
`$JIG_HOME/runs/<owner>/<repo>/<slug>/repo` → compose project `jig-run_<owner>_<repo>_<slug>` (no ports
on the host; owner and repo lowercased, characters other than latin letters, digits and `-` turned into
`-`) → the plan commit and `setup` in the container → `claude -p` under the time limit → the branch
leaves the container as a bundle → uncommitted changes are discarded (`git checkout -f`, `git clean -fd`,
also in the middle of an abandoned merge or rebase) and `verify` runs on the committed branch →
`docker compose down -v` (always: on errors and on Ctrl-C, even a repeated one) and removal of the clone →
on the host: fetch the branch, check it, `git push origin`, `gh pr create --base <base>`.

The PR is opened as a draft if `verify` is red, the time limit hit, the agent exited with an error, left
`JIG_BLOCKED.md` or uncommitted changes, changed a protected path (`.jig/`, the `setup` and `verify`
scripts, and the `protect` list of the base commit), or changed nothing but the plan. The reasons are
listed in the PR description under "Needs attention".

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

`jig smoke` checks a profile without the agent: it clones `HEAD` into
`$JIG_HOME/smoke/<owner>/<repo>/repo`, starts compose project `jig-smoke_<owner>_<repo>`, runs `setup`
and `verify`, and fails if they left changes in the clone. The compose project is always removed; the
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
- `profile/.jig/`: the copy of the profile that compose ran from.

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
- `.jig/` and the `setup` and `verify` scripts are protected whatever the `protect` list says: a branch
  that changes them becomes a draft PR, so the agent cannot turn its own check green by editing it.
- Changes under `.github/` are never pushed.
- The model credential's value never leaves the run directory unredacted, and a branch carrying it is
  not pushed.

## Known limitations

- Outbound network from the containers is open: the internet, `host.docker.internal` (services on the
  host) and the local network. There is no allow list.
- The agent sees everything in the repository, including any committed test secrets, and its own model
  token in its environment.
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
profile from a commit, finding the base on a local bare `origin`, and starting `bin/jig` through a
symlink. It needs bash and git 2.28 or newer, works offline and leaves nothing behind:
`bash test/profile_test.sh`.
