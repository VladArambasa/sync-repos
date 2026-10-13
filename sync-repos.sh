#!/usr/bin/env bash
# CRLF fix - keep the trailing # on these lines
[ -n "${BASH_VERSION:-}" ] || { echo "run it w bash: bash $0" >&2; exit 1; }            #
if [ -f "$0" ] && grep -q $'\r' "$0"; then                                               #
  sed -i 's/\r$//' "$0" && exec "$BASH" "$0" "$@"                                         #
  echo "can't fix CRLF line ends in $0" >&2; exit 1                                       #
fi                                                                                        #

set -uo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "needs bash 4+" >&2; exit 1; }

DEST=${REPOS_DIR:-$HOME/gits}                     # location of git repos (self-explanatory)
API=${GITHUB_API_URL:-https://api.github.com}
PROTO='' NO_FORKS=0 NO_ARCHIVED=0 DRY=0

usage() {
  cat <<EOF
Usage: bash ${0##*/} [options] [folder]

Clones every GitHub repository you own that is not in the folder yet;
pulls the ones that are. Pulls only fast-forward: (i.e. a copy with commits of its
own, OR w uncommitted changes in the way, is reported/announced and left alone).

  folder          repo location (default: ~/gits, or \$REPOS_DIR)
  --ssh           clone over SSH (git@github.com:...)
  --https         clone over HTTPS (default, unless gh is set to SSH)
  --no-forks      leave forks out
  --no-archived   leave archived repositories out
  -n, --dry-run   only show dry-run - no change - just "premonitions"
  -h, --help      this text

Needs one of these (to see private repos too):
  - GitHub CLI, logged in once:  gh auth login
  - a token in GITHUB_TOKEN (classic: "repo" scope, fine-grained: read access to contents)
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }
plural() { (( $1 == 1 )) || printf s; }

while (( $# )); do
  case $1 in
    --ssh)         PROTO=ssh ;;
    --https)       PROTO=https ;;
    --no-forks)    NO_FORKS=1 ;;
    --no-archived) NO_ARCHIVED=1 ;;
    -n|--dry-run)  DRY=1 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             DEST=$1 ;;
  esac
  shift
done
[ "$DEST" = / ] || DEST=${DEST%/}
command -v git >/dev/null 2>&1 || die "git not installed"

# ENQUIRE : which are pers repos

TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
if command -v gh >/dev/null 2>&1 && { gh auth token >/dev/null 2>&1 || gh auth status >/dev/null 2>&1; }; then
  USE_GH=1
  [ -n "$TOKEN" ] || TOKEN=$(gh auth token 2>/dev/null | tr -d '\r')
  [ -n "$PROTO" ] || PROTO=$(gh config get git_protocol 2>/dev/null | tr -d '\r')
elif [ -n "$TOKEN" ]; then
  USE_GH=0
  command -v curl >/dev/null 2>&1 || die "needs curl (or gh)"
else
  die "can't see your repos. do one of these, then run again:
  - gh auth login             (install gh: winget install GitHub.cli / sudo apt install gh)
  - export GITHUB_TOKEN=...   (github.com > Settings > Developer settings > Personal access tokens)"
fi
[ "$PROTO" = ssh ] || PROTO=https

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

REPOS=() LEFT_OUT=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r full fork archived <<< "$row"
  if { (( NO_FORKS )) && [ "$fork" = true ]; } || { (( NO_ARCHIVED )) && [ "$archived" = true ]; }; then
    LEFT_OUT=$((LEFT_OUT + 1))
  else
    REPOS+=("$full")
  fi
done

# CHECK : which are here already (by origin URL)

