#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_DIR="$REPO_ROOT/dist"

usage() {
  cat <<'EOF'
Usage: scripts/build-portable-release.sh [--output-dir PATH]

Build a portable work2md tar.gz release bundle from the current repository
state. The archive contains the CLI entrypoints, shared libraries, conversion
helpers, version metadata, and top-level documentation.
EOF
}

install_release_file() {
  local mode="$1"
  local source_path="$2"
  local destination_path="$3"

  mkdir -p "$(dirname "$destination_path")"
  install -m "$mode" "$source_path" "$destination_path"
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

VERSION="$(head -n1 "$REPO_ROOT/VERSION")"
SOURCE_DATE_EPOCH_VALUE="${SOURCE_DATE_EPOCH:-}"

if command -v dpkg-parsechangelog >/dev/null 2>&1; then
  CHANGELOG_VERSION="$(dpkg-parsechangelog -l"$REPO_ROOT/debian/changelog" -S Version)"
  UPSTREAM_VERSION="${CHANGELOG_VERSION%%-*}"

  if [[ "$VERSION" != "$UPSTREAM_VERSION" ]]; then
    echo "VERSION ($VERSION) does not match debian/changelog upstream version ($UPSTREAM_VERSION)." >&2
    exit 1
  fi

  if [[ -z "$SOURCE_DATE_EPOCH_VALUE" ]]; then
    SOURCE_DATE_EPOCH_VALUE="$(LC_ALL=C TZ=UTC date -d "$(dpkg-parsechangelog -l"$REPO_ROOT/debian/changelog" -S Date)" +%s)"
  fi
fi

if [[ -z "$SOURCE_DATE_EPOCH_VALUE" ]]; then
  SOURCE_DATE_EPOCH_VALUE="$(stat -c %Y "$REPO_ROOT/VERSION")"
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

ARCHIVE_ROOT="$STAGING_DIR/work2md-$VERSION"
mkdir -p "$ARCHIVE_ROOT"

install_release_file 755 "$REPO_ROOT/jira2md.sh" "$ARCHIVE_ROOT/jira2md"
install_release_file 755 "$REPO_ROOT/confluence2md.sh" "$ARCHIVE_ROOT/confluence2md"
install_release_file 755 "$REPO_ROOT/work2md-config" "$ARCHIVE_ROOT/work2md-config"
install_release_file 644 "$REPO_ROOT/lib/work2md-cli.sh" "$ARCHIVE_ROOT/lib/work2md-cli.sh"
install_release_file 644 "$REPO_ROOT/lib/work2md-config.sh" "$ARCHIVE_ROOT/lib/work2md-config.sh"
install_release_file 644 "$REPO_ROOT/scripts/atlassian_content_to_md.py" "$ARCHIVE_ROOT/scripts/atlassian_content_to_md.py"
install_release_file 644 "$REPO_ROOT/scripts/atlassian_json_helper.py" "$ARCHIVE_ROOT/scripts/atlassian_json_helper.py"
install_release_file 644 "$REPO_ROOT/scripts/confluence_attachment_helper.py" "$ARCHIVE_ROOT/scripts/confluence_attachment_helper.py"
install_release_file 644 "$REPO_ROOT/scripts/jira_media_helper.py" "$ARCHIVE_ROOT/scripts/jira_media_helper.py"
install_release_file 644 "$REPO_ROOT/scripts/work2md_export_helper.py" "$ARCHIVE_ROOT/scripts/work2md_export_helper.py"
install_release_file 644 "$REPO_ROOT/VERSION" "$ARCHIVE_ROOT/VERSION"
install_release_file 644 "$REPO_ROOT/README.md" "$ARCHIVE_ROOT/README.md"
install_release_file 644 "$REPO_ROOT/CHANGELOG.md" "$ARCHIVE_ROOT/CHANGELOG.md"

mkdir -p "$OUTPUT_DIR"
ARCHIVE_PATH="$OUTPUT_DIR/work2md_${VERSION}_portable.tar.gz"
find "$ARCHIVE_ROOT" -print0 | xargs -0 touch -d "@$SOURCE_DATE_EPOCH_VALUE"
tar \
  --sort=name \
  --mtime="@$SOURCE_DATE_EPOCH_VALUE" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -czf "$ARCHIVE_PATH" \
  -C "$STAGING_DIR" \
  "work2md-$VERSION"

printf '%s\n' "$ARCHIVE_PATH"
