# Updating Share to a new Unison release

Share builds against the `unison` git submodule (`./unison`) and is tested with transcripts that run a real `ucm`. Each time Unison cuts a release (tag `release/X.Y.Z`), Share needs to be moved onto it.
This document is a step-by-step checklist for doing that, from preparing the change locally through to deploying it. Every step has an explicit command and a way to check it worked.

Steps 1-9 only affect your local machine. Steps 10-18 (push, PR, merge, image, jobs repo, backup, migrations, deploy, rollback) touch shared
and production systems. If you are a software agent, be sure to ask for explicit approval from the user before each is run.

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

Stop here unless you have been given explicit approval for the next phase. Steps 1-8 only affect your local machine.
Everything from step 9 onwards touches shared systems (GitHub, the container registry, production), so each of
those steps needs **explicit approval from the user or maintainer before it is run**. Ask first; don't assume that approval
for one step covers the next.

### 9. Clean up local services

```sh
docker compose -f docker/docker-compose.base.yml down
colima stop            # optional, frees the VM's memory
```

## Shipping the release

These steps publish and deploy the change. They require explicit approval (see above) and credentials the agent may not have
(GitHub, AWS, Nomad). If you are an agent following these instructions and lack access to something, stop and tell the user exactly what's left to do rather than guessing!

### Setup for shipping

Before step 14 you need:

- `gh` logged in to GitHub with push access to `unisonweb/share-api` and the `jobs` repo (`gh auth status`).
- The Nomad CLI: `brew install hashicorp/tap/nomad`, then check `nomad version`. The `jobs` repo's `flake.nix` pins Nomad 1.8; if `nomad plan` or
  `nomad run` behaves oddly with a newer CLI, a version mismatch is a suspect.
- **Tailscale, connected.** The Nomad cluster is only reachable over the company tailnet. Its hostname resolves to private
  `172.20.x.x` addresses, so without Tailscale every Nomad command just times out.
  ```sh
  /Applications/Tailscale.app/Contents/MacOS/Tailscale status   # the `tailscale` CLI may not be on PATH on macOS; this path is the app's bundled CLI
  ```
  It should list peers (for example `bastion-us-west-2-1`) and not report being stopped or logged out. If it isn't connected, ask
  the user to connect it; you can't do that for them.
