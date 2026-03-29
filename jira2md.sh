#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
for work2md_cli_candidate in \
  "$SCRIPT_DIR/lib/work2md-cli.sh" \
  "$SCRIPT_DIR/../share/work2md/lib/work2md-cli.sh" \
  "/usr/share/work2md/lib/work2md-cli.sh"
do
  if [[ -f "$work2md_cli_candidate" ]]; then
    # shellcheck source=lib/work2md-cli.sh
    source "$work2md_cli_candidate"
    break
  fi
done

if [[ -z "${WORK2MD_CLI_LIB_LOADED:-}" ]]; then
  echo "Unable to locate work2md shared files." >&2
  exit 1
fi

TOOL_VERSION="$(work2md_resolve_version "0.9.0" "$SCRIPT_DIR")"

# jira2md
# Usage: jira2md ISSUE_KEY_OR_URL [--output-dir PATH] [--stdout] [--emit TARGET] [--ai-friendly] [--version]
# Exports issue -> Markdown
# - config: ~/.config/work2md/config
# - default output: ./docs/jira/ISSUE/index.md
# - --output-dir PATH: write the full export bundle under the given directory
# - --stdout: print one selected artifact to stdout and do not write files
# - --emit TARGET: one of index, metadata, comments (default: index when used with --stdout)
# - --ai-friendly: produce a linearized AI-friendly variant and store it in a separate -ai directory

print_usage() {
  cat <<'EOF'
Usage: jira2md ISSUE_KEY_OR_URL [--output-dir PATH] [--stdout] [--emit TARGET] [--ai-friendly] [--front-matter] [--redact RULES] [--drop-field FIELDS] [--incremental] [--version]
       jira2md --input-file PATH [--output-dir PATH] [--ai-friendly] [--front-matter] [--redact RULES] [--drop-field FIELDS] [--incremental]
       jira2md --jql QUERY [--output-dir PATH] [--ai-friendly] [--front-matter] [--redact RULES] [--drop-field FIELDS] [--incremental]
Examples:
  jira2md PROJ-123
  jira2md https://company.atlassian.net/browse/PROJ-123
  jira2md PROJ-123 --output-dir ./export
  jira2md PROJ-123 --stdout
  jira2md PROJ-123 --stdout --emit metadata
  jira2md --input-file ./issues.txt --front-matter --redact email,internal-url
  jira2md --jql 'project = DOCS ORDER BY updated DESC' --incremental
  jira2md PROJ-123 --ai-friendly
  jira2md --version
EOF
}

usage() {
  print_usage >&2
}

log() {
  work2md_info "$@"
}

