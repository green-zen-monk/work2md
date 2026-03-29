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

# confluence2md
# Usage: confluence2md PAGE_ID_OR_URL [--output-dir PATH] [--stdout] [--emit TARGET] [--ai-friendly] [--version]
# Exports a Confluence Cloud page -> Markdown
# - config: ~/.config/work2md/config
# - default output: ./docs/confluence/PAGE_ID-slug/index.md
# - --output-dir PATH: write the full export bundle under the given directory
# - --stdout: print one selected artifact to stdout and do not write files
# - --emit TARGET: one of index, metadata, comments (default: index when used with --stdout)
# - --ai-friendly: produce a linearized AI-friendly variant and store it in a separate -ai directory

print_usage() {
  cat <<'EOF'
Usage: confluence2md PAGE_ID_OR_URL [--output-dir PATH] [--stdout] [--emit TARGET] [--ai-friendly] [--front-matter] [--redact RULES] [--drop-field FIELDS] [--incremental] [--version]
       confluence2md --input-file PATH [--output-dir PATH] [--ai-friendly] [--front-matter] [--redact RULES] [--drop-field FIELDS] [--incremental]
       confluence2md --cql QUERY [--output-dir PATH] [--ai-friendly] [--front-matter] [--redact RULES] [--drop-field FIELDS] [--incremental]
Examples:
  confluence2md 123456789
  confluence2md 123456789 --output-dir ./export
  confluence2md 123456789 --stdout
  confluence2md 123456789 --stdout --emit comments
  confluence2md --input-file ./pages.txt --front-matter --redact email,internal-url
  confluence2md --cql 'type = page order by lastmodified desc' --incremental
  confluence2md 123456789 --ai-friendly
  confluence2md https://company.atlassian.net/wiki/spaces/TEAM/pages/123456789/Page+Title
  confluence2md --version
EOF
}

usage() {
  print_usage >&2
}

log() {
  work2md_info "$@"
}

debug_log() {
  if [[ "${DEBUG_MODE:-0}" -eq 1 ]]; then
    work2md_info "[debug] $*"
  fi
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

INPUT=""
OUTPUT_DIR=""
USE_STDOUT=0
DEBUG_MODE=0
EMIT_TARGET=""
AI_FRIENDLY=0
FRONT_MATTER=0
INCREMENTAL=0
INPUT_FILE=""
CQL_QUERY=""
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
    --cql)
      if [[ $# -lt 2 ]]; then
        work2md_error "Missing value for --cql."
        usage
        exit 1
      fi
      CQL_QUERY="$2"
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
    --debug)
      DEBUG_MODE=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    -V|--version)
      printf 'confluence2md %s\n' "$TOOL_VERSION"
      exit 0
      ;;
    --*)
      work2md_error "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$INPUT" ]]; then
        work2md_error "Unexpected argument: $1"
        usage
        exit 1
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

work2md_set_log_format "$LOG_FORMAT"

if [[ $USE_STDOUT -eq 1 && -n "$OUTPUT_DIR" ]]; then
  work2md_error "Use either --output-dir/--output or --stdout, not both."
  usage
  exit 1
fi

if [[ $USE_STDOUT -eq 1 ]]; then
  EMIT_TARGET="${EMIT_TARGET:-index}"
elif [[ -n "$EMIT_TARGET" ]]; then
  work2md_error "Use --emit only together with --stdout."
  usage
  exit 1
fi

input_sources=0
[[ -n "$INPUT" ]] && input_sources=$((input_sources + 1))
[[ -n "$INPUT_FILE" ]] && input_sources=$((input_sources + 1))
[[ -n "$CQL_QUERY" ]] && input_sources=$((input_sources + 1))
if [[ "$input_sources" -ne 1 ]]; then
  work2md_error "Provide exactly one input source: PAGE_ID_OR_URL, --input-file, or --cql."
  usage
  exit 1
fi

if [[ $USE_STDOUT -eq 1 && ( -n "$INPUT_FILE" || -n "$CQL_QUERY" ) ]]; then
  work2md_error "--stdout is only supported for single-page exports."
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
work2md_prepare_service_auth confluence WORK2MD_AUTH_B64

if [[ -n "$INPUT_FILE" && ! -f "$INPUT_FILE" ]]; then
  work2md_error "Input file not found: $INPUT_FILE"
  exit 1
fi

resolve_page_id() {
  local value="$1"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [[ "$value" =~ /pages/([0-9]+)(/|$|\?) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$value" =~ ^https?:// ]] && [[ "$value" =~ pageId=([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  work2md_error "Unsupported input: expected a numeric Page ID or a Confluence page URL containing /pages/{id}."
  exit 1
}

slugify() {
  python3 - "$1" <<'PY'
import re
import sys
import unicodedata

value = sys.argv[1]
value = unicodedata.normalize("NFKD", value)
value = value.encode("ascii", "ignore").decode("ascii")
value = value.lower()
value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
print(value)
PY
}

storage_to_markdown() {
  local panel_map_file="${1:-}"
  local profile="${CONTENT_PROFILE:-default}"

  if [[ -n "$panel_map_file" ]]; then
    python3 "$WORK2MD_SHARE_DIR/scripts/atlassian_content_to_md.py" --format confluence-storage --profile "$profile" --confluence-panel-map "$panel_map_file"
    return 0
  fi

  python3 "$WORK2MD_SHARE_DIR/scripts/atlassian_content_to_md.py" --format confluence-storage --profile "$profile"
}

CONTENT_PROFILE="default"
if [[ $AI_FRIENDLY -eq 1 ]]; then
  CONTENT_PROFILE="ai-friendly"
fi

api_get() {
  local url="$1"
  local http_code body

  work2md_http_request GET "$url" || return 1
  http_code="$WORK2MD_HTTP_STATUS"
  body="$WORK2MD_HTTP_BODY"

  case "$http_code" in
    200)
      printf '%s\n' "$body"
      ;;
    401|403)
      work2md_error "Confluence API error ($http_code): authentication failed or access is denied."
      echo "$body" >&2
      exit 1
      ;;
    404)
      work2md_error "Confluence API error (404): page not found: $PAGE_ID"
      echo "$body" >&2
      exit 1
      ;;
    *)
      work2md_error "Confluence API error ($http_code)"
      echo "$body" >&2
      exit 1
      ;;
  esac
}

