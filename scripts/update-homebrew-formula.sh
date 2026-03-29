#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FORMULA_PATH="$REPO_ROOT/Formula/work2md.rb"
OUTPUT_DIR="$REPO_ROOT/dist"

usage() {
  cat <<'EOF'
Usage: scripts/update-homebrew-formula.sh [--output-dir PATH]

Rebuild the portable release archive and refresh Formula/work2md.rb so its URL,
version, and SHA-256 match the current repository version.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --output-dir." >&2
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

version="$(head -n1 "$REPO_ROOT/VERSION")"
archive_name="work2md_${version}_portable.tar.gz"
archive_path="$OUTPUT_DIR/$archive_name"
release_url="https://github.com/green-zen-monk/work2md/releases/download/v${version}/${archive_name}"

"$REPO_ROOT/scripts/build-portable-release.sh" --output-dir "$OUTPUT_DIR" >/dev/null
archive_sha="$(sha256sum "$archive_path" | awk '{print $1}')"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

awk \
  -v version="$version" \
  -v release_url="$release_url" \
  -v archive_sha="$archive_sha" \
  '
    $1 == "url" { print "  url \"" release_url "\""; next }
    $1 == "version" { print "  version \"" version "\""; next }
    $1 == "sha256" { print "  sha256 \"" archive_sha "\""; next }
    { print }
  ' \
  "$FORMULA_PATH" > "$tmp_file"

install -m 644 "$tmp_file" "$FORMULA_PATH"

printf 'Updated %s for version %s\n' "$FORMULA_PATH" "$version"
printf 'Archive SHA-256: %s\n' "$archive_sha"
