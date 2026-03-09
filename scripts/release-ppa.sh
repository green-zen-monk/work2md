#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: scripts/release-ppa.sh ppa:<launchpad-user>/<ppa-name> <jammy|noble>" >&2
  exit 1
fi

PPA_TARGET="$1"
SERIES="$2"

case "$SERIES" in
  jammy|noble)
    ;;
  *)
    echo "Unsupported Ubuntu series: $SERIES" >&2
    exit 1
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHANGELOG_FILE="$ROOT_DIR/debian/changelog"
BASE_VERSION="$(sed -n '1s/^work2md (//; 1s/) .*//p' "$CHANGELOG_FILE")"
RELEASE_VERSION="${BASE_VERSION%%~*}"
UPSTREAM_VERSION="${RELEASE_VERSION%%-*}"
TARGET_VERSION="${RELEASE_VERSION}~${SERIES}1"
EXPECTED_TAG="v${UPSTREAM_VERSION}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cp -a "$ROOT_DIR"/. "$TMP_DIR/work2md"
TMP_PROJECT_DIR="$TMP_DIR/work2md"
TMP_CHANGELOG="$TMP_PROJECT_DIR/debian/changelog"

if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CURRENT_TAG="$(git -C "$ROOT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
  if [[ "$CURRENT_TAG" != "$EXPECTED_TAG" ]]; then
    echo "Expected current Git tag ${EXPECTED_TAG}, got ${CURRENT_TAG:-<none>}." >&2
    exit 1
  fi
fi

python3 - "$TMP_CHANGELOG" "$TARGET_VERSION" "$SERIES" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
series = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines()

if not lines:
    raise SystemExit("debian/changelog is empty")

lines[0] = f"work2md ({version}) {series}; urgency=medium"
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

(
  cd "$TMP_PROJECT_DIR"
  dpkg-buildpackage -S
)

dput "$PPA_TARGET" "$TMP_DIR/work2md_${TARGET_VERSION}_source.changes"
