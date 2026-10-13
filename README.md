# sync-repos

Clones the GitHub repos you own that you don't have yet. Pulls the ones you do. That's it.

## Needs

- bash 4+ and git. On Windows, Git Bash.
- The GitHub CLI, logged in once: `gh auth login`.
  No gh? Put a token in `GITHUB_TOKEN` (classic, `repo` scope).

## Use

```bash
bash sync-repos.sh            # syncs ~/gits
bash sync-repos.sh ~/code     # any other folder
bash sync-repos.sh -n         # dry run, changes nothing
```

| Option | Does |
|---|---|
| `--ssh` / `--https` | how new repos get cloned (default: what gh uses, else HTTPS) |
| `--no-forks` | skips forks |
| `--no-archived` | skips archived repos |
| `-n`, `--dry-run` | shows what it would do, does nothing |

`REPOS_DIR` changes the default folder.

## It won't

- Merge. Pulls are fast-forward only.
- Touch a repo that has its own commits, or uncommitted changes in the way. It says why and moves on.
- Clone over a folder that isn't that repo.
- Save your token. Not in the script, not in `.git/config`. Nowhere.

It does tell you what you forgot to push.

## Good to know

- Renamed a folder? Fine. Clones are found by their GitHub address, not their name.
- Exit code is 1 if anything failed.
- Picked up Windows line endings? It fixes them itself.