repo_key() {   # any GitHub URL -> owner/name
  local u=${1%/} owner name
  u=${u%.git}; u=${u//:/\/}
  name=${u##*/}; u=${u%/*}; owner=${u##*/}
  printf '%s/%s' "${owner,,}" "${name,,}"
}

declare -A HAVE=()                                # owner/name -> local clones
shopt -s nullglob dotglob
for dir in "$DEST"/*; do
  [ -d "$dir" ] && [ -e "$dir/.git" ] || continue
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || continue
  key=$(repo_key "$url")
  HAVE[$key]+="$dir"$'\n'
done

# SYNC : clone missing, pull the rest

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
start() { printf '  %-*s  ' "$W" "$1"; }         # name, result on same line

N_CLONED=0 N_UPDATED=0 N_SAME=0 N_SKIPPED=0 N_FAILED=0 N_TO_PULL=0
FAILED=()

failed() {   # $1 name, $2 git output
  local msg hint=''
  # first fatal:/error: line (+ files it lists), else first line
  msg=$(awk '!m && /^(fatal|error|ERROR):/ { m = $0; l = /:$/; next }
             m && l && /^[ \t]+[^ \t]/      { sub(/^[ \t]+/, ""); m = m (n++ ? ", " : " ") $0; next }
             m                              { exit }
             END                            { print m }' <<< "$2")
  [ -n "$msg" ] || msg=$(grep -v -E '^(hint|warning):' <<< "$2" | grep -m 1 .)
  msg=${msg#"${msg%%[![:space:]]*}"}
  case $2 in
    *"Not possible to fast-forward"*) hint="diverged - merge or rebase by hand" ;;
    *"would be overwritten"*)         hint="uncommitted changes in the way - commit or stash" ;;
    *"no tracking information"*)      hint="branch has no upstream" ;;
    *"not currently on a branch"*)    hint="detached HEAD" ;;
    *"no such ref was fetched"*)      hint="upstream branch gone from GitHub" ;;
    *"Authentication failed"*|*"could not read Username"*|*"Permission denied"*|*"not found"*)
                                      hint="access denied - check login/SSH key" ;;
  esac
  echo "FAILED - ${hint:-${msg:-git error}}"
  FAILED+=("$1: ${msg:-(no output)}")
  N_FAILED=$((N_FAILED + 1))
}

notes() {    # unpushed commits, uncommitted changes
  local ahead out=
  ahead=$(git -C "$1" rev-list --count '@{u}..HEAD' 2>/dev/null) || ahead=0
  (( ahead == 0 )) || out="$ahead unpushed commit$(plural "$ahead")"
  [ -z "$(git -C "$1" status --porcelain 2>/dev/null | head -n 1)" ] || out+="${out:+, }uncommitted changes"
  [ -z "$out" ] || printf ' (%s)' "$out"
}

pull_one() {   # $1 label, $2 folder
  local before after out n
  start "$1"
  if (( DRY )); then echo "would pull"; N_TO_PULL=$((N_TO_PULL + 1)); return; fi
  before=$(git -C "$2" rev-parse -q --verify HEAD 2>/dev/null)
  if out=$(gitnet -C "$2" pull --ff-only --no-rebase 2>&1); then
    after=$(git -C "$2" rev-parse -q --verify HEAD 2>/dev/null)
    if [ "$before" = "$after" ]; then
      echo "up to date$(notes "$2")"; N_SAME=$((N_SAME + 1))
    else
      n=$(git -C "$2" rev-list --count "${before:+$before..}$after")
      echo "updated: $n new commit$(plural "$n")$(notes "$2")"; N_UPDATED=$((N_UPDATED + 1))
    fi
    return
  fi
  if [ -z "$before" ]; then                       # no commits here: still empty on GitHub?
    gitnet -C "$2" ls-remote --exit-code --heads origin >/dev/null 2>&1
    if (( $? == 2 )); then echo "empty on GitHub"; N_SAME=$((N_SAME + 1)); return; fi
  fi
  failed "$1" "$out"
}

clone_one() {  # $1 name, $2 owner/name
  local url out
  if [ "$PROTO" = ssh ]; then url="git@github.com:$2.git"; else url="https://github.com/$2.git"; fi
  start "$1"
  if (( DRY )); then echo "would clone"; N_CLONED=$((N_CLONED + 1)); return; fi
  if out=$(gitnet clone --quiet -- "$url" "$DEST/$1" 2>&1); then
    if git -C "$DEST/$1" rev-parse -q --verify HEAD >/dev/null 2>&1; then echo "cloned"
    else echo "cloned (empty)"; fi
    N_CLONED=$((N_CLONED + 1))
  else
    failed "$1" "$out"
  fi
}

(( DRY )) || mkdir -p "$DEST" || die "can't create $DEST"
header="${#REPOS[@]} repo$(plural "${#REPOS[@]}")"
(( LEFT_OUT )) && header+=" ($LEFT_OUT left out)"
header+=" -> $DEST"
(( DRY )) && header+="  (dry run, no changes)"
printf '%s\n\n' "$header"

PLAN=()                                           # action <TAB> label <TAB> folder or owner/name
for full in "${REPOS[@]}"; do
  name=${full#*/}
  key=${full,,}
  if [ -n "${HAVE[$key]:-}" ]; then               # already here (maybe twice)
    mapfile -t dirs <<< "${HAVE[$key]%$'\n'}"
    for dir in "${dirs[@]}"; do
      label=$name
      [ "${dir##*/}" = "$name" ] || label="$name (in ${dir##*/})"
      PLAN+=("pull"$'\t'"$label"$'\t'"$dir")
    done
  elif [ -e "$DEST/$name" ]; then                 # name taken by something else
    PLAN+=("skip"$'\t'"$name"$'\t'"$full")
  else
    PLAN+=("clone"$'\t'"$name"$'\t'"$full")
  fi
done
for step in "${PLAN[@]}"; do
  IFS=$'\t' read -r _ label _ <<< "$step"
  (( ${#label} > W )) && W=${#label}
done
(( W > 40 )) && W=40

for step in "${PLAN[@]}"; do
  IFS=$'\t' read -r action label arg <<< "$step"
  case $action in
    pull)  pull_one "$label" "$arg" ;;
    clone) clone_one "$label" "$arg" ;;
    skip)  start "$label"; echo "skipped - not a clone of $arg"
           N_SKIPPED=$((N_SKIPPED + 1)) ;;
  esac
done

echo
if (( DRY )); then
  echo "dry run: $N_CLONED to clone, $N_TO_PULL to pull, $N_SKIPPED skipped - nothing changed"
  exit 0
fi
summary="done: $N_CLONED cloned, $N_UPDATED updated, $N_SAME up to date"
(( N_SKIPPED )) && summary+=", $N_SKIPPED skipped"
(( N_FAILED )) && summary+=", $N_FAILED failed"
echo "$summary"
if (( N_FAILED )); then
  printf '\ngit said:\n'
  printf '  %s\n' "${FAILED[@]}"
  exit 1
fi
