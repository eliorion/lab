# Bitbucket project migration — 7.21.10 ➜ 4.14.2 (with Git LFS)

Scripts that copy **all repositories of one Bitbucket project** to a project on another
Bitbucket server: every branch, every tag and **every Git LFS object** (of all branches,
tags and the whole history), plus the default branch and the LFS setting.

Bitbucket's built-in project export/import cannot do this migration: it needs a Data Center
license and a target version ≥ the source version. So these scripts copy the data with
git + git-lfs and use the REST API to create the repositories.

**The source server is never modified.** The scripts only read from it, so every repository
stays on the old server and you end up with the same repository on both servers. This is
enforced in the code: any request that could write to the source is refused. Use a read-only
token and Bitbucket itself makes writes impossible.

```
.
├── .env.example          configuration template (copy to .env)
├── .env                  YOUR configuration and credentials (git-ignored)
├── scripts/
│   ├── 01-check-connections.sh   read-only checks of everything (run first)
│   ├── 02-test-single-repo.sh    migrates ONE repository as a test copy + deep verification
│   ├── 03-migrate-project.sh     migrates the whole project (resumable)
│   ├── 04-verify-project.sh      proves the target is an exact copy of the source
│   ├── watch-progress.sh         live view of a running migration (second terminal)
│   └── lib/                      shared code (config, REST, JSON parser, migration logic)
└── output/               EVERYTHING the scripts create (git-ignored), see section 7
```

## 1. Requirements on the machine running the scripts

| Tool | Version | Note |
|---|---|---|
| bash | ≥ 4 | Linux, Git Bash on Windows; on macOS install a newer bash (`brew install bash`) |
| git | ≥ 2.31 | |
| git-lfs | ≥ 2.10 (3.x recommended) | `git lfs version` |
| curl, grep, awk, sed, sort, … | any | standard tools; **jq and python are not needed** (JSON is parsed with grep + awk) |

You also need HTTPS access to both servers, and enough free disk space for the biggest
repository plus its LFS objects (each repository is deleted locally after its migration).
`01-check-connections.sh` checks all of this.

## 2. Credentials: HTTP access token or username/password?

| Server | Use | Why |
|---|---|---|
| **Source 7.21.10** | **HTTP access token** (`SOURCE_AUTH_TYPE=bearer`), recommended | Tokens exist since 5.5. A read-only token cannot modify anything, you can revoke it after the migration, and your password is not stored in `.env`. Username/password (`basic`) also works. |
| **Target 4.14.2** | **Username + password** (`TARGET_AUTH_TYPE=basic`) | 4.14 has no personal access tokens (they arrived in 5.5): basic authentication is the only option. With LDAP/AD, use your LDAP password. |

To create the token on 7.21: avatar ➜ **Manage account** ➜ **HTTP access tokens** ➜ **Create token**.
- Permissions: **Project read + Repository read** is enough.
  **Repository admin** also lets the scripts read each repository's "LFS enabled" flag. Without it the scripts still find the LFS objects; they just scan every repository.
- Set an expiry date that covers the whole migration window.

Notes:
- After a few failed logins, Bitbucket asks for a CAPTCHA, and basic auth keeps failing until you log in once through the web UI. The scripts say so when it happens.
- Credentials never appear on a command line or in a `.git/config`. curl reads them from a private temporary file that is deleted at exit, and git/git-lfs receive them as HTTP headers through environment variables. Your own git credential helpers are ignored during the migration.
- Run `chmod 600 .env`.

## 3. Permissions needed

- **Source**: read access to the project and its repositories (as system admin you have it).
- **Target**: **PROJECT_ADMIN on the target project**. That is enough to create repositories, enable Git LFS on them, set the default branch and delete the test copy. Nothing more is needed, but:
  - the target project must **already exist** (project admins cannot create projects);
  - Git LFS must be enabled on the target **server** (a system-admin setting). The server also needs disk space for all LFS objects;
  - project-level branch permissions or hooks on the target can reject the initial push. `01` warns about branch restrictions.

## 4. Setup

```bash
cp .env.example .env     # only if .env does not exist yet
chmod 600 .env
```

