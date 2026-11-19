# Updating Share to a new Unison release

Share builds against the `unison` git submodule (`./unison`) and is tested with transcripts that run a real `ucm`.
Each time Unison cuts a release (tag `release/X.Y.Z`), Share needs to be moved onto it.
This document is a step-by-step checklist for doing that. Every step has an explicit command and a way to check it worked.

Throughout, `X.Y.Z` is the target Unison version, e.g. `2.0.0`.

## Prerequisites

Run all commands from the repo root. Install the following if they're missing (macOS / Homebrew shown):

| Tool | Install | Used for |
| --- | --- | --- |
| `stack` | `brew install haskell-stack` | building and testing |
| `pg_config`, `pg_isready`, `psql` | `brew install libpq` | `postgresql-libpq` build, transcript scripts |
| `docker`, `docker compose` | see [Docker](#docker-setup-macos) | Postgres, Redis, Vault for transcripts |
| `redis-cli` | `brew install redis` | `make` readiness checks |
| `vault` | `brew install hashicorp/tap/vault` | `make` readiness checks |
| `ucm` at version `X.Y.Z` | https://github.com/unisonweb/unison/releases | transcripts |

Confirm `ucm` matches the target: `ucm --version` must print `release/X.Y.Z`. If it doesn't, install the right one before running transcripts, or the golden files will be wrong.

### `libpq` is keg-only

Homebrew does not put `libpq` on your `PATH`. Without it, `stack build` fails while configuring `postgresql-libpq`
(`pg_config not found`). Prefix every `stack`/`make` command in this document with:

```sh
export PATH=/opt/homebrew/opt/libpq/bin:$PATH
```

### Docker setup (macOS)

Docker Desktop is not required. Colima works and needs no admin prompts:

```sh
brew install colima docker docker-compose
mkdir -p ~/.docker
# Lets `docker compose` find the plugin. Skip if ~/.docker/config.json already exists and has this key.
echo '{"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}' > ~/.docker/config.json
colima start
docker version && docker compose version
```

**If the repo is not under your home directory** (e.g. it lives on an external drive like `/Volumes/T9`), Colima's VM
cannot see it by default, and `docker compose` bind mounts silently fail. The Postgres container then starts with
an *empty* `sql/` init directory, and the otel-collector fails with
`error mounting ".../otel-collector-config.yaml" ... not a directory`. Start Colima with the repo's volume mounted:

```sh
colima stop
colima start --mount "$HOME:r" --mount /Volumes/T9:w   # adjust /Volumes/T9 to wherever the repo lives
colima ssh -- ls "$PWD/docker"                           # must list docker-compose.base.yml etc.
```

## Steps

### 1. Start from a clean branch

```sh
git checkout main && git pull
git status --short            # must be empty
git checkout -b update-unison-X.Y.Z
```

### 2. Move the submodule to the release tag

```sh
git submodule update --init unison      # no-op if already initialized; required if `git submodule status` shows a leading `-`
git -C unison fetch --tags origin
git -C unison checkout release/X.Y.Z
git add unison
```

Check: `git submodule status` shows the commit for the tag, with a leading `+`.
(The parenthesised description may be a nearby tag name rather than `release/X.Y.Z`; that is just `git describe`.
To verify the commit, compare with `git ls-remote --tags https://github.com/unisonweb/unison | grep release/X.Y.Z`.)

Also check `stack.yaml`: it lists `unison/...` packages under `packages:`. If the new release adds, removes or renames
packages that Share depends on, update that list. A missing package shows up as a "package not found" error in step 3.

### 3. Build, and fix API breakage

```sh
export PATH=/opt/homebrew/opt/libpq/bin:$PATH
stack build --fast > /tmp/build.log 2>&1; echo exit=$?
grep -n -A25 " error" /tmp/build.log | head -100
```

The first build compiles the whole dependency tree and takes a long time. Always send output to a file: the real error is
usually far above the final "Stack failed to execute the build plan" message, and filtering or tailing the stream can hide it.

Share's code depends on Unison internals, so a major release usually breaks a few call sites. Fix each in Share's code
(`share-api/`, `share-task-runner/`, `share-utils/`, ...); do **not** edit the `unison/` submodule. Repeat until `exit=0`.

Examples seen in the 1.5.0 -> 2.0.0 upgrade (use as a guide to the kind of change to expect):

- `Unison.Runtime.Interface.startRuntime` gained a `JIT` first argument and dropped its version-string argument.
  In `share-api/src/Share/Env.hs`:
  ```haskell
  import Unison.Runtime.JIT qualified as JIT
  ...
  jit <- JIT.readConfig >>= JIT.newJIT
  sandboxedRuntime <- RT.startRuntime jit True RT.Persistent
  ```
  The JIT is off unless `UNISON_JIT` is set in the environment, so this keeps behaviour unchanged.
- `Unison.Type.F` gained a `Record` constructor, so the exhaustive `case` in
  `share-api/src/Share/BackgroundJobs/Search/DefinitionSync.hs` (`-Werror=incomplete-patterns`) needed a new branch.
  Decide deliberately how a new constructor should be treated for Share's purposes. Here record field types and the extra-fields row are
  indexed like type applications: `Type.Record tail_ fields -> Monoid.foldMapM id (toList tail_ <> Map.elems fields)`.

To see what changed upstream, search the submodule: `git -C unison diff <old-tag> release/X.Y.Z -- <path>` and `grep -rn` for the
function or type named in the compiler error.

### 4. Run the unit tests

```sh
export PATH=/opt/homebrew/opt/libpq/bin:$PATH
stack test --fast > /tmp/test.log 2>&1; echo exit=$?
grep -n "Test suite .* \(passed\|failed\)" /tmp/test.log
```

Check: `exit=0` and every listed suite says `passed`. Note what this covers: Share's own packages have no Haskell tests
(`test-auth-app` only prints "Test suite not yet implemented"). The suites that run are the `unison/*` packages that `stack.yaml` lists.
This step confirms the new Unison builds and passes its own tests, not that Share behaves correctly. Step 5 does that.

This is slow the first time because test builds are configured differently from `stack build`.

### 5. Run the transcripts

Transcripts are Share's real regression tests. They start Postgres/Redis/Vault in Docker, start the Share server, and drive it with
`ucm` and `curl`, writing output files that are committed to git ("golden files").

```sh
export PATH=/opt/homebrew/opt/libpq/bin:$PATH
colima status || colima start     # see Docker setup above for the --mount flags if the repo is outside $HOME
make transcripts > /tmp/transcripts.log 2>&1; echo exit=$?
tail -5 /tmp/transcripts.log      # should end with "Transcripts complete!"
git status --short
```

Notes:

- `make transcripts` tears down any existing containers first and uses a throwaway database. It does not touch the persistent
  `postgresVolume` used by `make serve`.
- To run a subset: `make transcripts pattern=<transcript-dir-prefix>` (directories are under `transcripts/share-apis/`).
- The log contains very long JSON lines. Use `tail -c 3000` or `grep`, not a bare `cat`.
- If a container fails with a mount error, see the Colima `--mount` note under Docker setup.

#### Reviewing changed golden files

Any file modified under `transcripts/` after the run is a behavioural difference. For each one, decide whether it's an expected
consequence of the new Unison release or a regression:

```sh
git diff --stat
git diff transcripts/share-apis/<name>/<file>          # readable text/markdown outputs
```

For JSON files with very long hash lines, a plain diff is unreadable; compare the changed values instead
(e.g. `git diff -U0 <file>` and look at which keys differ).

Typical *expected* changes after a Unison release:

- Entity counts and builtin counts (`Uploaded N entities`, `builtin. (N terms, M types)`) change when builtins are added or removed.
- Namespace/ref hashes (`"hash": "#..."`, `newRefHash`) change when the builtin set changes, since root namespace hashes include them.
- UCM output wording changes (e.g. the `pull` merge-conflict message and its scratch file name).

Anything else (missing fields, changed HTTP statuses, different JSON structure, new errors) should be investigated and
**not** committed until understood. If you can't tell whether a change is expected, ask the maintainer.

Once the changes are judged expected, commit them (see step 8).

### 6. Run the task runner

```sh
export PATH=/opt/homebrew/opt/libpq/bin:$PATH
make task-runner > /tmp/task-runner.log 2>&1; echo exit=$?
tail -c 1500 /tmp/task-runner.log
```

Check: `exit=0`, and the output contains `Starting ambiguous component check task.` then `Finished ambiguous component check task.`
(`No Sentry configuration detected.` is normal locally.)

### 7. Update CI

CI installs a pinned `ucm` for the transcripts. Update it to the same release you used locally, otherwise CI will produce different
golden-file output from what you committed:

```sh
grep -n "releases/download" .github/workflows/ci.yaml
```

In `.github/workflows/ci.yaml`, change the `release%2FX.Y.Z` in the `ucm-linux-x64.tar.gz` download URL to the new version.
Also check any other `ucm` references or version pins in `.github/` and `docker/` (e.g. Dockerfiles).

### 8. Commit

Keep the commits logically separated:

```sh
# Code + submodule
git add unison share-api share-task-runner share-utils share-client stack.yaml   # only the paths you actually changed
git commit -m "Update unison submodule to release/X.Y.Z" -m "<bullet list of API adaptations from step 3>"

# Golden files
git add transcripts
git commit -m "Update transcript outputs for unison X.Y.Z" -m "<what changed and why, from step 5>"

# CI
git add .github/workflows/ci.yaml
git commit -m "Bump CI ucm to release/X.Y.Z"

git status -sb      # must be clean
```

Do not push or open a PR unless asked.

### 9. Clean up local services

```sh
docker compose -f docker/docker-compose.base.yml down
colima stop            # optional, frees the VM's memory
```

## Not part of this process

- `make reset_fixtures` wipes your **local** development database (`docker_postgresVolume`) and re-imports projects from the live Share.
  It's for preparing local dev data, not for validating a Unison upgrade. Do not run it unless the maintainer asks.
- `make serve` is for interactive local development, not testing.

## Quick checklist

- [ ] Branch created, tree clean
- [ ] Submodule on `release/X.Y.Z`, `stack.yaml` package list still valid
- [ ] `stack build --fast` exits 0 (API breakage fixed in Share code, not in `unison/`)
- [ ] `stack test --fast` exits 0, all suites passed
- [ ] `make transcripts` completes; every changed golden file reviewed and judged expected
- [ ] `make task-runner` exits 0 with both task messages
- [ ] CI `ucm` version bumped to X.Y.Z
- [ ] Commits made (code, transcripts, CI); working tree clean
- [ ] Docker services stopped
