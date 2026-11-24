# Bitbucket project migration (7.21.10 ➜ 4.14.2, with Git LFS)

Copies every repository of a Bitbucket project to another Bitbucket server: all branches,
all tags, all Git LFS files (of the whole history) and the default branch.
The source server is only read: everything stays on the old server.

```
.env.example                      settings template (copy to .env)
scripts/01-check-connections.sh   checks both servers, logins and permissions
scripts/02-test-single-repo.sh    migrates one repository as a test copy
scripts/03-migrate-project.sh     migrates all the repositories of the project
scripts/04-verify-project.sh      checks that the target is an exact copy
scripts/update.sh                 downloads the latest version of these scripts
output/                           created by the scripts (log, progress, temporary copies)
```

## Requirements

`bash`, `git` >= 2.31, `git-lfs` and `curl` on the machine running the scripts, with
network access to both servers. Nothing else (no jq, no python).

## Logins

- **Source (7.21.10)**: your username + an HTTP access token with read permissions is
  recommended (avatar ➜ Manage account ➜ HTTP access tokens). Username/password also works.
  The username is always needed: git sends the token as the password of your username.
- **Target (4.14.2)**: username and password. Tokens do not exist before Bitbucket 5.5.
  You need to be **admin of the target project**, and the project must already exist.

## Usage

```bash
cp .env.example .env && chmod 600 .env     # then fill it in
scripts/01-check-connections.sh            # fix every FAIL before going on
scripts/02-test-single-repo.sh my-repo     # pick a repository that uses Git LFS
scripts/03-migrate-project.sh              # all repositories
scripts/04-verify-project.sh               # add --lfs to also download every LFS file
```

- **Follow the migration live** from another terminal: `tail -f output/migration.log`.
  `output/progress.txt` always shows the current position, e.g.
  `[37/212] my-repo: uploading 120 Git LFS files to the target`.
- **Resume**: run `03-migrate-project.sh` again. Repositories listed in `output/done.txt`
  are skipped.
- **Update before the switch**: if people kept working on the old server, run
  `scripts/03-migrate-project.sh --sync`. It pushes what changed. Nothing is ever deleted.

## Get the latest version

```bash
scripts/update.sh
```

Downloads the latest version of every script from GitHub and tells you which files changed.
Your `.env` and `output/` are never touched. If you need an internet proxy, set `PROXY` in `.env`.

## The output/ folder

| File | Content |
|---|---|
| `migration.log` | one line per step and per repository (OK / FAILED / SKIPPED + reason) |
| `progress.txt` | where the copy is right now |
| `done.txt` | repositories already migrated |
| `work/` | temporary copy of the repository being migrated (deleted after each one) |

## Not migrated

Pull requests, permissions, branch restrictions, webhooks, repository settings:
only the git content (branches, tags, LFS files) and the default branch are copied.