api_get_optional() {
  work2md_api_get_optional "$1"
}

api_post_optional() {
  work2md_api_post_optional "$1" "$2"
}

resolve_inputs_from_file() {
  local file_path="$1"
  local raw_line trimmed

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    trimmed="$(trim_value "$raw_line")"
    [[ -n "$trimmed" ]] || continue
    [[ "$trimmed" == \#* ]] && continue
    resolve_page_id "$trimmed"
  done < "$file_path"
}

resolve_inputs_from_cql() {
  local query="$1"
  local start=0
  local limit=100
  local search_json results_jsonl returned_count size
  local encoded_query

  encoded_query="$(work2md_urlencode "$query")"
  while :; do
    search_json="$(api_get "${CONFLUENCE_BASE}/wiki/rest/api/search?cql=${encoded_query}&limit=${limit}&start=${start}")"
    printf '%s\n' "$search_json" | work2md_json_helper array-field --path results --field content.id
    results_jsonl="$(printf '%s' "$search_json" | work2md_json_helper array-to-jsonl --path results)"
    returned_count="$(printf '%s' "$results_jsonl" | sed '/^$/d' | wc -l | awk '{print $1}')"
    size="$(printf '%s' "$search_json" | work2md_json_helper get-string --default 0 --path size)"

    if [[ "$returned_count" -eq 0 || "$size" -eq 0 ]]; then
      break
    fi

    start=$((start + returned_count))
    if [[ "$returned_count" -lt "$limit" ]]; then
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
    done < <(resolve_inputs_from_cql "$CQL_QUERY")
  fi

  if [[ ${#inputs[@]} -eq 0 ]]; then
    work2md_warn "No Confluence pages matched the batch input."
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
  if [[ $DEBUG_MODE -eq 1 ]]; then
    child_args+=(--debug)
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
      work2md_error "Failed to export Confluence page: ${item}"
    fi
  done

  if [[ "$failures" -gt 0 ]]; then
    work2md_error "Batch export completed with ${failures} failure(s)."
    return 1
  fi

  work2md_success "Batch export completed successfully for ${#inputs[@]} Confluence page(s)."
}

if [[ $BATCH_CHILD -eq 0 && ( -n "$INPUT_FILE" || -n "$CQL_QUERY" ) ]]; then
  run_batch_export
  exit $?
fi

PAGE_ID="$(resolve_page_id "$INPUT")"

debug_body_candidates() {
  local label="$1"
  local json="$2"

  [[ "${DEBUG_MODE:-0}" -eq 1 ]] || return 0

  printf '%s' "$json" | work2md_json_helper debug-body-candidates --label "$label" >&2
}

extract_body_value() {
  work2md_json_helper body-value
}

extract_body_field() {
  local field="$1"

  work2md_json_helper body-field --field "$field"
}

extract_adf_body() {
  work2md_json_helper adf-body
}

extract_adf_panel_map() {
  python3 /dev/fd/3 3<<'PY'
import json
import sys

raw = sys.stdin.read().strip()
if not raw or raw == '""':
    print("{}")
    raise SystemExit(0)

try:
    adf = json.loads(raw)
except json.JSONDecodeError:
    print("{}")
    raise SystemExit(0)

if isinstance(adf, str):
    try:
        adf = json.loads(adf)
    except json.JSONDecodeError:
        print("{}")
        raise SystemExit(0)

mapping: dict[str, dict[str, str]] = {}

def walk(node):
    if isinstance(node, dict):
        if node.get("type") == "panel":
            attrs = node.get("attrs") or {}
            local_id = str(attrs.get("localId") or "").strip()
            panel_type = str(attrs.get("panelType") or "").strip()
            panel_icon_text = str(attrs.get("panelIconText") or "").strip()
            if local_id:
                mapping[local_id] = {
                    "panelType": panel_type,
                    "panelIconText": panel_icon_text,
                }
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)

walk(adf)
print(json.dumps(mapping, ensure_ascii=False))
PY
}

render_body_candidate() {
  local json="$1"
  local field="$2"
  local context="$3"
  local panel_map_file="${4:-}"
  local candidate_body rendered_md

  candidate_body="$(printf '%s' "$json" | extract_body_field "$field")"
  debug_log "${context} candidate ${field} body length: ${#candidate_body}"
  [[ -n "$candidate_body" ]] || return 1

  rendered_md="$(printf '%s' "$candidate_body" | storage_to_markdown "$panel_map_file")"
  debug_log "${context} candidate ${field} markdown length: ${#rendered_md}"
  [[ -n "$rendered_md" ]] || return 1

  printf '%s' "$rendered_md"
}

convert_adf_to_view() {
  local adf_body="$1"
  local payload async_json async_id result_json status
  local attempt

  [[ -z "$adf_body" || "$adf_body" == "\"\"" ]] && return 1

  payload="$(python3 - "$adf_body" <<'PY'
import json
import sys

print(json.dumps({"value": sys.argv[1], "representation": "atlas_doc_format"}, ensure_ascii=False))
PY
)"

  async_json="$(api_post_optional "${CONFLUENCE_BASE}/wiki/rest/api/contentbody/convert/async/view?contentIdContext=${PAGE_ID}" "$payload")" || return 1
  async_id="$(printf '%s' "$async_json" | work2md_json_helper get-string --default "" --path asyncId)"
  [[ -z "$async_id" ]] && return 1

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    result_json="$(api_get_optional "${CONFLUENCE_BASE}/wiki/rest/api/contentbody/convert/async/${async_id}")" || return 1
    status="$(printf '%s' "$result_json" | work2md_json_helper get-string --default "" --path status)"

    case "$status" in
      ""|COMPLETE)
        printf '%s' "$result_json" | work2md_json_helper get-string --default "" --path value
        return 0
        ;;
      WORKING|PENDING|QUEUED)
        sleep 1
        ;;
      *)
        return 1
        ;;
    esac
  done

  return 1
}

