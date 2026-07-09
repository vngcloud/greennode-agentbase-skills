#!/usr/bin/env bash
# Cut a release of greennode-agentbase-skills.
#
# Bumps the SemVer "version" field in lockstep across every plugin manifest,
# validates the JSON, then (unless --no-git / --dry-run) commits and tags.
#
# The Claude Code and Codex tracks share one version on purpose: a single
# bump ships to both marketplaces, and the auto-update / "new version" logic
# in each tool keys off this field.
#
# Usage:
#   scripts/release.sh patch|minor|major [--dry-run] [--no-git]
set -euo pipefail

MANIFESTS=(
  ".claude-plugin/plugin.json"
  ".claude-plugin/marketplace.json"
  ".codex-plugin/plugin.json"
)

DRY_RUN=0
NO_GIT=0
BUMP=""

for arg in "$@"; do
  case "$arg" in
    patch|minor|major) BUMP="$arg" ;;
    --dry-run) DRY_RUN=1 ;;
    --no-git)  NO_GIT=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/release.sh patch|minor|major [--dry-run] [--no-git]

Bump the version across all plugin manifests (.claude-plugin + .codex-plugin),
validate the JSON, then commit and tag vX.Y.Z.

  patch|minor|major   SemVer bump level
  --dry-run           Print the planned bump; change nothing
  --no-git            Bump + validate the files, but skip the commit/tag
EOF
      exit 0 ;;
    *) echo "error: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

if [[ -z "$BUMP" ]]; then
  echo "usage: $0 patch|minor|major [--dry-run] [--no-git]" >&2
  exit 2
fi

# Run from the repo root so the relative manifest paths resolve.
if [[ ! -f ".claude-plugin/plugin.json" ]]; then
  echo "error: run from the repo root (.claude-plugin/plugin.json not found)" >&2
  exit 1
fi

# Extract the first "version": "x.y.z" value from a manifest.
read_version() {
  grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$1" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true
}

# Pre-check: every manifest must already agree. Otherwise we'd silently
# desync the Claude and Codex release tracks instead of fixing the drift.
CURRENT=""
for f in "${MANIFESTS[@]}"; do
  v="$(read_version "$f")"
  if [[ -z "$v" ]]; then
    echo "error: no \"version\" field found in $f" >&2
    exit 1
  fi
  if [[ -z "$CURRENT" ]]; then
    CURRENT="$v"
  elif [[ "$v" != "$CURRENT" ]]; then
    echo "error: version drift across manifests:" >&2
    for g in "${MANIFESTS[@]}"; do echo "  $g -> $(read_version "$g")" >&2; done
    echo "fix manually so all agree, then re-run." >&2
    exit 1
  fi
done

# Compute next SemVer.
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac
NEW="${MAJOR}.${MINOR}.${PATCH}"

echo "release: ${CURRENT} -> ${NEW} (${BUMP})"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would bump: ${MANIFESTS[*]}"
  echo "[dry-run] would run:  git add ${MANIFESTS[*]} \\"
  echo "                      && git commit -m \"chore(release): v${NEW}\" \\"
  echo "                      && git tag v${NEW}"
  exit 0
fi

# Bump every manifest in place (surgical replace; preserves all other formatting).
# perl (not sed): ${1}/${2} backrefs stay unambiguous when the new version starts
# with a digit, and -i behaves identically on macOS and Linux.
for f in "${MANIFESTS[@]}"; do
  perl -i -pe 's/("version"\s*:\s*")[0-9]+\.[0-9]+\.[0-9]+(")/${1}'"${NEW}"'${2}/' "$f"
done

# Validate JSON and confirm each manifest landed on the new version.
for f in "${MANIFESTS[@]}"; do
  if ! python3 -m json.tool "$f" >/dev/null; then
    echo "error: $f is not valid JSON after bump" >&2
    exit 1
  fi
  got="$(read_version "$f")"
  if [[ "$got" != "$NEW" ]]; then
    echo "error: $f is at ${got}, expected ${NEW}" >&2
    exit 1
  fi
done
echo "bumped ${#MANIFESTS[@]} manifests to ${NEW}"

if [[ "$NO_GIT" -eq 1 ]]; then
  echo "[--no-git] skipping commit/tag; changes are in the working tree."
  exit 0
fi

git add "${MANIFESTS[@]}"
git commit -m "chore(release): v${NEW}" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git tag "v${NEW}"
echo "tagged v${NEW}. publish with:"
echo "  git push && git push origin v${NEW}"