Fill in `.env`. Every setting is documented in the file. The minimum is `SOURCE_URL`,
`SOURCE_PROJECT_KEY`, `SOURCE_TOKEN`, `TARGET_URL`, `TARGET_USERNAME` and `TARGET_PASSWORD`.
URLs are the base URLs as seen in the browser, including a context path such as
`/bitbucket` if there is one. Leave `TARGET_PROJECT_KEY` empty to use the same project key
as the source, or set it if the key is different on the new server.

Values are taken literally (no `$` expansion), so passwords with special characters work.
Wrap a value in single quotes only if it contains ` #` (space + hash).

## 5. Workflow

**Step 1: checks (read-only, changes nothing)**
```bash
scripts/01-check-connections.sh          # add --quick to skip the per-repository inventory
```
This checks tools, configuration, both servers (reachability, version, login, identity),
read access to the source project, PROJECT_ADMIN on the target project, name collisions,
git over HTTPS and the LFS API. It also writes an inventory of every source repository
(LFS flag, size) to `logs/<run>/inventory.csv`. Fix every `ERROR` before going further.

**Step 2: test on one repository** (choose one that uses LFS, ideally a big one)
```bash
scripts/02-test-single-repo.sh --list           # repositories, LFS ones first
scripts/02-test-single-repo.sh my-repo
```
This creates `<name>-migration-test` on the target, so it never collides with the real
migration. It migrates the repository, then verifies it: refs identical, every LFS object
present (LFS API), and a *round trip*, i.e. a fresh copy fetched back from the target with
all LFS objects downloaded again and compared. At the end it offers to delete the test copy
(`--delete` / `--keep` to decide in advance). The timing gives you an idea of the throughput.

**Step 3: migrate the project**
```bash
scripts/03-migrate-project.sh --dry-run    # what would be done
scripts/03-migrate-project.sh              # asks for confirmation (-y to skip)
```
Repositories are migrated one by one, each one verified. Follow it live from a second
terminal with `scripts/watch-progress.sh` (see section 7). The run is **resumable**: every
successful repository is recorded in `state/<SRC>_to_<TGT>.done`, so after an error, a
network cut or Ctrl-C you **just run the same command again**. The run stops by itself
after `MAX_CONSECUTIVE_FAILURES` failures in a row (server down, expired password…).
Useful options: `REPO_EXCLUDE` in `.env`, `-f list.txt` or slugs on the command line to
migrate only some repositories, `--no-resume`.

**Step 4: prove that the target is an exact copy**
```bash
scripts/04-verify-project.sh                  # fast: branches, tags, default branch, LFS flag
scripts/04-verify-project.sh --deep           # + full download from the target + every LFS object
scripts/04-verify-project.sh --download-lfs   # + downloads every LFS file again (sha256 checked)
```
Branches and tags are compared by their git id. A git id is a SHA hash of the content
**and** the whole history, so the same id on both servers means byte-for-byte the same
repository. `--deep` also downloads every repository from the target (git checks every
object) and asks the target, for every LFS object referenced anywhere in the history,
whether it has it with the right size. An LFS object missing on the source server too is
reported separately: it cannot be migrated.

**Step 5: cut-over (if people keep working during the migration)**
1. make the source project read-only (e.g. remove the write permissions on the project);
2. `scripts/03-migrate-project.sh --sync` pushes what changed on the source since the first copy;
3. `scripts/04-verify-project.sh --deep` must report every repository as identical;
4. developers switch their clones: `git remote set-url origin <new clone URL>`.

About `--prune` (off by default): it never deletes a repository and never touches the
source. If a branch or tag was **deleted on the source** after the first copy, the target
copy still has it, and `04` reports the repository as not identical. `--sync --prune`
removes that branch/tag from the **target copy only**, so it matches the source again.
Without `--prune` it stays on the target. Nothing is needed if the source is frozen
before the first copy.

## 6. What is migrated / not migrated

