# sync-repos

Two scripts for every GitHub repo you own:

- `sync-repos.sh` clones the ones you don't have. Pulls the ones you do.
- `push-repos.sh` does the opposite: `git add .`, `git commit -m "Automatic Commit"`, `git push` in each.

That's it.

## Needs

- bash 4+ and git. On Windows, Git Bash.
- The GitHub CLI, logged in once: `gh auth login`.
  No gh? Put a token in `GITHUB_TOKEN` (classic, `repo` scope).

## Use

```bash
bash sync-repos.sh              # pull everything down
bash push-repos.sh              # push everything up
bash push-repos.sh -m "notes"   # own commit message
bash sync-repos.sh -n           # dry run, changes nothing (both scripts)
bash sync-repos.sh ~/code       # any other folder (both scripts)
```

| Option | Does |
|---|---|
| `-n`, `--dry-run` | shows what it would do, does nothing |
| `--no-forks` | skips forks |
| `--no-archived` | skips archived repos (sync; push always skips them) |
| `--ssh` / `--https` | how new repos get cloned (sync; default: what gh uses, else HTTPS) |
| `-m "text"` | commit message (push) |

Folder: paste it between the quotes of `REPO_DIR_CUSTOM=""` at the top of each script. Empty? It uses `$REPOS_DIR`, else `~/gits`. `export REPOS_DIR=...` sets both at once.

Commit message: `COMMIT_MSG` at the top of `push-repos.sh`.

## It won't

- Merge. Pulls are fast-forward only.
- Touch a repo that has its own commits, or uncommitted changes in the way. It says why and moves on.
- Clone over a folder that isn't that repo.
- Push to repos that aren't yours, archived ones, or ones mid-merge/rebase or on a detached HEAD.
- Save your token. Not in the scripts, not in `.git/config`. Nowhere.

`push-repos.sh` adds everything `.gitignore` doesn't stop. Keep secrets in `.gitignore`.

## Good to know

- Renamed a folder? Fine. Clones are found by their GitHub address, not their name.
- Push rejected? GitHub has newer commits. Pull first, then push again.
- `sync-repos.sh` tells you what you forgot to push.
- Exit code is 1 if anything failed.
- Picked up Windows line endings? They fix themselves.