trim_value() {
  local value="${1-}"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

append_csv_values() {
  local array_name="$1"
  local raw="$2"
  local item
  local -a values=()

  IFS=',' read -r -a values <<< "$raw"
  for item in "${values[@]}"; do
    item="$(trim_value "$item")"
    [[ -n "$item" ]] || continue
    eval "$array_name+=(\"\$item\")"
  done
}

export_helper() {
  python3 "$WORK2MD_SHARE_DIR/scripts/work2md_export_helper.py" "$@"
}

filter_metadata_markdown() {
  local metadata="$1"
  local -a args=()
  local field

  if [[ ${#DROP_FIELDS[@]} -eq 0 ]]; then
    printf '%s' "$metadata"
    return 0
  fi

  for field in "${DROP_FIELDS[@]}"; do
    args+=(--drop-field "$field")
  done
  printf '%s' "$metadata" | export_helper filter-metadata-markdown "${args[@]}"
}

prepend_front_matter() {
  local metadata="$1"
  local body="$2"
  local front_matter=""

  if [[ "${FRONT_MATTER:-0}" -ne 1 ]]; then
    printf '%s' "$body"
    return 0
  fi

  front_matter="$(printf '%s' "$metadata" | export_helper markdown-metadata-to-front-matter)"
  printf '%s\n\n%s' "$front_matter" "$body"
}

redact_text() {
  local text="$1"
  shift || true
  local -a args=()
  local rule base_url

  if [[ ${#REDACT_RULES[@]} -eq 0 ]]; then
    printf '%s' "$text"
    return 0
  fi

  for rule in "${REDACT_RULES[@]}"; do
    args+=(--rule "$rule")
  done
  for base_url in "$@"; do
    [[ -n "$base_url" ]] || continue
    args+=(--base-url "$base_url")
  done

  printf '%s' "$text" | export_helper redact-text "${args[@]}"
}

compute_export_fingerprint() {
  python3 - "$@" <<'PY'
import hashlib
import json
import sys

payload = json.dumps(sys.argv[1:], ensure_ascii=False, separators=(",", ":"))
print(hashlib.sha256(payload.encode("utf-8")).hexdigest())
PY
}

resolve_issue_key() {
  local value="$1"

  if [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [[ "$value" =~ /browse/([A-Za-z][A-Za-z0-9_]*-[0-9]+)(/|$|\?) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$value" =~ [\?\&](selectedIssue|selectedIssueKey)=([A-Za-z][A-Za-z0-9_]*-[0-9]+)($|[\&]) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi

  work2md_error "Unsupported input: expected an issue key like PROJ-123 or a Jira URL containing /browse/PROJ-123."
  exit 1
}

ISSUE=""
OUTPUT_DIR=""
USE_STDOUT=0
EMIT_TARGET=""
AI_FRIENDLY=0
FRONT_MATTER=0
INCREMENTAL=0
INPUT_FILE=""
JQL_QUERY=""
LOG_FORMAT="text"
BATCH_CHILD=0
REDACT_RULES=()
DROP_FIELDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir|--output)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for $1."
        usage
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --stdout)
      USE_STDOUT=1
      shift
      ;;
    --emit)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for --emit."
        usage
        exit 1
      fi
      EMIT_TARGET="$2"
      shift 2
      ;;
    --ai-friendly)
      AI_FRIENDLY=1
      shift
      ;;
    --front-matter)
      FRONT_MATTER=1
      shift
      ;;
    --incremental)
      INCREMENTAL=1
      shift
      ;;
    --redact)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for --redact."
        usage
        exit 1
      fi
      append_csv_values REDACT_RULES "$2"
      shift 2
      ;;
    --drop-field)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for --drop-field."
        usage
        exit 1
      fi
      append_csv_values DROP_FIELDS "$2"
      shift 2
      ;;
    --input-file)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for --input-file."
        usage
        exit 1
      fi
      INPUT_FILE="$2"
      shift 2
      ;;
    --jql)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for --jql."
        usage
        exit 1
      fi
      JQL_QUERY="$2"
      shift 2
      ;;
    --log-format)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for --log-format."
        usage
        exit 1
      fi
      LOG_FORMAT="$2"
      shift 2
      ;;
    --batch-child)
      BATCH_CHILD=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    -V|--version)
      printf 'jira2md %s\n' "$TOOL_VERSION"
      exit 0
      ;;
    --*)
      work2md_error "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$ISSUE" ]]; then
        work2md_error "Unexpected argument: $1"
        usage
        exit 1
      fi
      ISSUE="$1"
      shift
      ;;
  esac
done
work2md_set_log_format "$LOG_FORMAT"
CONTENT_PROFILE="default"
if [[ $AI_FRIENDLY -eq 1 ]]; then
  CONTENT_PROFILE="ai-friendly"
fi

if [[ $USE_STDOUT -eq 1 && -n "$OUTPUT_DIR" ]]; then
  work2md_error "Use either --output-dir/--output or --stdout, not both."
  usage
  exit 1
fi

batch_sources=0
[[ -n "$ISSUE" ]] && batch_sources=$((batch_sources + 1))
[[ -n "$INPUT_FILE" ]] && batch_sources=$((batch_sources + 1))
[[ -n "$JQL_QUERY" ]] && batch_sources=$((batch_sources + 1))
if [[ "$batch_sources" -ne 1 ]]; then
  work2md_error "Provide exactly one input source: ISSUE_KEY_OR_URL, --input-file, or --jql."
  usage
  exit 1