| Migrated | Not migrated |
|---|---|
| all branches and tags (annotated too) | pull requests, their comments and approvals |
| all Git LFS objects, whole history | repository / branch permissions, branch restrictions |
| default branch | webhooks, hooks and their settings, branch model |
| "forkable" flag (`public` optional: `COPY_PUBLIC`) | repository descriptions, fork relationships |
| Git LFS enabled on the target repository | `refs/pull-requests/*` (Bitbucket rejects them), personal repositories |

## 7. The `output/` folder and live progress

Everything the scripts create goes into `output/` (`OUTPUT_DIR` in `.env`):

```
output/
├── STATUS.txt                         live status of the current / last run
├── logs/<date>-<script>/
│   ├── main.log                       everything printed on screen
│   ├── report.csv                     migrate/test: one line per repository (status, branches,
│   │                                  tags, LFS objects/bytes, duration, message), filled live
│   ├── failures.tsv                   failed repositories and the reason
│   ├── inventory.csv                  check: source repositories, LFS flag, size
│   ├── verify.csv, verify-details.log verify: comparison source vs target
│   └── repos/<slug>.log               every git / git-lfs command of one repository + its output
│       repos/<slug>.lfs-progress      one line per LFS file transferred
├── state/<SRC>_to_<TGT>.done          repositories already migrated (used to resume;
│                                      delete a line to migrate that repository again)
└── work/                              temporary local copies, each deleted after its repository
```

**Watching a run live**: in a second terminal (or over ssh) run

```bash
scripts/watch-progress.sh            # refreshes every 2 s, stops when the run ends
scripts/watch-progress.sh -n 10      # every 10 s
scripts/watch-progress.sh --once     # print once (e.g. from cron or a script)
```

```
state        : RUNNING
progress     : 37/212 repositories done (17%)   OK 35   skipped 1   failed 1
elapsed      : 0h42m10s   ETA ~3h18m00s
current repo : [38/212] my-repo   (since 22:18:12)
current step : uploading 120 LFS objects (1.2 GB) to the target

live transfer:
  lfs : LFS upload: file 57 of 120, 512.4 MB / 1.2 GB

last finished repositories:
  OK                   other-repo
  ...
```
`output/STATUS.txt` is a plain text file, so `cat output/STATUS.txt` works too.

## 8. Troubleshooting

| Message | Cause / fix |
|---|---|
| `credentials rejected` / `HTTP 401` | wrong user/password/token, CAPTCHA (log in once in the browser), expired token |
| `unexpected answer … application-properties` / `HTTP 404` | wrong URL or missing context path (`/bitbucket`) |
| `network/TLS error` | internal CA: set `*_CA_BUNDLE` to the CA's PEM file. A very old server that only speaks TLS 1.0/1.1 is refused by recent curl/OpenSSL: ask the admins |
| `you are not PROJECT_ADMIN` | ask the target admins for project admin on the target project |
| `cannot enable Git LFS on the target` | Git LFS is disabled globally on the target server (system admin setting) |
| `git lfs push to the target failed` with HTTP 400/422 | possible incompatibility between a recent git-lfs and 4.14: try an older git-lfs (e.g. 2.13.x) on the migration machine |
| `pre-receive hook declined` / `remote rejected` | a hook or branch permission of the target project refuses the push |
| `RPC failed; HTTP 413` | a reverse proxy in front of the target limits the body size (nginx `client_max_body_size`), or try `GIT_HTTP_POST_BUFFER=524288000` |
| `git lfs fetch from the source failed … Object does not exist` | the LFS object is missing **on the source server** itself. `LFS_ALLOW_MISSING=true` migrates the rest and flags the repository in the report |
| `the target slug is 'x' (expected 'y')` | Bitbucket derived another slug from the name: the clone URL differs, the mapping is kept in `output/state/` |
| `SAFETY: refused … on the SOURCE server` | a write to the source was blocked (should never happen; please report it) |

> These scripts were tested end to end against a mock Bitbucket server (REST API subset,
> git smart HTTP, Git LFS batch API) with gawk, mawk, BSD awk and busybox awk. They were
> not tested against real 7.21.10 / 4.14.2 instances, which is exactly what
> `02-test-single-repo.sh` is for: run it before the full migration.