- The Nomad environment, which comes from the `jobs` repo rather than from installing the CLI. `jobs/.envrc` sets `NOMAD_ADDR`
  (`http://nomad.us-west-2.unison-lang.org:4646`), `VAULT_ADDR`, `CONSUL_HTTP_ADDR` and `LOKI_ADDR`. Load it with
  [direnv](https://direnv.net) (`brew install direnv`, then `direnv allow` inside the `jobs` checkout), or without direnv:
  ```sh
  cd <jobs checkout> && source ./.envrc && echo $NOMAD_ADDR
  ```
  `.envrc` also sources an optional, uncommitted `./.envrc.private`. Put any personal secrets there, such as a `NOMAD_TOKEN`.
  Never commit tokens or paste them into logs or PRs. Nothing in the `jobs` repo mentions TLS variables
  (`NOMAD_CACERT`, etc.); the address is plain HTTP over the tailnet.

  **A `NOMAD_TOKEN` is required.** Even read-only commands like `nomad status` are rejected without one
  (`Error querying jobs: Unexpected response code: 403 (Permission denied)`), and `nomad run` needs a token with permission to run jobs
  in production. Put it in `./.envrc.private` in the `jobs` checkout as `export NOMAD_TOKEN=...`. If you don't have one, stop immediately. Don't try to work around the 403.

  > **TODO:** say where tokens are issued and which policy/role a deployer needs.

- Check that you can reach the cluster before you need it (with Tailscale connected and the environment loaded):
  ```sh
  curl -s -m 5 "$NOMAD_ADDR/v1/status/leader"   # prints the cluster leader's address (HTTP 200)
  nomad status                                  # read-only: lists jobs; a 403 "Permission denied" means the token is missing or insufficient
  ```
  A timeout means Tailscale is off or not routing to the cluster. A 403 means a missing or insufficient `NOMAD_TOKEN`.
  In either case you can't deploy; stop and tell the user what failed.
- Access to the AWS console for the Postgres backup in step 15, and to the production database for any migrations in step 16.

### 10. Push and open a PR

```sh
git push -u origin update-unison-X.Y.Z
gh pr create --base main --head update-unison-X.Y.Z --title "Update unison submodule to release/X.Y.Z" --body "<summary, testing done, anything not run>"
```

In the PR description, list the code adaptations, which golden files changed and why, and what you did and did not test
(e.g. that `make reset_fixtures` was not run).

### 11. Get CI passing

CI must be green before anything is merged. Check with `gh pr checks <PR number>`. The CI `ucm` pin was already bumped in step 7,
and that is the part you can't verify locally, so look closely at the transcript job. If CI fails, fix the cause on the
branch and push again. Don't merge with a red CI, and don't "fix" a failure by committing different golden files unless you've
reviewed the diff the way step 5 describes.

### 12. Merge to `main`

Use a **merge commit** (not squash or rebase), which keeps the separate code / transcripts / CI / docs commits in history:

```sh
gh pr merge <PR number> --merge
git checkout main && git pull
git log --oneline -5       # confirm the merge is on main
```

### 13. Find the image that CI published

A CI step builds and publishes a container image to the repo's Packages tab:
https://github.com/unisonweb/share-api/pkgs/container/share-api

Tags look like `main_2026-10-05-19-11_gitref-e1dc80b`: the branch, a timestamp, and the short git hash of the commit that was built.

**Why you have to wait for a second CI run, even though CI already passed on the PR.** The same workflow behaves differently depending
on what triggered it (see `is_published_build` in `.github/workflows/ci.yaml`):

- On a **pull request**, CI builds with `stack build --fast` (unoptimized) and builds the Docker image but does **not** push it. Its
  computed tag has no branch name in it and uses the PR's merge-ref hash, and it is never published. There is nothing to deploy from a PR run.
- On a **push to `main`** (or `staging`), CI builds with `-O2` (the optimized production binary) and **pushes** the image to the registry.
  Only this run produces an image you can deploy.

So merging the PR starts a new run on `main`, and its image is the one you want. That run compiles with `-O2`, so expect it to take
at least as long as the PR run (about 45 minutes with a cold cache, and possibly longer). Don't poll it in a loop; check back when it should
be done, or when the user says it is.

1. Wait for CI on `main` (the run triggered by your merge) to finish. Find it with `gh run list --branch main --limit 3`, and make sure the
   run's commit is your merge commit and its conclusion is `success`.
2. Open the Packages page and find the newest tag.
3. Confirm it is the build you expect: the `gitref-` hash must match the merge commit you just made, and the timestamp must be after the merge.
   ```sh
   git rev-parse --short=7 origin/main
   ```
   The example tag starts with `main_`, so use the build from `main`, not one from a feature branch.
4. Copy the full tag. Do not use a tag from an earlier run just because it looks similar.

### 14. Update the tag in the jobs repo

Deployment config lives in a separate repo: https://github.com/unisoncomputing/jobs

1. Clone it and open `share.hcl`.
2. Find the `share_docker_image_tag` variable at the top of the file. Its `default = "..."` line holds the tag that production runs.
   **Write down the old tag before you change it.** You need it for the migration check in step 16 and for rolling back in step 18.
   The `gitref-` part of that tag is the short hash of the `share-api` commit currently deployed.
3. Replace the tag with the one from step 13. Change nothing else.
4. Don't run anything yet. Do the backup and migration checks below first.

Notes about this repo:

- The `jobs` repo's default branch is `trunk`, not `main`. If you open a PR for the tag change, use `--base trunk`
  (`gh pr create --base trunk ...`); `--base main` fails with "Base ref must be a branch". The PR description should give the old and
  new tags, the backup/migration status, and the deploy and rollback commands.
- Production is deployed directly. There is no staging-first step in this process (`share-staging.hcl` exists, but it isn't used for this).
- The `jobs` README says to take a build number from Drone. That is out of date. Use the ghcr tag from step 13, as the comment in `share.hcl` says.
- Don't touch `share-task-runner.hcl` or the jobs under `migrations/`. See "Not part of this process" below.

### 15. Back up Postgres

Take a Postgres backup before deploying anything that would affect the data stored in the database. Do this from the Amazon (AWS) Postgres dashboard.

> **TODO:** this document doesn't yet say exactly where in the AWS console to take the backup or who has
> permission.

### 16. Check the new code against the existing production data, and apply any migrations

Production holds data written by the *old* code. Before deploying, think through everything the new code expects of the old codebase and database, and perform any Postgres migrations that are needed.

- **Check whether `sql/` changed since the version that production runs.** Take the `gitref-` hash from the *old* tag you wrote down in
  step 14 (for example `3fd7c03`) and diff against the commit you're deploying:
  ```sh
  git cat-file -t <old-gitref>                          # must print "commit"; if not, `git fetch origin` first
  git diff --stat <old-gitref> origin/main -- sql       # empty output = no schema changes to apply
  git log --oneline <old-gitref>..origin/main -- sql    # which commits touched it, if any
  ```
  If this is empty, there are no SQL migrations to apply. Say so in your report. If it shows files, those are the migrations to apply, in
  timestamp order, and you must apply them **before** deploying. For the 2.0.0 upgrade this check was empty.
- Think about what the Unison upgrade changes about stored data: any changes to serialization or hashing formats, codebase / sync
  versions, or anything else the new Unison libraries read or write that old rows might not satisfy. Read the upstream release notes
  for the Unison release.
- Schema changes are applied by hand. Everything needed is in `sql/`, ordered by timestamp, and you copy-paste the SQL into a
  Postgres terminal session. See "Managing Postgres Migrations" in the README.
- Run migrations inside a transaction so you can abort if something goes wrong:
  ```
  > BEGIN;
  > <run migrations>
  > COMMIT;
  ```

If you aren't sure whether a migration is needed, or you don't have production database access, stop and ask for help. Don't deploy.

### 17. Deploy

ONLY after steps 15 and 16 are complete, and with explicit approval, from the root of your `jobs` checkout (with Nomad configured for the cluster):

```sh
nomad run ./share.hcl
```

Then check that the new job version is running (Nomad UI or `nomad job status`) and that Share is healthy.

### 18. Rolling back

> **Verify with a maintainer.** This is the expected shape of a rollback, not a tested runbook.

- **Code only (no migrations were applied):** set the image tag in `share.hcl` back to the previous tag (find it in the git
  history of `jobs`, or from the Packages page) and run `nomad run ./share.hcl` again.
- **Migrations were applied:** reverting the image alone may not be safe because the old code might not work with the new schema.
  Decide with a maintainer whether to run a reverse migration or restore the backup from step 15 before redeploying the old image.
  Restoring a backup discards writes made since it was taken, so don't do it without approval.

## Not part of this process

- **`share-task-runner.hcl` in the `jobs` repo.** The task runner is a separate one-off batch job (it runs checks such as the ambiguous
  component check). Its image is only built from branches named `task-*`, never from `main`, so merging to `main` doesn't produce one.
  It doesn't need updating for a Unison release. Only run or bump it when someone wants to rerun that check in production.
  (`make task-runner` in step 6 only verifies that the task runner still works locally.)
- **The jobs under `migrations/` in the `jobs` repo** (`share-prod-migration.hcl`, `share-staging-migration.hcl`). These are batch jobs
  that use `ENLIL_*` variables and an old ECR image (Enlil is a former name of Share). They look like legacy tooling and are not how
  Postgres schema changes are applied. Don't run them as part of a Unison upgrade. Schema changes are the SQL files in `sql/` (step 16).

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
- [ ] *(approval needed from here on)* Branch pushed, PR opened
- [ ] CI green on the PR
- [ ] PR merged to `main` with a merge commit
- [ ] Image tag found on the Packages page; its `gitref-` hash matches the merge commit
- [ ] Tag updated in `share.hcl` in the `jobs` repo
- [ ] Postgres backup taken
- [ ] Old-data expectations reviewed, migrations applied if needed
- [ ] `nomad run ./share.hcl` done and the new version verified