fi

if [[ $USE_STDOUT -eq 1 && ( -n "$INPUT_FILE" || -n "$JQL_QUERY" ) ]]; then
  work2md_error "--stdout is only supported for single-issue exports."
  exit 1
fi

if [[ -n "$ISSUE" ]]; then
  ISSUE="$(resolve_issue_key "$ISSUE")"
fi

if [[ $USE_STDOUT -eq 1 ]]; then
  EMIT_TARGET="${EMIT_TARGET:-index}"
elif [[ -n "$EMIT_TARGET" ]]; then
  work2md_error "Use --emit only together with --stdout."
  usage
  exit 1
fi

case "${EMIT_TARGET:-}" in
  ""|index|metadata|comments) ;;
  *)
    work2md_error "Unsupported --emit target: ${EMIT_TARGET}. Use index, metadata, or comments."
    exit 1
    ;;
esac

work2md_require_not_root
work2md_require_commands curl python3
WORK2MD_AUTH_B64=""
work2md_prepare_service_auth jira WORK2MD_AUTH_B64

if [[ -n "$INPUT_FILE" && ! -f "$INPUT_FILE" ]]; then
  work2md_error "Input file not found: $INPUT_FILE"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
ISSUE_JSON_FILE="$TMP_DIR/issue.json"
COMMENTS_JSONL_FILE="$TMP_DIR/comments.jsonl"
MEDIA_MAP_SNAPSHOT_FILE="$TMP_DIR/media-map-snapshot.json"
trap 'rm -rf "$TMP_DIR"' EXIT
touch "$COMMENTS_JSONL_FILE"
printf '{}\n' > "$MEDIA_MAP_SNAPSHOT_FILE"

api_get() {
  work2md_api_get_or_die "Jira API error" "$1"
}

