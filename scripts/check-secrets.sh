#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
case "$mode" in
  staged|outbound|ci) ;;
  *) echo "Usage: $0 {staged|outbound|ci}" >&2; exit 2 ;;
esac

command -v gitleaks >/dev/null || { echo "Install gitleaks with brew bundle" >&2; exit 2; }
command -v ripsecrets >/dev/null || { echo "Install ripsecrets with brew bundle" >&2; exit 2; }

files=()
if [[ "$mode" == staged ]]; then
  while IFS= read -r -d '' path; do files+=("$path"); done < <(git diff --cached --name-only --diff-filter=ACMR -z)
else
  while IFS= read -r -d '' path; do files+=("$path"); done < <(git ls-files -z)
fi

if [[ ${files[0]+present} ]]; then
  for path in "${files[@]}"; do
    name="${path##*/}"
    case "$name" in
      .env|.env.*)
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
  done
fi

if [[ "$mode" == staged ]]; then
  if [[ ${files[0]+present} ]]; then
    ripsecrets --strict-ignore "${files[@]}" >/dev/null
    gitleaks git --staged --redact --no-banner --log-level error
  fi
  exit 0
fi

ripsecrets --strict-ignore "${files[@]}" >/dev/null
if [[ "$mode" == ci ]]; then
  gitleaks git --redact --no-banner --log-level error
else
  base="$(git merge-base origin/main HEAD)"
  gitleaks git --redact --no-banner --log-level error --log-opts="$base..HEAD"
fi
