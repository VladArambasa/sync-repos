#!/usr/bin/env bash
# CRLF fix - keep the trailing # on these lines
[ -n "${BASH_VERSION:-}" ] || { echo "run it w bash: bash $0" >&2; exit 1; }            #
if [ -f "$0" ] && grep -q $'\r' "$0"; then                                               #
  sed -i 's/\r$//' "$0" && exec "$BASH" "$0" "$@"                                         #
  echo "can't fix CRLF line ends in $0" >&2; exit 1                                       #
fi                                                                                        #

# SET : paste repo dir between " " (empty = $REPOS_DIR, else ~/gits)
REPO_DIR_CUSTOM=""
# SET : commit message
COMMIT_MSG="Automatic Commit"

set -uo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "needs bash 4+" >&2; exit 1; }

REPO_DIR=${REPO_DIR_CUSTOM:-${REPOS_DIR:-$HOME/gits}}
DEST=$REPO_DIR                                    # location of git repos (self-explanatory)
API=${GITHUB_API_URL:-https://api.github.com}
MSG=$COMMIT_MSG NO_FORKS=0 DRY=0

usage() {
  cat <<EOF
Usage: bash ${0##*/} [options] [folder]

Pushes every repo in the folder that you own on GitHub:
git add . , git commit -m "$COMMIT_MSG", git push.
Repos mid-merge/rebase, on a detached HEAD or archived on GitHub are reported and left alone.
Adds everything .gitignore doesn't stop - keep secrets in .gitignore.

  folder          repo location (default: $REPO_DIR)
  -m "text"       commit message (default: "$COMMIT_MSG")
  --no-forks      leave forks out
  -n, --dry-run   only show dry-run - no change - just "premonitions"
  -h, --help      this text

Needs one of these (to see which repos are yours):
  - GitHub CLI, logged in once:  gh auth login
  - a token in GITHUB_TOKEN (classic: "repo" scope, fine-grained: read+write access to contents)
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }
plural() { (( $1 == 1 )) || printf s; }

while (( $# )); do
  case $1 in
    -m)            (( $# > 1 )) || die "-m needs a message"; MSG=$2; shift ;;
    --no-forks)    NO_FORKS=1 ;;
    -n|--dry-run)  DRY=1 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             DEST=$1 ;;
  esac
  shift
done
[ -n "$MSG" ] || die "empty commit message"
# shellcheck disable=SC2088  # literal ~ on purpose
case $DEST in '~'|'~/'*) DEST=$HOME${DEST:1} ;; esac               # ~ in quotes -> $HOME
command -v cygpath >/dev/null 2>&1 && DEST=$(cygpath -u "$DEST")   # Git Bash: C:\x -> /c/x
[ "$DEST" = / ] || DEST=${DEST%/}
command -v git >/dev/null 2>&1 || die "git not installed"
[ -d "$DEST" ] || die "no such folder: $DEST"

# ENQUIRE : which are pers repos

TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
if command -v gh >/dev/null 2>&1 && { gh auth token >/dev/null 2>&1 || gh auth status >/dev/null 2>&1; }; then
  USE_GH=1
  [ -n "$TOKEN" ] || TOKEN=$(gh auth token 2>/dev/null | tr -d '\r')
elif [ -n "$TOKEN" ]; then
  USE_GH=0
  command -v curl >/dev/null 2>&1 || die "needs curl (or gh)"
else
  die "can't see your repos. do one of these, then run again:
  - gh auth login             (install gh: winget install GitHub.cli / sudo apt install gh)
  - export GITHUB_TOKEN=...   (github.com > Settings > Developer settings > Personal access tokens)"
fi

list_with_gh() {     # one line per repo: owner/name <TAB> fork? <TAB> archived?
  gh repo list --limit 10000 --json nameWithOwner,isFork,isArchived \
    --jq '.[] | "\(.nameWithOwner)\t\(.isFork)\t\(.isArchived)"'
}

list_with_token() {  # same, via REST API - 100/page, no jq needed
  local page=1 resp code body rows
  while :; do
    resp=$(printf 'Authorization: Bearer %s\n' "$TOKEN" |
      curl -sS -H @- -H 'Accept: application/vnd.github+json' -w $'\n%{http_code}' \
        "$API/user/repos?affiliation=owner&per_page=100&page=$page") || return 1
    code=${resp##*$'\n'} body=${resp%$'\n'*}
    if [ "$code" != 200 ]; then
      echo "GitHub said $code: $(grep -oE '"message": *"[^"]*"' <<< "$body" | head -n 1 | cut -d '"' -f 4)" >&2
      return 1
    fi
    rows=$(grep -oE '"(full_name|fork|archived)": *("[^"]*"|true|false)' <<< "$body" | awk -F '"' '
      $2 == "full_name" { if (n != "") print n "\t" f "\t" a; n = $4; f = a = "false" }
      $2 == "fork"      { f = ($3 ~ /true/) ? "true" : "false" }
      $2 == "archived"  { a = ($3 ~ /true/) ? "true" : "false" }
      END               { if (n != "") print n "\t" f "\t" a }')
    [ -z "$rows" ] || printf '%s\n' "$rows"
    (( $(grep -c . <<< "$rows") == 100 )) || break
    page=$((page + 1))
  done
}

if (( USE_GH )); then
  echo "listing your repos (gh)..."
  list=$(list_with_gh) || die "gh can't list your repos (see above)"
else
  echo "listing your repos (token)..."
  list=$(list_with_token) || die "token can't list your repos (see above)"
fi
mapfile -t ROWS < <(tr -d '\r' <<< "$list" | grep . | sort -f)
(( ${#ROWS[@]} )) || die "no repos on GitHub"

declare -A MINE=() ARCHIVED=()                    # owner/name -> Owner/Name, archived?
LEFT_OUT=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r full fork archived <<< "$row"
  if (( NO_FORKS )) && [ "$fork" = true ]; then LEFT_OUT=$((LEFT_OUT + 1)); continue; fi
  MINE[${full,,}]=$full
  ARCHIVED[${full,,}]=$archived
done

# CHECK : which are here (by origin URL)

repo_key() {   # any GitHub URL -> owner/name
  local u=${1%/} owner name
  u=${u%.git}; u=${u//:/\/}
  name=${u##*/}; u=${u%/*}; owner=${u##*/}
  printf '%s/%s' "${owner,,}" "${name,,}"
}

PLAN=()                                           # label <TAB> folder <TAB> archived?
shopt -s nullglob dotglob
for dir in "$DEST"/*; do
  [ -d "$dir" ] && [ -e "$dir/.git" ] || continue
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || continue
  key=$(repo_key "$url")
  [ -n "${MINE[$key]:-}" ] || continue            # not yours: leave it
  name=${MINE[$key]#*/}
  label=$name
  [ "${dir##*/}" = "$name" ] || label="$name (in ${dir##*/})"
  PLAN+=("$label"$'\t'"$dir"$'\t'"${ARCHIVED[$key]}")
done
(( ${#PLAN[@]} )) && mapfile -t PLAN < <(printf '%s\n' "${PLAN[@]}" | sort -f)

# PUSH : add, commit, push

[ -t 0 ] || export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never   # unattended: fail, don't wait for a login

gitnet() {   # git w token for github.com only - never saved
  if [ -n "$TOKEN" ]; then
    # shellcheck disable=SC2016  # expanded by the helper, not here
    SYNC_TOKEN=$TOKEN git -c credential.https://github.com.helper= \
      -c 'credential.https://github.com.helper=!f() { if [ "$1" = get ]; then echo username=x-access-token; echo "password=$SYNC_TOKEN"; fi; }; f' "$@"
  else
    git "$@"
  fi
}

W=12
for step in "${PLAN[@]}"; do
  label=${step%%$'\t'*}
  (( ${#label} > W )) && W=${#label}
done
(( W > 40 )) && W=40
start() { printf '  %-*s  ' "$W" "$1"; }         # name, result on same line

N_PUSHED=0 N_SAME=0 N_SKIPPED=0 N_FAILED=0 N_TO_PUSH=0
FAILED=()

skip() { echo "skipped - $1"; N_SKIPPED=$((N_SKIPPED + 1)); }

failed() {   # $1 name, $2 git output, $3 1 = committed first
  local msg hint='' fix=''
  # GitHub's error > rejected line > first fatal:/error: (+ files) > first line
  msg=$(grep -m 1 -E '^remote: (error|fatal):' <<< "$2") ||
    msg=$(grep -m 1 -E '^ ! \[' <<< "$2" | tr -s ' ') ||
    msg=$(awk '!m && /^(fatal|error|ERROR):/ { m = $0; l = /:$/; next }
               m && l && /^[ \t]+[^ \t]/      { sub(/^[ \t]+/, ""); m = m (n++ ? ", " : " ") $0; next }
               m                              { exit }
               END                            { print m }' <<< "$2")
  [ -n "$msg" ] || msg=$(grep -v -E '^(hint|warning):' <<< "$2" | grep -m 1 .)
  msg=${msg#"${msg%%[![:space:]]*}"}; msg=${msg%"${msg##*[![:space:]]}"}
  case $2 in
    *"GH001"*|*"exceeds GitHub's file size limit"*)
                    hint="file over 100 MB, GitHub won't take it"; fix="undo: git reset --soft HEAD~1" ;;
    *"[rejected]"*|*"fetch first"*|*"non-fast-forward"*)
                    hint="GitHub has newer commits"; fix="pull first" ;;
    *"tell me who you are"*|*"identity unknown"*|*"empty ident"*)
                    hint="no git identity"; fix="set user.name and user.email" ;;
    *"archived"*)   hint="archived on GitHub (read-only)" ;;
    *"Authentication failed"*|*"could not read Username"*|*"Permission denied"*|*"not found"*|*"error: 403"*)
                    hint="access denied"; fix="check login/SSH key" ;;
  esac
  hint=${hint:-${msg:-git error}}
  (( ${3:-0} )) && hint+=" (committed locally)"
  echo "FAILED - $hint${fix:+ - $fix}"
  FAILED+=("$1: ${msg:-(no output)}")
  N_FAILED=$((N_FAILED + 1))
}

busy() {     # mid merge/rebase/cherry-pick/revert, or unmerged files
  local p
  while IFS= read -r p; do
    [[ $p == /* || $p == ?:[\\/]* ]] || p="$1/$p"
    [ -e "$p" ] && return 0
  done < <(git -C "$1" rev-parse --git-path MERGE_HEAD --git-path rebase-merge --git-path rebase-apply \
             --git-path CHERRY_PICK_HEAD --git-path REVERT_HEAD 2>/dev/null)
  [ -n "$(git -C "$1" ls-files -u 2>/dev/null | head -n 1)" ]
}

push_one() {   # $1 label, $2 folder, $3 archived?
  local dir=$2 branch files ahead=0 up=1 made=0 n out msg args
  start "$1"
  if busy "$dir"; then skip "merge/rebase in progress"; return; fi
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD) || { skip "detached HEAD"; return; }
  files=$(git -C "$dir" status --porcelain -uall 2>/dev/null | grep -c .)
  if git -C "$dir" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD')
  else                                            # no upstream yet: push -u
    up=0
    git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1 && ahead=$(git -C "$dir" rev-list --count HEAD)
  fi
  if (( files == 0 && ahead == 0 )); then echo "up to date"; N_SAME=$((N_SAME + 1)); return; fi
  if [ "$3" = true ]; then skip "archived on GitHub (read-only)"; return; fi

  if (( DRY )); then
    msg="would "
    (( files )) && msg+="commit $files file$(plural "$files"), "
    if (( up )); then n=$((ahead + (files > 0))); msg+="push $n commit$(plural "$n")"
    else msg+="push $branch (sets upstream)"; fi
    echo "$msg"; N_TO_PUSH=$((N_TO_PUSH + 1)); return
  fi

  if (( files )); then
    out=$(git -C "$dir" add . 2>&1) || { failed "$1" "$out"; return; }
    if ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
      files=$(git -C "$dir" diff --cached --name-only | grep -c .)
      out=$(git -C "$dir" commit -q -m "$MSG" 2>&1) || { failed "$1" "$out"; return; }
      made=1; ahead=$((ahead + 1))
    fi
  fi
  if (( ahead == 0 )); then echo "up to date"; N_SAME=$((N_SAME + 1)); return; fi

  args=(push -q)
  (( up )) || args+=(-u origin HEAD)
  out=$(gitnet -C "$dir" "${args[@]}" 2>&1) || { failed "$1" "$out" "$made"; return; }
  if (( up )); then msg="pushed: $ahead commit$(plural "$ahead")"; else msg="pushed: $branch, upstream set"; fi
  (( made )) && msg+=" ($files file$(plural "$files") committed)"
  echo "$msg"; N_PUSHED=$((N_PUSHED + 1))
}

header="${#PLAN[@]} repo$(plural "${#PLAN[@]}")"
(( LEFT_OUT )) && header+=" ($LEFT_OUT left out)"
header+=" -> $DEST"
(( DRY )) && header+="  (dry run, no changes)"
printf '%s\n\n' "$header"

for step in "${PLAN[@]}"; do
  IFS=$'\t' read -r label dir archived <<< "$step"
  push_one "$label" "$dir" "$archived"
done

echo
if (( DRY )); then
  echo "dry run: $N_TO_PUSH to push, $N_SAME up to date, $N_SKIPPED skipped - nothing changed"
  exit 0
fi
summary="done: $N_PUSHED pushed, $N_SAME up to date"
(( N_SKIPPED )) && summary+=", $N_SKIPPED skipped"
(( N_FAILED )) && summary+=", $N_FAILED failed"
echo "$summary"
if (( N_FAILED )); then
  printf '\ngit said:\n'
  printf '  %s\n' "${FAILED[@]}"
  exit 1
fi