resolve_inputs_from_file() {
  local file_path="$1"
  local raw_line trimmed

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    trimmed="$(trim_value "$raw_line")"
    [[ -n "$trimmed" ]] || continue
    [[ "$trimmed" == \#* ]] && continue
    resolve_issue_key "$trimmed"
  done < "$file_path"
}

resolve_inputs_from_jql() {
  local query="$1"
  local start_at=0
  local max_results=100
  local search_json issues_jsonl total returned_count
  local encoded_query

  encoded_query="$(work2md_urlencode "$query")"
  while :; do
    search_json="$(api_get "${JIRA_BASE}/rest/api/3/search/jql?maxResults=${max_results}&startAt=${start_at}&fields=key&jql=${encoded_query}")"
    printf '%s\n' "$search_json" | work2md_json_helper array-field --path issues --field key
    issues_jsonl="$(printf '%s' "$search_json" | work2md_json_helper array-to-jsonl --path issues)"
    returned_count="$(printf '%s' "$issues_jsonl" | sed '/^$/d' | wc -l | awk '{print $1}')"
    total="$(printf '%s' "$search_json" | work2md_json_helper get-string --default 0 --path total)"

    if [[ "$returned_count" -eq 0 ]]; then
      break
    fi

    start_at=$((start_at + returned_count))
    if [[ "$start_at" -ge "$total" ]]; then
      break
    fi
  done
}

run_batch_export() {
  local -a inputs=()
  local -a child_args=()
  local item
  local failures=0
  local count=0

  if [[ -n "$INPUT_FILE" ]]; then
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      inputs+=("$item")
    done < <(resolve_inputs_from_file "$INPUT_FILE")
  else
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      inputs+=("$item")
    done < <(resolve_inputs_from_jql "$JQL_QUERY")
  fi

  if [[ ${#inputs[@]} -eq 0 ]]; then
    work2md_warn "No Jira issues matched the batch input."
    return 0
  fi

  if [[ -n "$OUTPUT_DIR" ]]; then
    child_args+=(--output-dir "$OUTPUT_DIR")
  fi
  if [[ $AI_FRIENDLY -eq 1 ]]; then
    child_args+=(--ai-friendly)
  fi
  if [[ $FRONT_MATTER -eq 1 ]]; then
    child_args+=(--front-matter)
  fi
  if [[ $INCREMENTAL -eq 1 ]]; then
    child_args+=(--incremental)
  fi
  if [[ "$LOG_FORMAT" != "text" ]]; then
    child_args+=(--log-format "$LOG_FORMAT")
  fi
  for item in "${REDACT_RULES[@]}"; do
    child_args+=(--redact "$item")
  done
  for item in "${DROP_FIELDS[@]}"; do
    child_args+=(--drop-field "$item")
  done

  for item in "${inputs[@]}"; do
    count=$((count + 1))
    log "Batch export ${count}/${#inputs[@]}: ${item}"
    if ! "$0" --batch-child "${child_args[@]}" "$item"; then
      failures=$((failures + 1))
      work2md_error "Failed to export Jira issue: ${item}"
    fi
  done

  if [[ "$failures" -gt 0 ]]; then
    work2md_error "Batch export completed with ${failures} failure(s)."
    return 1
  fi

  work2md_success "Batch export completed successfully for ${#inputs[@]} Jira issue(s)."
}

if [[ $BATCH_CHILD -eq 0 && ( -n "$INPUT_FILE" || -n "$JQL_QUERY" ) ]]; then
  run_batch_export
  exit $?
fi

extract_adf_media_map() {
  local issue_json_file="$1"
  local comments_jsonl_file="$2"
  python3 "$WORK2MD_SHARE_DIR/scripts/jira_media_helper.py" \
    extract-map \
    --issue-file "$issue_json_file" \
    --comments-file "$comments_jsonl_file"
}

rewrite_jira_media_paths() {
  local markdown="$1"
  local mapping_file="$2"
  local profile="${3:-default}"
  JIRA_MARKDOWN_INPUT="$markdown" python3 "$WORK2MD_SHARE_DIR/scripts/jira_media_helper.py" \
    rewrite-markdown \
    --mapping-file "$mapping_file" \
    --profile "$profile"
}

prepare_issue_media_map() {
  local issue_json_file="$1"
  local comments_jsonl_file="$2"
  local out_file="$3"
  local manifest_file="${4:-}"
  local media_map_json media_map_file asset_root attachment_key target_file content_url label
  local downloaded_targets_file checksum_registry_file
  local downloaded_count=0
  local reused_count=0
  local asset_path desired_asset_path tmp_download sha256 existing_checksum_path existing_checksum_rel
  local previous_path previous_sha previous_source_url previous_abs_path

  media_map_json="$(extract_adf_media_map "$issue_json_file" "$comments_jsonl_file")"
  if [[ -z "$media_map_json" || "$media_map_json" == "{}" ]]; then
    printf '%s' ""
    return 0
  fi

  asset_root="$(dirname "$out_file")/assets"
  mkdir -p "$asset_root"

  media_map_file="$(mktemp "$TMP_DIR/jira-media-map.XXXXXX")"
  downloaded_targets_file="$(mktemp "$TMP_DIR/jira-downloaded-targets.XXXXXX")"
  checksum_registry_file="$(mktemp "$TMP_DIR/jira-checksums.XXXXXX")"
  printf '%s\n' "$media_map_json" > "$media_map_file"

  python3 - "$media_map_file" "$asset_root" <<'PY'
import json
import os
import sys
from pathlib import Path

mapping_file = Path(sys.argv[1])
asset_root = Path(sys.argv[2]).resolve()

with mapping_file.open("r", encoding="utf-8") as fh:
    mapping = json.load(fh)

desired = set()
for entry in mapping.values():
    rel_path = str((entry or {}).get("path") or "").strip()
    label = str((entry or {}).get("label") or "").strip()
    if rel_path:
        desired.add((asset_root.parent / rel_path).resolve())
        continue
    if not label:
        continue
    desired.add((asset_root / label).resolve())

for path in asset_root.rglob("*"):
    if not path.is_file():
        continue
    resolved = path.resolve()
    if resolved not in desired:
        path.unlink()

for path in sorted(asset_root.rglob("*"), reverse=True):
    if path.is_dir():
        try:
            path.rmdir()
        except OSError:
            pass
PY

  while IFS= read -r attachment_key; do
    [[ -n "$attachment_key" ]] || continue
    content_url="$(work2md_json_helper json-map-get --file "$media_map_file" --key "$attachment_key" --field content_url --default "")"
    label="$(work2md_json_helper json-map-get --file "$media_map_file" --key "$attachment_key" --field label --default "")"
    [[ -n "$content_url" && -n "$label" ]] || continue

    desired_asset_path="assets/$label"
    asset_path="$desired_asset_path"
    target_file="$asset_root/$label"
    mkdir -p "$(dirname "$target_file")"
    if ! grep -Fqx -- "$asset_path" "$downloaded_targets_file"; then
      sha256=""
      previous_path=""
      previous_sha=""
      previous_source_url=""
      if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
        previous_path="$(work2md_json_helper file-map-get --file "$manifest_file" --path attachments --key "$attachment_key" --field path --default "")"
        previous_sha="$(work2md_json_helper file-map-get --file "$manifest_file" --path attachments --key "$attachment_key" --field sha256 --default "")"
        previous_source_url="$(work2md_json_helper file-map-get --file "$manifest_file" --path attachments --key "$attachment_key" --field content_url --default "")"
      fi

      if [[ -n "$previous_path" && -n "$previous_sha" && "$previous_source_url" == "$content_url" ]]; then
        previous_abs_path="$(dirname "$out_file")/$previous_path"
        if [[ -f "$previous_abs_path" ]]; then
          asset_path="$previous_path"
          printf '%s\t%s\t%s\n' "$previous_sha" "$previous_abs_path" "$asset_path" >> "$checksum_registry_file"
          printf '%s\n' "$asset_path" >> "$downloaded_targets_file"
          reused_count=$((reused_count + 1))
          work2md_json_helper json-map-set --file "$media_map_file" --key "$attachment_key" --field path --value "$asset_path" >/dev/null
          work2md_json_helper json-map-set --file "$media_map_file" --key "$attachment_key" --field sha256 --value "$previous_sha" >/dev/null
          continue
        fi
      fi

      tmp_download="$(mktemp "$TMP_DIR/jira-attachment.XXXXXX")"
      work2md_download_to_file "$content_url" "$tmp_download"
      sha256="$(work2md_sha256_file "$tmp_download")"
      existing_checksum_path="$(awk -F '\t' -v sha="$sha256" '$1 == sha {print $2; exit}' "$checksum_registry_file")"
      existing_checksum_rel="$(awk -F '\t' -v sha="$sha256" '$1 == sha {print $3; exit}' "$checksum_registry_file")"
      if [[ -n "$existing_checksum_path" && -f "$existing_checksum_path" && -n "$existing_checksum_rel" ]]; then
        rm -f "$tmp_download"
        asset_path="$existing_checksum_rel"
        reused_count=$((reused_count + 1))
      else
        mv -f "$tmp_download" "$target_file"
        asset_path="$desired_asset_path"
        downloaded_count=$((downloaded_count + 1))
      fi
      printf '%s\t%s\t%s\n' "$sha256" "$(dirname "$out_file")/$asset_path" "$asset_path" >> "$checksum_registry_file"
      printf '%s\n' "$asset_path" >> "$downloaded_targets_file"
    fi

    work2md_json_helper json-map-set --file "$media_map_file" --key "$attachment_key" --field path --value "$asset_path" >/dev/null
    if [[ -z "${sha256:-}" ]]; then
      sha256="$(awk -F '\t' -v rel="$asset_path" '$3 == rel {print $1; exit}' "$checksum_registry_file")"
    fi
    if [[ -n "$sha256" ]]; then
      work2md_json_helper json-map-set --file "$media_map_file" --key "$attachment_key" --field sha256 --value "$sha256" >/dev/null
    fi
  done < <(work2md_json_helper json-map-keys --file "$media_map_file")

  if [[ "$downloaded_count" -gt 0 ]]; then
    log "Downloaded ${downloaded_count} attachment(s) to: $asset_root"
  fi
  if [[ "$reused_count" -gt 0 ]]; then
    log "Reused ${reused_count} attachment(s) from prior or duplicate content."
  fi

  printf '%s' "$media_map_file"
}

adf_to_markdown() {
  python3 "$WORK2MD_SHARE_DIR/scripts/atlassian_content_to_md.py" --format jira-adf --profile "${CONTENT_PROFILE:-default}"
}

write_jira_manifest() {
  local manifest_file="$1"
  local media_map_file="${2:-}"
  local fingerprint="$3"
  local issue_sha="$4"
  local comments_sha="$5"
  local redact_serialized="$6"
  local drop_fields_serialized="$7"

  python3 - "$manifest_file" "$media_map_file" "$fingerprint" "$issue_sha" "$comments_sha" "$key" "$updated" "$CONTENT_PROFILE" "$FRONT_MATTER" "$EXPORTED_AT" "$redact_serialized" "$drop_fields_serialized" <<'PY'
import json
import pathlib
import sys

(
    manifest_path,
    media_map_path,
    fingerprint,
    issue_sha,
    comments_sha,
    issue_key,
    updated,
    content_profile,
    front_matter,
    exported_at,
    redactions,
    dropped_fields,
) = sys.argv[1:]

attachments = {}
if media_map_path:
    media_map_file = pathlib.Path(media_map_path)
    if media_map_file.exists() and media_map_file.stat().st_size > 0:
        attachments = json.loads(media_map_file.read_text(encoding="utf-8"))

payload = {
    "format": "work2md-jira-manifest-v1",
    "source": "jira",
    "source_id": issue_key,
    "content_profile": content_profile,
    "front_matter": front_matter == "1",
    "exported_at": exported_at,
    "fingerprint": fingerprint,
    "issue_updated": updated,
    "checksums": {
        "issue_json": issue_sha,
        "comments_jsonl": comments_sha,
    },
    "redactions": [item for item in redactions.split("\x1f") if item],
    "dropped_fields": [item for item in dropped_fields.split("\x1f") if item],
    "attachments": attachments,
}

pathlib.Path(manifest_path).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

log "Fetching issue $ISSUE ..."

ISSUE_JSON="$(api_get "${JIRA_BASE}/rest/api/3/issue/${ISSUE}?fields=summary,description,status,priority,labels,reporter,assignee,updated,created,issuetype,project,attachment")"
COMMENTS_JSON="$(api_get "${JIRA_BASE}/rest/api/3/issue/${ISSUE}/comment?maxResults=100")"
printf '%s\n' "$ISSUE_JSON" > "$ISSUE_JSON_FILE"
printf '%s' "$COMMENTS_JSON" | work2md_json_helper array-to-jsonl --path comments > "$COMMENTS_JSONL_FILE"
extract_adf_media_map "$ISSUE_JSON_FILE" "$COMMENTS_JSONL_FILE" > "$MEDIA_MAP_SNAPSHOT_FILE"

eval "$(printf '%s' "$ISSUE_JSON" | work2md_json_helper jira-issue-meta --default-issue "$ISSUE")"
ISSUE_SHA="$(work2md_sha256_file "$ISSUE_JSON_FILE")"
COMMENTS_SHA="$(work2md_sha256_file "$COMMENTS_JSONL_FILE")"
MEDIA_MAP_SHA="$(work2md_sha256_file "$MEDIA_MAP_SNAPSHOT_FILE")"
REDACTION_SERIALIZED="$(IFS=$'\x1f'; printf '%s' "${REDACT_RULES[*]-}")"
DROP_FIELDS_SERIALIZED="$(IFS=$'\x1f'; printf '%s' "${DROP_FIELDS[*]-}")"

desc_text="$(printf '%s\n' "$description_json" | adf_to_markdown)"
ISSUE_URL="${JIRA_BASE}/browse/${key}"

comments_md=""
comment_index=0
while IFS= read -r comment_json; do
  [[ -n "$comment_json" ]] || continue

  eval "$(printf '%s\n' "$comment_json" | work2md_json_helper jira-comment-meta)"
  comment_md="$(printf '%s\n' "$comment_body_json" | adf_to_markdown)"

  if [[ -z "$comment_md" ]]; then
    comment_md="_No comment content exported._"
  fi

  comment_index=$((comment_index + 1))
  comment_meta="- Author: ${comment_author}"$'\n'"- Created: ${comment_created}"
  if [[ -n "${comment_updated:-}" && "${comment_updated}" != "${comment_created}" ]]; then
    comment_meta+=$'\n'"- Updated: ${comment_updated}"
  fi
  if [[ -n "${comment_id:-}" ]]; then
    comment_meta+=$'\n'"- ID: ${comment_id}"
    comment_meta+=$'\n'"- URL: ${ISSUE_URL}?focusedCommentId=${comment_id}"
  fi

  if [[ -n "$comments_md" ]]; then
    comments_md+=$'\n\n'
  fi
  comments_md+="## Comment ${comment_index}"$'\n'"${comment_meta}"$'\n\n'"${comment_md}"
done < "$COMMENTS_JSONL_FILE"

if [[ -z "$comments_md" ]]; then
  comments_md="_No comments found._"
fi

INDEX_MD="$(cat <<EOF
# ${key} — ${summary}

${desc_text}
EOF
)"

COMMENTS_FILE_NAME="comments.md"
METADATA_FILE_NAME="metadata.md"
MANIFEST_FILE_NAME="manifest.json"
ASSETS_DIR_NAME="assets"
EXPORTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
OUTPUT_DIR_NAME="${ISSUE}"
if [[ "$CONTENT_PROFILE" == "ai-friendly" ]]; then
  OUTPUT_DIR_NAME+="-ai"
fi

METADATA_MD="$(cat <<EOF
# Metadata

- Source: Jira
- Title: ${summary}
- Content profile: ${CONTENT_PROFILE}
- Issue key: ${key}
- Project: ${project}
- Issue type: ${issuetype}
- Status: ${status}
EOF
)"

if [[ -n "$priority" ]]; then
  METADATA_MD+=$'\n'"- Priority: ${priority}"
fi

if [[ -n "$labels" ]]; then
  METADATA_MD+=$'\n'"- Labels: ${labels}"
fi

STABLE_METADATA_MD="$METADATA_MD"

METADATA_MD+=$(cat <<EOF

- Reporter: ${reporter}
- Assignee: ${assignee}
- Created: ${created}
- Updated: ${updated}
- URL: ${ISSUE_URL}
- Exported at: ${EXPORTED_AT}
- Exporter: work2md
- Exporter version: ${TOOL_VERSION}
- Content file: index.md
- Comments file: ${COMMENTS_FILE_NAME}
- Assets directory: ${ASSETS_DIR_NAME}/
EOF
)

STABLE_METADATA_MD+=$(cat <<EOF

- Reporter: ${reporter}
- Assignee: ${assignee}
- Created: ${created}
- Updated: ${updated}
- URL: ${ISSUE_URL}
- Exporter: work2md
- Exporter version: ${TOOL_VERSION}
- Content file: index.md
- Comments file: ${COMMENTS_FILE_NAME}
- Assets directory: ${ASSETS_DIR_NAME}/
EOF
)

COMMENTS_MD="$(cat <<EOF
# Comments

${comments_md}
EOF
)"

STABLE_METADATA_MD="$(filter_metadata_markdown "$STABLE_METADATA_MD")"
EXPORT_FINGERPRINT="$(compute_export_fingerprint "$STABLE_METADATA_MD" "$INDEX_MD" "$COMMENTS_MD" "$MEDIA_MAP_SHA" "$CONTENT_PROFILE" "$FRONT_MATTER" "$REDACTION_SERIALIZED")"
METADATA_MD="$(filter_metadata_markdown "$METADATA_MD")"

MEDIA_MAP_FILE=""
if [[ $USE_STDOUT -eq 0 ]]; then
  OUT_DIR="$(work2md_resolve_output_dir "$OUTPUT_DIR" "jira" "$OUTPUT_DIR_NAME")"
  OUT_FILE="$OUT_DIR/index.md"
  METADATA_FILE="$OUT_DIR/$METADATA_FILE_NAME"
  COMMENTS_FILE="$OUT_DIR/$COMMENTS_FILE_NAME"
  MANIFEST_FILE="$OUT_DIR/$MANIFEST_FILE_NAME"
  if [[ $INCREMENTAL -eq 1 && -f "$MANIFEST_FILE" ]]; then
    PREVIOUS_FINGERPRINT="$(work2md_json_helper get-string-file --file "$MANIFEST_FILE" --default "" --path fingerprint)"
    if [[ "$PREVIOUS_FINGERPRINT" == "$EXPORT_FINGERPRINT" ]]; then
      log "No Jira changes detected for $ISSUE; keeping existing export."
      work2md_success "Jira export is already up to date: $OUT_DIR"
      log "Config: $WORK2MD_CONFIG_FILE"
      exit 0
    fi
  fi
  MEDIA_MAP_FILE="$(prepare_issue_media_map "$ISSUE_JSON_FILE" "$COMMENTS_JSONL_FILE" "$OUT_FILE" "$MANIFEST_FILE")"
  if [[ -n "$MEDIA_MAP_FILE" ]]; then
    INDEX_MD="$(rewrite_jira_media_paths "$INDEX_MD" "$MEDIA_MAP_FILE" "$CONTENT_PROFILE")"
    COMMENTS_MD="$(rewrite_jira_media_paths "$COMMENTS_MD" "$MEDIA_MAP_FILE" "$CONTENT_PROFILE")"
  fi
fi

INDEX_MD="$(prepend_front_matter "$METADATA_MD" "$INDEX_MD")"
INDEX_MD="$(redact_text "$INDEX_MD" "$JIRA_BASE")"
METADATA_MD="$(redact_text "$METADATA_MD" "$JIRA_BASE")"
COMMENTS_MD="$(redact_text "$COMMENTS_MD" "$JIRA_BASE")"

if [[ $USE_STDOUT -eq 1 ]]; then
  case "$EMIT_TARGET" in
    index) printf '%s\n' "$INDEX_MD" ;;
    metadata) printf '%s\n' "$METADATA_MD" ;;
    comments) printf '%s\n' "$COMMENTS_MD" ;;
  esac
else
  printf '%s\n' "$INDEX_MD" > "$OUT_FILE"
  printf '%s\n' "$METADATA_MD" > "$METADATA_FILE"
  printf '%s\n' "$COMMENTS_MD" > "$COMMENTS_FILE"
  write_jira_manifest "$MANIFEST_FILE" "$MEDIA_MAP_FILE" "$EXPORT_FINGERPRINT" "$ISSUE_SHA" "$COMMENTS_SHA" "$REDACTION_SERIALIZED" "$DROP_FIELDS_SERIALIZED"
  log "Saved to: $OUT_FILE"
  log "Saved to: $METADATA_FILE"
  log "Saved to: $COMMENTS_FILE"
  log "Saved to: $MANIFEST_FILE"
  work2md_success "Jira export completed successfully: $OUT_DIR"
fi

log "Config: $WORK2MD_CONFIG_FILE"
