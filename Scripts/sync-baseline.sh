#!/usr/bin/env bash
# Refresh the parity corpus from the platform repo.
#
# The fixtures and the frames the web renderer produced for them live in
# funnel-platform; this is a different repository, so they are COPIED here and
# nothing in Swift can prove the copy is current. That is the one drift risk in
# the parity story, and it is why this script exists rather than a manual copy:
# run it, commit what changes, and the diff shows exactly which frames moved.
#
#   ./Scripts/sync-baseline.sh [path-to-funnel-platform]
set -euo pipefail

PLATFORM="${1:-$HOME/Documents/funnel-platform}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Tests/UpliftLayoutTests/Baseline"

if [ ! -d "$PLATFORM/packages/schema/fixtures" ]; then
  echo "not a funnel-platform checkout: $PLATFORM" >&2
  exit 1
fi

# Regenerate the baseline first, so a stale dump is never copied forward.
echo "→ regenerating the web baseline"
(cd "$PLATFORM/apps/dashboard" && npx playwright test tests/layout.spec.ts)

echo "→ copying into $DEST"
cp "$PLATFORM/packages/schema/fixtures/interior-paywall.json" "$DEST/"
cp "$PLATFORM/packages/schema/fixtures/wellness-onboarding.json" "$DEST/"
cp "$PLATFORM"/apps/dashboard/tests/layout-baseline/*.json "$DEST/"

echo "→ done. Review with: git diff --stat Tests/UpliftLayoutTests/Baseline"
