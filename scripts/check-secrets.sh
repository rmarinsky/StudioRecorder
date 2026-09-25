#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
case "$mode" in
  staged|outbound|ci) ;;
  *) echo "Usage: $0 {staged|outbound|ci}" >&2; exit 2 ;;
esac

command -v gitleaks >/dev/null || { echo "Install gitleaks with brew bundle" >&2; exit 2; }
command -v ripsecrets >/dev/null || { echo "Install ripsecrets with brew bundle" >&2; exit 2; }

check_path() {
  local path="$1" name="${1##*/}"
  case "$name" in
    .env*)
      case "$name" in
        *.example|*.sample|*.template) ;;
        *) echo "Credential file cannot be committed: $path" >&2; exit 1 ;;
      esac
      ;;
    *.pem|*.p8|*.p12|*.key|*.keystore|*.sqlite|*.db|*.dump|*production*.sql|*credentials*.json|*tokens*.json)
      echo "Credential, signing, or data-dump file cannot be committed: $path" >&2
      exit 1
      ;;
  esac
}

check_history_paths() {
  local path
  while IFS= read -r -d '' path; do
    [[ -z "$path" ]] || check_path "$path"
  done < <(git log --format= --name-only -z "$1")
}

if [[ "$mode" == staged ]]; then
  files=()
  while IFS= read -r -d '' path; do
    check_path "$path"
    files+=("$path")
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
  if [[ ${files[0]+present} ]]; then
    staged_tree="$(mktemp -d)"
    trap 'rm -rf "$staged_tree"' EXIT
    for path in "${files[@]}"; do
      mkdir -p "$staged_tree/$(dirname "$path")"
      git show ":$path" > "$staged_tree/$path"
    done
    ripsecrets --strict-ignore "$staged_tree" >/dev/null
    gitleaks git --staged --redact --no-banner --log-level error
  fi
  exit 0
fi

if [[ "$mode" == ci ]]; then
  while IFS= read -r -d '' path; do check_path "$path"; done < <(git ls-files -z)
  check_history_paths HEAD
  git ls-files -z | xargs -0 ripsecrets --strict-ignore >/dev/null
  gitleaks git --redact --no-banner --log-level error
  exit 0
fi

found_ref=false
while read -r local_ref local_oid remote_ref remote_oid; do
  [[ -z "$local_oid" || "$local_oid" =~ ^0+$ ]] && continue
  found_ref=true
  if [[ "$remote_oid" =~ ^0+$ ]] || ! git cat-file -e "${remote_oid}^{commit}" 2>/dev/null; then
    range="$local_oid"
  else
    range="$remote_oid..$local_oid"
  fi
  check_history_paths "$range"
  gitleaks git --redact --no-banner --log-level error --log-opts="$range"
done
if [[ "$found_ref" == false ]]; then
  echo "No pushed commit refs were supplied to the pre-push check" >&2
  exit 2
fi
