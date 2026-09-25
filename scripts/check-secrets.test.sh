#!/usr/bin/env bash
set -euo pipefail

checker="$(cd "$(dirname "$0")" && pwd)/check-secrets.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repo" "$fixture/bin"

cat > "$fixture/bin/gitleaks" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture/bin/ripsecrets" <<'SH'
#!/usr/bin/env bash
for path in "$@"; do
  [[ "$path" == --* ]] && continue
  if [[ -f "$path" ]] && grep -q UNSTAGED_MARKER "$path"; then exit 1; fi
  if [[ -d "$path" ]] && grep -R -q UNSTAGED_MARKER "$path"; then exit 1; fi
done
SH
chmod +x "$fixture/bin/gitleaks" "$fixture/bin/ripsecrets"

git -C "$fixture/repo" init -q -b main
git -C "$fixture/repo" config user.name "Secret Guard Fixture"
git -C "$fixture/repo" config user.email "fixture@example.test"
printf 'base\n' > "$fixture/repo/README.md"
git -C "$fixture/repo" add README.md
git -C "$fixture/repo" commit -qm base
base="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" update-ref refs/remotes/origin/main "$base"

git -C "$fixture/repo" checkout -qb feature
printf 'placeholder\n' > "$fixture/repo/.env"
git -C "$fixture/repo" add .env
git -C "$fixture/repo" commit -qm 'add prohibited path'
git -C "$fixture/repo" rm -q .env
git -C "$fixture/repo" commit -qm 'remove prohibited path'
feature="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" checkout -q main

if output="$(cd "$fixture/repo" && printf 'refs/heads/feature %s refs/heads/feature %s\n' "$feature" "$base" \
    | PATH="$fixture/bin:$PATH" "$checker" outbound 2>&1)"; then
  echo "Outbound check missed a prohibited path in another pushed ref's history" >&2
  exit 1
fi
if [[ "$output" != *"Credential file cannot be committed: .env"* ]]; then
  echo "Outbound check failed without identifying the prohibited historical path" >&2
  exit 1
fi

printf 'staged\n' > "$fixture/repo/README.md"
git -C "$fixture/repo" add README.md
printf 'UNSTAGED_MARKER\n' >> "$fixture/repo/README.md"
if ! (cd "$fixture/repo" && PATH="$fixture/bin:$PATH" "$checker" staged >/dev/null 2>&1); then
  echo "Staged check read unstaged working-tree content" >&2
  exit 1
fi