fetch_v2_page_json() {
  local page_id="$1"
  local format="$2"
  local page_json

  page_json="$(api_get_optional "${CONFLUENCE_BASE}/wiki/api/v2/pages/${page_id}?body-format=${format}&include-version=true")" || return 1
  debug_body_candidates "v2-page-${format}" "$page_json"
  printf '%s\n' "$page_json"
}

fetch_all_comments() {
  local page_id="$1"
  local start=0
  local limit=100
  local page_json size total

  while :; do
    page_json="$(api_get "${CONFLUENCE_BASE}/wiki/rest/api/content/${page_id}/child/comment?expand=body.storage,body.view,body.export_view,body.styled_view,version,history&limit=${limit}&start=${start}")"

    printf '%s' "$page_json" | work2md_json_helper array-to-jsonl --path results >> "$COMMENTS_JSONL_FILE"
    eval "$(printf '%s' "$page_json" | work2md_json_helper confluence-list-meta)"

    if [[ "$size" == "0" ]]; then
      break
    fi

    start=$((start + size))

    if [[ -n "$total" && "$start" -ge "$total" ]]; then
      break
    fi

    if [[ "$size" -lt "$limit" ]]; then
      break
    fi
  done
}

fetch_v2_footer_comments() {
  local page_id="$1"
  local cursor=""
  local url page_json next_relative next_url

  while :; do
    url="${CONFLUENCE_BASE}/wiki/api/v2/pages/${page_id}/footer-comments?body-format=storage&limit=100"
    if [[ -n "$cursor" ]]; then
      url+="&cursor=${cursor}"
    fi

    page_json="$(api_get_optional "$url")" || break
    printf '%s' "$page_json" | work2md_json_helper array-to-jsonl --path results >> "$COMMENTS_JSONL_FILE"

    next_relative="$(printf '%s' "$page_json" | work2md_json_helper get-string --default "" --path _links.next)"
    if [[ -z "$next_relative" ]]; then
      break
    fi

    if [[ "$next_relative" =~ ^https?:// ]]; then
      next_url="$next_relative"
    else
      next_url="${CONFLUENCE_BASE}${next_relative}"
    fi

    cursor="$(printf '%s\n' "$next_url" | sed -n 's/.*[?&]cursor=\([^&]*\).*/\1/p')"
    if [[ -z "$cursor" ]]; then
      break
    fi
  done
}

extract_storage_image_filenames() {
  python3 /dev/fd/3 3<<'PY'
import html
import re
import sys

raw = sys.stdin.read()
seen: set[str] = set()

pattern = re.compile(
    r"<ac:image\b.*?<ri:attachment\b[^>]*ri:filename=\"([^\"]+)\"",
    re.IGNORECASE | re.DOTALL,
)

for match in pattern.finditer(raw):
    filename = html.unescape(match.group(1)).strip()
    if not filename or filename in seen:
        continue
    seen.add(filename)
    print(filename)
PY
}

fetch_all_attachments() {
  local page_id="$1"
  local start=0
  local limit=100
  local page_json size total

  : > "$ATTACHMENTS_JSONL_FILE"

  while :; do
    page_json="$(api_get_optional "${CONFLUENCE_BASE}/wiki/rest/api/content/${page_id}/child/attachment?limit=${limit}&start=${start}")" || break
    printf '%s' "$page_json" | work2md_json_helper array-to-jsonl --path results >> "$ATTACHMENTS_JSONL_FILE"

    eval "$(printf '%s' "$page_json" | work2md_json_helper confluence-list-meta)"

    if [[ "$size" == "0" ]]; then
      break
    fi

    start=$((start + size))

    if [[ -n "$total" && "$start" -ge "$total" ]]; then
      break
    fi

    if [[ "$size" -lt "$limit" ]]; then
      break
    fi
  done
}

extract_confluence_attachment_map() {
  local page_json_file="$1"
  local comments_jsonl_file="$2"
  local page_id="$3"
  local link_base="$4"

  python3 "$WORK2MD_SHARE_DIR/scripts/confluence_attachment_helper.py" \
    extract-map \
    --page-file "$page_json_file" \
    --comments-file "$comments_jsonl_file" \
    --page-id "$page_id" \
    --link-base "$link_base"
}

build_confluence_rewrite_map() {
  local attachment_map_file="$1"
  local asset_prefix="${2:-assets}"

  python3 "$WORK2MD_SHARE_DIR/scripts/confluence_attachment_helper.py" \
    build-rewrite-map \
    --mapping-file "$attachment_map_file" \
    --asset-prefix "$asset_prefix"
}

rewrite_markdown_attachment_paths() {
  local markdown="$1"
  local mapping_file="$2"

  MARKDOWN_INPUT="$markdown" python3 - "$mapping_file" <<'PY'
import json
import os
import re
import sys

mapping_path = sys.argv[1]
with open(mapping_path, "r", encoding="utf-8") as fh:
    mapping = json.load(fh)

text = os.environ.get("MARKDOWN_INPUT", "")
pattern = re.compile(r'(\!?\[[^\]]*\]\()([^)\n]+)(\))')
html_attr_pattern = re.compile(r'((?:src|href)=["\'])([^"\']+)(["\'])')

def normalize_destination(value: str) -> str:
    value = value.strip()
    if value.startswith("<") and value.endswith(">"):
        return value[1:-1].strip()
    return value

def repl(match: re.Match[str]) -> str:
    destination = match.group(2)
    replacement = mapping.get(destination) or mapping.get(normalize_destination(destination))
    if replacement is None:
        return match.group(0)
    return f"{match.group(1)}<{replacement}>{match.group(3)}"

text = pattern.sub(repl, text)

def html_attr_repl(match: re.Match[str]) -> str:
    destination = match.group(2)
    replacement = mapping.get(destination) or mapping.get(normalize_destination(destination))
    if replacement is None:
        return match.group(0)
    return f"{match.group(1)}{replacement}{match.group(3)}"

sys.stdout.write(html_attr_pattern.sub(html_attr_repl, text))
PY
}

extract_mention_map() {
  local page_json_file="$1"
  local comments_jsonl_file="$2"

  python3 - "$page_json_file" "$comments_jsonl_file" "$CONFLUENCE_BASE" "$CONFLUENCE_LINK_BASE" <<'PY'
import json
import sys
from html.parser import HTMLParser

page_json_file = sys.argv[1]
comments_jsonl_file = sys.argv[2]
site_base = sys.argv[3].rstrip("/")
wiki_base = sys.argv[4].rstrip("/")


def absolutize_href(href: str) -> str:
    href = (href or "").strip()
    if not href:
        return ""
    if href.startswith(("http://", "https://")):
        return href
    if href.startswith("/"):
        return site_base + href
    return wiki_base + "/" + href.lstrip("/")


class MentionParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.mapping: dict[str, dict[str, str]] = {}
        self.current: dict[str, str | list[str]] | None = None

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag != "a":
            return
        attr_map = {key: value for key, value in attrs}
        account_id = (attr_map.get("data-account-id") or "").strip()
        if not account_id:
            return
        href = absolutize_href(attr_map.get("href") or "")
        self.current = {"account_id": account_id, "href": href, "parts": []}

    def handle_data(self, data: str) -> None:
        if self.current is None:
            return
        parts = self.current["parts"]
        if isinstance(parts, list):
            parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag != "a" or self.current is None:
            return
        account_id = str(self.current.get("account_id") or "").strip()
        href = str(self.current.get("href") or "").strip()
        parts = self.current.get("parts") or []
        name = "".join(parts).strip() if isinstance(parts, list) else ""
        if account_id:
            record = self.mapping.setdefault(account_id, {})
            if name and not record.get("name"):
                record["name"] = name
            if href and not record.get("href"):
                record["href"] = href
        self.current = None


def feed_html(parser: MentionParser, raw_html: str) -> None:
    raw_html = (raw_html or "").strip()
    if not raw_html:
        return
    parser.feed(raw_html)


parser = MentionParser()

with open(page_json_file, "r", encoding="utf-8") as fh:
    page_json = json.load(fh)
feed_html(parser, (((page_json.get("body") or {}).get("view") or {}).get("value") or ""))

with open(comments_jsonl_file, "r", encoding="utf-8") as fh:
    for raw_line in fh:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        item = json.loads(raw_line)
        feed_html(parser, (((item.get("body") or {}).get("view") or {}).get("value") or ""))

json.dump(parser.mapping, sys.stdout, ensure_ascii=False)
PY
}

rewrite_user_mentions() {
  local markdown="$1"
  local mapping_file="$2"
  local profile="${3:-default}"

  USER_MENTION_INPUT="$markdown" python3 - "$mapping_file" "$profile" <<'PY'
import json
import os
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    mapping = json.load(fh)

profile = sys.argv[2]

text = os.environ.get("USER_MENTION_INPUT", "")
pattern = re.compile(r"__WORK2MD_USER_MENTION__([A-Za-z0-9:._-]+)__")


def escape_label(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("[", "\\[")
        .replace("]", "\\]")
    )


def repl(match: re.Match[str]) -> str:
    account_id = match.group(1)
    entry = mapping.get(account_id) or {}
    name = str(entry.get("name") or "").strip()
    href = str(entry.get("href") or "").strip()
    if profile == "ai-friendly":
        if name:
            return name
        if href:
            return href
        return "@mentioned-user"
    if name and href:
        return f"[{escape_label(name)}](<{href}>)"
    if name:
        return name
    if href:
        return f"<{href}>"
    return "@mentioned-user"


sys.stdout.write(pattern.sub(repl, text))
PY
}

replace_attachments_macro() {
  local markdown="$1"
  local attachment_map_file="$2"
  local rewrite_map_file="$3"

  ATTACHMENTS_MARKDOWN_INPUT="$markdown" python3 - "$attachment_map_file" "$rewrite_map_file" <<'PY'
import json
import os
import sys

attachment_map_path = sys.argv[1]
rewrite_map_path = sys.argv[2]

with open(attachment_map_path, "r", encoding="utf-8") as fh:
    attachment_map = json.load(fh)

with open(rewrite_map_path, "r", encoding="utf-8") as fh:
    rewrite_map = json.load(fh)

lines = []
for title in attachment_map.keys():
    destination = rewrite_map.get(title)
    if not destination:
        continue
    lines.append(f"- [{title}](<{destination}>)")

replacement = "\n".join(lines) if lines else "_No attachments exported._"
text = os.environ.get("ATTACHMENTS_MARKDOWN_INPUT", "")
sys.stdout.write(text.replace("__WORK2MD_ATTACHMENTS_MACRO__", replacement))
PY
}

prepare_page_attachments() {
  local page_json_file="$1"
  local comments_jsonl_file="$2"
  local page_id="$3"
  local link_base="$4"
  local out_file="$5"
  local manifest_file="${6:-}"
  local attachment_map_snapshot_file="${7:-}"
  local asset_root target_file filename download_url
  local downloaded_count=0
  local reused_count=0
  local attachment_map_json attachment_map_file rewrite_map_file downloaded_targets_file checksum_registry_file
  local previous_path previous_sha previous_source_url previous_abs_path tmp_download sha256 existing_checksum_path existing_checksum_rel

  CONFLUENCE_ATTACHMENT_MAP_FILE=""
  ATTACHMENT_REWRITE_MAP_FILE=""

  if [[ -n "$attachment_map_snapshot_file" && -f "$attachment_map_snapshot_file" ]]; then
    attachment_map_json="$(cat "$attachment_map_snapshot_file")"
  else
    attachment_map_json="$(extract_confluence_attachment_map "$page_json_file" "$comments_jsonl_file" "$page_id" "$link_base")"
  fi
  if [[ -z "$attachment_map_json" || "$attachment_map_json" == "{}" ]]; then
    return 0
  fi

  asset_root="$(dirname "$out_file")/assets"
  mkdir -p "$asset_root"

  attachment_map_file="$(mktemp "$TMP_DIR/confluence-attachment-map.XXXXXX")"
  downloaded_targets_file="$(mktemp "$TMP_DIR/confluence-downloaded-targets.XXXXXX")"
  checksum_registry_file="$(mktemp "$TMP_DIR/confluence-checksums.XXXXXX")"
  printf '%s\n' "$attachment_map_json" > "$attachment_map_file"
  CONFLUENCE_ATTACHMENT_MAP_FILE="$attachment_map_file"

  python3 - "$attachment_map_file" "$asset_root" <<'PY'
import json
import sys
from pathlib import Path

mapping_path = Path(sys.argv[1])
asset_root = Path(sys.argv[2]).resolve()

with mapping_path.open("r", encoding="utf-8") as fh:
    mapping = json.load(fh)

desired = set()
for filename, entry in mapping.items():
    rel_path = str((entry or {}).get("path") or "").strip()
    if rel_path:
        desired.add((asset_root.parent / rel_path).resolve())
        continue
    desired.add((asset_root / filename).resolve())

for path in asset_root.rglob("*"):
    if path.is_file() and path.resolve() not in desired:
        path.unlink()

for path in sorted(asset_root.rglob("*"), reverse=True):
    if path.is_dir():
        try:
            path.rmdir()
        except OSError:
            pass
PY

  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    download_url="$(work2md_json_helper json-map-get --file "$attachment_map_file" --key "$filename" --field download_url --default "")"
    [[ -n "$download_url" ]] || continue
    target_file="$asset_root/$filename"
    mkdir -p "$(dirname "$target_file")"
    if ! grep -Fqx -- "$filename" "$downloaded_targets_file"; then
      sha256=""
      previous_path=""
      previous_sha=""
      previous_source_url=""
      if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
        previous_path="$(work2md_json_helper file-map-get --file "$manifest_file" --path attachments --key "$filename" --field path --default "")"
        previous_sha="$(work2md_json_helper file-map-get --file "$manifest_file" --path attachments --key "$filename" --field sha256 --default "")"
        previous_source_url="$(work2md_json_helper file-map-get --file "$manifest_file" --path attachments --key "$filename" --field download_url --default "")"
      fi

      if [[ -n "$previous_path" && -n "$previous_sha" && "$previous_source_url" == "$download_url" ]]; then
        previous_abs_path="$(dirname "$out_file")/$previous_path"
        if [[ -f "$previous_abs_path" ]]; then
          work2md_json_helper json-map-set --file "$attachment_map_file" --key "$filename" --field path --value "$previous_path" >/dev/null
          work2md_json_helper json-map-set --file "$attachment_map_file" --key "$filename" --field sha256 --value "$previous_sha" >/dev/null
          printf '%s\t%s\t%s\n' "$previous_sha" "$previous_abs_path" "$previous_path" >> "$checksum_registry_file"
          printf '%s\n' "$previous_path" >> "$downloaded_targets_file"
          reused_count=$((reused_count + 1))
          continue
        fi
      fi

      tmp_download="$(mktemp "$TMP_DIR/confluence-attachment.XXXXXX")"
      work2md_download_to_file "$download_url" "$tmp_download"
      sha256="$(work2md_sha256_file "$tmp_download")"
      existing_checksum_path="$(awk -F '\t' -v sha="$sha256" '$1 == sha {print $2; exit}' "$checksum_registry_file")"
      existing_checksum_rel="$(awk -F '\t' -v sha="$sha256" '$1 == sha {print $3; exit}' "$checksum_registry_file")"
      if [[ -n "$existing_checksum_path" && -f "$existing_checksum_path" && -n "$existing_checksum_rel" ]]; then
        rm -f "$tmp_download"
        work2md_json_helper json-map-set --file "$attachment_map_file" --key "$filename" --field path --value "$existing_checksum_rel" >/dev/null
        reused_count=$((reused_count + 1))
      else
        mv -f "$tmp_download" "$target_file"
        work2md_json_helper json-map-set --file "$attachment_map_file" --key "$filename" --field path --value "assets/$filename" >/dev/null
        downloaded_count=$((downloaded_count + 1))
      fi
      work2md_json_helper json-map-set --file "$attachment_map_file" --key "$filename" --field sha256 --value "$sha256" >/dev/null
      printf '%s\t%s\t%s\n' "$sha256" "$(dirname "$out_file")/$(work2md_json_helper json-map-get --file "$attachment_map_file" --key "$filename" --field path --default "assets/$filename")" "$(work2md_json_helper json-map-get --file "$attachment_map_file" --key "$filename" --field path --default "assets/$filename")" >> "$checksum_registry_file"
      printf '%s\n' "$(work2md_json_helper json-map-get --file "$attachment_map_file" --key "$filename" --field path --default "assets/$filename")" >> "$downloaded_targets_file"
    fi
  done < <(work2md_json_helper json-map-keys --file "$attachment_map_file")

  rewrite_map_file="$(mktemp "$TMP_DIR/confluence-rewrite-map.XXXXXX")"
  build_confluence_rewrite_map "$attachment_map_file" "assets" > "$rewrite_map_file"

  if [[ "$downloaded_count" -gt 0 ]]; then
    log "Downloaded ${downloaded_count} attachment(s) to: $asset_root"
  fi
  if [[ "$reused_count" -gt 0 ]]; then
    log "Reused ${reused_count} attachment(s) from prior or duplicate content."
  fi

  ATTACHMENT_REWRITE_MAP_FILE="$rewrite_map_file"
}

write_confluence_manifest() {
  local manifest_file="$1"
  local attachment_map_file="${2:-}"
  local fingerprint="$3"
  local page_sha="$4"
  local comments_sha="$5"
  local attachments_sha="$6"
  local attachment_map_sha="$7"
  local redact_serialized="$8"
  local drop_fields_serialized="$9"

  python3 - "$manifest_file" "$attachment_map_file" "$fingerprint" "$page_sha" "$comments_sha" "$attachments_sha" "$attachment_map_sha" "$page_id" "$updated" "$CONTENT_PROFILE" "$FRONT_MATTER" "$EXPORTED_AT" "$redact_serialized" "$drop_fields_serialized" <<'PY'
import json
import pathlib
import sys

(
    manifest_path,
    attachment_map_path,
    fingerprint,
    page_sha,
    comments_sha,
    attachments_sha,
    attachment_map_sha,
    page_id,
    updated,
    content_profile,
    front_matter,
    exported_at,
    redactions,
    dropped_fields,
) = sys.argv[1:]

attachments = {}
if attachment_map_path:
    mapping_file = pathlib.Path(attachment_map_path)
    if mapping_file.exists() and mapping_file.stat().st_size > 0:
        attachments = json.loads(mapping_file.read_text(encoding="utf-8"))

payload = {
    "format": "work2md-confluence-manifest-v1",
    "source": "confluence",
    "source_id": page_id,
    "content_profile": content_profile,
    "front_matter": front_matter == "1",
    "exported_at": exported_at,
    "fingerprint": fingerprint,
    "page_updated": updated,
    "checksums": {
        "page_json": page_sha,
        "comments_jsonl": comments_sha,
        "attachments_jsonl": attachments_sha,
        "attachment_map_json": attachment_map_sha,
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

TMP_DIR="$(mktemp -d)"
PAGE_JSON_FILE="$TMP_DIR/page.json"
COMMENTS_JSONL_FILE="$TMP_DIR/comments.jsonl"
ATTACHMENTS_JSONL_FILE="$TMP_DIR/attachments.jsonl"
MENTION_MAP_FILE="$TMP_DIR/mentions.json"
PANEL_MAP_FILE="$TMP_DIR/panels.json"
ATTACHMENT_MAP_SNAPSHOT_FILE="$TMP_DIR/attachment-map-snapshot.json"
trap 'rm -rf "$TMP_DIR"' EXIT
touch "$COMMENTS_JSONL_FILE"
touch "$ATTACHMENTS_JSONL_FILE"
printf '{}\n' > "$MENTION_MAP_FILE"
printf '{}\n' > "$PANEL_MAP_FILE"
printf '{}\n' > "$ATTACHMENT_MAP_SNAPSHOT_FILE"

log "Fetching Confluence page $PAGE_ID ..."

PAGE_JSON="$(api_get "${CONFLUENCE_BASE}/wiki/rest/api/content/${PAGE_ID}?expand=body.storage,body.view,body.export_view,body.styled_view,version,space,history")"
printf '%s\n' "$PAGE_JSON" > "$PAGE_JSON_FILE"
CONFLUENCE_LINK_BASE="$(printf '%s' "$PAGE_JSON" | work2md_json_helper get-string --default "" --path _links.base)"
if [[ -z "$CONFLUENCE_LINK_BASE" ]]; then
  CONFLUENCE_LINK_BASE="${CONFLUENCE_BASE}/wiki"
fi
debug_body_candidates "v1-page" "$PAGE_JSON"
fetch_all_comments "$PAGE_ID"
fetch_all_attachments "$PAGE_ID"
extract_mention_map "$PAGE_JSON_FILE" "$COMMENTS_JSONL_FILE" > "$MENTION_MAP_FILE"
v2_adf_json="$(fetch_v2_page_json "$PAGE_ID" "atlas_doc_format" || true)"
if [[ -n "$v2_adf_json" ]]; then
  adf_panel_body="$(echo "$v2_adf_json" | extract_adf_body)"
  if [[ -n "$adf_panel_body" && "$adf_panel_body" != "\"\"" ]]; then
    printf '%s' "$adf_panel_body" | extract_adf_panel_map > "$PANEL_MAP_FILE"
    debug_log "panel map bytes: $(wc -c < "$PANEL_MAP_FILE")"
  fi
fi

body_md=""
page_render_source=""
adf_body=""
page_body_field=""
page_body_raw=""

v2_storage_json="$(fetch_v2_page_json "$PAGE_ID" "storage" || true)"
if [[ -n "$v2_storage_json" ]]; then
  candidate_body="$(printf '%s' "$v2_storage_json" | extract_body_field "storage")"
  debug_log "v2-page-storage candidate storage body length: ${#candidate_body}"
  if [[ -n "$candidate_body" ]]; then
    candidate_md="$(printf '%s' "$candidate_body" | storage_to_markdown "$PANEL_MAP_FILE")"
    debug_log "v2-page-storage candidate storage markdown length: ${#candidate_md}"
    if [[ -n "$candidate_md" ]]; then
      body_md="$candidate_md"
      page_body_field="storage"
      page_body_raw="$candidate_body"
      page_render_source="v2:storage"
    fi
  fi
fi

for field in storage export_view view styled_view; do
  [[ -z "$body_md" ]] || break
  candidate_body="$(printf '%s' "$PAGE_JSON" | extract_body_field "$field")"
  debug_log "v1-page candidate ${field} body length: ${#candidate_body}"
  [[ -n "$candidate_body" ]] || continue

  candidate_md="$(printf '%s' "$candidate_body" | storage_to_markdown "$PANEL_MAP_FILE")"
  debug_log "v1-page candidate ${field} markdown length: ${#candidate_md}"
  [[ -n "$candidate_md" ]] || continue

  body_md="$candidate_md"
  page_body_field="$field"
  page_body_raw="$candidate_body"
  page_render_source="v1:${field}"
  break
done

if [[ -z "$body_md" ]]; then
  v2_view_json="$(fetch_v2_page_json "$PAGE_ID" "view" || true)"
  if [[ -n "$v2_view_json" ]]; then
    body_md="$(render_body_candidate "$v2_view_json" "view" "v2-page-view" "$PANEL_MAP_FILE" || true)"
    if [[ -n "$body_md" ]]; then
      page_render_source="v2:view"
    fi
  fi
fi

if [[ -z "$body_md" ]]; then
  :
fi

if [[ -z "$body_md" ]]; then
  adf_body="$(echo "$PAGE_JSON" | extract_adf_body)"
  debug_log "selected v1 atlas_doc_format length: ${#adf_body}"
  if [[ -z "$adf_body" || "$adf_body" == "\"\"" ]]; then
    v2_page_json="$v2_adf_json"
    if [[ -z "$v2_page_json" ]]; then
      v2_page_json="$(fetch_v2_page_json "$PAGE_ID" "atlas_doc_format" || true)"
    fi
    if [[ -n "$v2_page_json" ]]; then
      adf_body="$(echo "$v2_page_json" | extract_adf_body)"
      debug_log "selected v2 atlas_doc_format length: ${#adf_body}"
    fi
  fi

  if [[ -n "$adf_body" && "$adf_body" != "\"\"" ]]; then
    converted_body="$(convert_adf_to_view "$adf_body" || true)"
    debug_log "selected converted atlas_doc_format view length: ${#converted_body}"
    if [[ -n "$converted_body" ]]; then
      body_md="$(printf '%s' "$converted_body" | storage_to_markdown "$PANEL_MAP_FILE")"
      debug_log "converted atlas_doc_format markdown length: ${#body_md}"
      if [[ -n "$body_md" ]]; then
        page_render_source="converted:atlas_doc_format"
      fi
    fi
  fi
fi

debug_log "selected page render source: ${page_render_source:-none}"

if [[ ! -s "$COMMENTS_JSONL_FILE" ]]; then
  fetch_v2_footer_comments "$PAGE_ID"
fi
extract_confluence_attachment_map "$PAGE_JSON_FILE" "$COMMENTS_JSONL_FILE" "$PAGE_ID" "$CONFLUENCE_LINK_BASE" > "$ATTACHMENT_MAP_SNAPSHOT_FILE"

eval "$(printf '%s' "$PAGE_JSON" | work2md_json_helper confluence-page-meta --default-page-id "$PAGE_ID")"
PAGE_SHA="$(work2md_sha256_file "$PAGE_JSON_FILE")"
COMMENTS_SHA="$(work2md_sha256_file "$COMMENTS_JSONL_FILE")"
ATTACHMENTS_SHA="$(work2md_sha256_file "$ATTACHMENTS_JSONL_FILE")"
ATTACHMENT_MAP_SHA="$(work2md_sha256_file "$ATTACHMENT_MAP_SNAPSHOT_FILE")"
REDACTION_SERIALIZED="$(IFS=$'\x1f'; printf '%s' "${REDACT_RULES[*]-}")"
DROP_FIELDS_SERIALIZED="$(IFS=$'\x1f'; printf '%s' "${DROP_FIELDS[*]-}")"
if [[ -z "$page_url" ]]; then
  page_url="${CONFLUENCE_BASE}/wiki/spaces/${space_key}/pages/${page_id}"
fi

slug="$(slugify "$title")"
if [[ -z "$slug" ]]; then
  slug="page-${page_id}"
fi
GENERATED_DIR_NAME="${page_id}-${slug}"
if [[ "$CONTENT_PROFILE" == "ai-friendly" ]]; then
  GENERATED_DIR_NAME+="-ai"
fi

if [[ -z "$body_md" ]]; then
  body_md="_No content exported._"
fi

body_md="$(rewrite_user_mentions "$body_md" "$MENTION_MAP_FILE" "$CONTENT_PROFILE")"

ORIGINAL_FORMAT="${page_body_field:-}"
if [[ -z "$ORIGINAL_FORMAT" && "${page_render_source:-}" == "converted:atlas_doc_format" ]]; then
  ORIGINAL_FORMAT="atlas_doc_format"
fi

comments_md=""
comment_index=0
if [[ -s "$COMMENTS_JSONL_FILE" ]]; then
  while IFS= read -r comment_json; do
    [[ -z "$comment_json" ]] && continue

    eval "$(printf '%s' "$comment_json" | work2md_json_helper confluence-comment-meta)"
    comment_md=""
    for field in storage export_view view styled_view; do
      comment_md="$(render_body_candidate "$comment_json" "$field" "comment" "$PANEL_MAP_FILE" || true)"
      if [[ -n "$comment_md" ]]; then
        break
      fi
    done
    if [[ -z "$comment_md" ]]; then
      comment_md="_No comment content exported._"
    fi
    comment_md="$(rewrite_user_mentions "$comment_md" "$MENTION_MAP_FILE" "$CONTENT_PROFILE")"

    comment_index=$((comment_index + 1))
    comment_meta="- Author: ${comment_author}"$'\n'"- Created: ${comment_created}"
    if [[ -n "${comment_updated:-}" && "${comment_updated}" != "${comment_created}" ]]; then
      comment_meta+=$'\n'"- Updated: ${comment_updated}"
    fi
    if [[ -n "${comment_id:-}" ]]; then
      comment_meta+=$'\n'"- ID: ${comment_id}"
    fi

    comment_url=""
    if [[ -n "${comment_webui:-}" ]]; then
      if [[ "$comment_webui" =~ ^https?:// ]]; then
        comment_url="$comment_webui"
      else
        comment_url="${CONFLUENCE_LINK_BASE}${comment_webui}"
      fi
    elif [[ -n "${page_url:-}" && -n "${comment_id:-}" ]]; then
      comment_url="${page_url}?focusedCommentId=${comment_id}"
    fi
    if [[ -n "$comment_url" ]]; then
      comment_meta+=$'\n'"- URL: ${comment_url}"
    fi

    if [[ -n "$comments_md" ]]; then
      comments_md+=$'\n\n'
    fi
    comments_md+="## Comment ${comment_index}"$'\n'"${comment_meta}"$'\n\n'"${comment_md}"
  done < "$COMMENTS_JSONL_FILE"
else
  comments_md="_No comments found._"
fi

INDEX_MD="$(cat <<EOF
# ${title}

${body_md}
EOF
)"

COMMENTS_FILE_NAME="comments.md"
METADATA_FILE_NAME="metadata.md"
MANIFEST_FILE_NAME="manifest.json"
ASSETS_DIR_NAME="assets"
EXPORTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

METADATA_MD="$(cat <<EOF
# Metadata

- Source: Confluence
- Title: ${title}
- Page ID: ${page_id}
- Space: ${space_key}
- Version: ${version_number}
- Created: ${created}
- Updated: ${updated}
- Created by: ${created_by}
- Last updated by: ${updated_by}
- URL: ${page_url}
- Content profile: ${CONTENT_PROFILE}
- Original format: ${ORIGINAL_FORMAT}
- Render source: ${page_render_source}
- Exported at: ${EXPORTED_AT}
- Exporter: work2md
- Exporter version: ${TOOL_VERSION}
- Content file: index.md
- Comments file: ${COMMENTS_FILE_NAME}
- Assets directory: ${ASSETS_DIR_NAME}/
EOF
)"

STABLE_METADATA_MD="$(cat <<EOF
# Metadata

- Source: Confluence
- Title: ${title}
- Page ID: ${page_id}
- Space: ${space_key}
- Version: ${version_number}
- Created: ${created}
- Updated: ${updated}
- Created by: ${created_by}
- Last updated by: ${updated_by}
- URL: ${page_url}
- Content profile: ${CONTENT_PROFILE}
- Original format: ${ORIGINAL_FORMAT}
- Render source: ${page_render_source}
- Exporter: work2md
- Exporter version: ${TOOL_VERSION}
- Content file: index.md
- Comments file: ${COMMENTS_FILE_NAME}
- Assets directory: ${ASSETS_DIR_NAME}/
EOF
)"

COMMENTS_MD="$(cat <<EOF
# Comments

${comments_md}
EOF
)"

STABLE_METADATA_MD="$(filter_metadata_markdown "$STABLE_METADATA_MD")"
EXPORT_FINGERPRINT="$(compute_export_fingerprint "$STABLE_METADATA_MD" "$INDEX_MD" "$COMMENTS_MD" "$ATTACHMENT_MAP_SHA" "$CONTENT_PROFILE" "$FRONT_MATTER" "$REDACTION_SERIALIZED")"
METADATA_MD="$(filter_metadata_markdown "$METADATA_MD")"
if [[ $USE_STDOUT -eq 1 ]]; then
  INDEX_MD="${INDEX_MD//__WORK2MD_ATTACHMENTS_MACRO__/_No attachments exported._}"
fi

if [[ $USE_STDOUT -eq 0 ]]; then
  OUT_DIR="$(work2md_resolve_output_dir "$OUTPUT_DIR" "confluence" "$GENERATED_DIR_NAME")"
  OUT_FILE="$OUT_DIR/index.md"
  MANIFEST_FILE="$OUT_DIR/$MANIFEST_FILE_NAME"
  if [[ $INCREMENTAL -eq 1 && -f "$MANIFEST_FILE" ]]; then
    PREVIOUS_FINGERPRINT="$(work2md_json_helper get-string-file --file "$MANIFEST_FILE" --default "" --path fingerprint)"
    if [[ "$PREVIOUS_FINGERPRINT" == "$EXPORT_FINGERPRINT" ]]; then
      log "No Confluence changes detected for $PAGE_ID; keeping existing export."
      work2md_success "Confluence export is already up to date: $OUT_DIR"
      log "Config: $WORK2MD_CONFIG_FILE"
      exit 0
    fi
  fi
  ATTACHMENT_REWRITE_MAP_FILE=""
  CONFLUENCE_ATTACHMENT_MAP_FILE=""
  prepare_page_attachments "$PAGE_JSON_FILE" "$COMMENTS_JSONL_FILE" "$page_id" "$CONFLUENCE_LINK_BASE" "$OUT_FILE" "$MANIFEST_FILE" "$ATTACHMENT_MAP_SNAPSHOT_FILE"
  if [[ -n "$ATTACHMENT_REWRITE_MAP_FILE" ]]; then
    body_md="$(rewrite_markdown_attachment_paths "$body_md" "$ATTACHMENT_REWRITE_MAP_FILE")"
    comments_md="$(rewrite_markdown_attachment_paths "$comments_md" "$ATTACHMENT_REWRITE_MAP_FILE")"
    body_md="$(replace_attachments_macro "$body_md" "$CONFLUENCE_ATTACHMENT_MAP_FILE" "$ATTACHMENT_REWRITE_MAP_FILE")"
  else
    body_md="${body_md//__WORK2MD_ATTACHMENTS_MACRO__/_No attachments exported._}"
  fi
  INDEX_MD="$(cat <<EOF
# ${title}

${body_md}
EOF
)"
  COMMENTS_MD="$(cat <<EOF
# Comments

${comments_md}
EOF
)"
fi

INDEX_MD="$(prepend_front_matter "$METADATA_MD" "$INDEX_MD")"
INDEX_MD="$(redact_text "$INDEX_MD" "$CONFLUENCE_BASE" "$CONFLUENCE_LINK_BASE")"
METADATA_MD="$(redact_text "$METADATA_MD" "$CONFLUENCE_BASE" "$CONFLUENCE_LINK_BASE")"
COMMENTS_MD="$(redact_text "$COMMENTS_MD" "$CONFLUENCE_BASE" "$CONFLUENCE_LINK_BASE")"

if [[ $USE_STDOUT -eq 1 ]]; then
  case "$EMIT_TARGET" in
    index) printf '%s\n' "$INDEX_MD" ;;
    metadata) printf '%s\n' "$METADATA_MD" ;;
    comments) printf '%s\n' "$COMMENTS_MD" ;;
  esac
else
  METADATA_FILE="$OUT_DIR/$METADATA_FILE_NAME"
  COMMENTS_FILE="$OUT_DIR/$COMMENTS_FILE_NAME"
  printf '%s\n' "$INDEX_MD" > "$OUT_FILE"
  printf '%s\n' "$METADATA_MD" > "$METADATA_FILE"
  printf '%s\n' "$COMMENTS_MD" > "$COMMENTS_FILE"
  write_confluence_manifest "$MANIFEST_FILE" "$CONFLUENCE_ATTACHMENT_MAP_FILE" "$EXPORT_FINGERPRINT" "$PAGE_SHA" "$COMMENTS_SHA" "$ATTACHMENTS_SHA" "$ATTACHMENT_MAP_SHA" "$REDACTION_SERIALIZED" "$DROP_FIELDS_SERIALIZED"
  log "Saved to: $OUT_FILE"
  log "Saved to: $METADATA_FILE"
  log "Saved to: $COMMENTS_FILE"
  log "Saved to: $MANIFEST_FILE"
  work2md_success "Confluence export completed successfully: $OUT_DIR"
fi

log "Config: $WORK2MD_CONFIG_FILE"
