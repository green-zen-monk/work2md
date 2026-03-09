#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_VERSION="0.1.0"
PACKAGE_VERSION_FILE="/usr/share/work2md/VERSION"

resolve_version() {
  local candidate

  for candidate in "$SCRIPT_DIR/VERSION" "$PACKAGE_VERSION_FILE"; do
    if [[ -f "$candidate" ]]; then
      head -n1 "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$DEFAULT_VERSION"
}

TOOL_VERSION="$(resolve_version)"

# jira2md
# Usage: jira2md ISSUE_KEY [--output PATH] [--stdout] [--version]
# Exports issue -> Markdown
# - config: ~/.config/jira2md/config
# - default output: ./docs/jira/ISSUE.md
# - --output PATH: write to a specific file or directory
# - --stdout: print Markdown to stdout and do not write a file

print_usage() {
  cat <<'EOF'
Usage: jira2md ISSUE_KEY [--output PATH] [--stdout] [--version]
Examples:
  jira2md PROJ-123
  jira2md PROJ-123 --output ./export
  jira2md PROJ-123 --output ./export/issue.md
  jira2md PROJ-123 --stdout
  jira2md --version
EOF
}

usage() {
  print_usage >&2
}

log() {
  echo "$*" >&2
}

ensure_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "Do not run this script with sudo/root." >&2
    exit 1
  fi
}

ISSUE=""
OUTPUT_PATH=""
USE_STDOUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --output." >&2
        usage
        exit 1
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --stdout)
      USE_STDOUT=1
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
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$ISSUE" ]]; then
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ISSUE="$1"
      shift
      ;;
  esac
done

if [[ -z "$ISSUE" ]]; then
  usage
  exit 1
fi

if [[ $USE_STDOUT -eq 1 && -n "$OUTPUT_PATH" ]]; then
  echo "Use either --output or --stdout, not both." >&2
  usage
  exit 1
fi

ensure_not_root

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install: sudo apt-get install -y jq" >&2
  exit 1
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/jira2md"
CONFIG_FILE="$CONFIG_DIR/config"

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  umask 077
  local tmp
  tmp="$(mktemp "$CONFIG_DIR/.config.XXXXXX")"
  cat > "$tmp" <<EOF
JIRA_BASE=${JIRA_BASE@Q}
JIRA_EMAIL=${JIRA_EMAIL@Q}
JIRA_TOKEN=${JIRA_TOKEN@Q}
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

load_config

if [[ -z "${JIRA_BASE:-}" ]]; then
  read -rp "Jira base URL (https://company.atlassian.net): " JIRA_BASE
fi
if [[ -z "${JIRA_EMAIL:-}" ]]; then
  read -rp "Jira email: " JIRA_EMAIL
fi
if [[ -z "${JIRA_TOKEN:-}" ]]; then
  read -rsp "Jira API token: " JIRA_TOKEN
  echo ""
fi

save_config

resolve_output_file() {
  local output_path="$1"
  local generated_name="$2"
  local target_dir dir_part base_name

  if [[ -z "$output_path" ]]; then
    target_dir="$PWD/docs/jira"
    mkdir -p "$target_dir"
    target_dir="$(cd "$target_dir" && pwd -P)"
    printf '%s/%s\n' "$target_dir" "$generated_name"
    return 0
  fi

  if [[ -d "$output_path" || "$output_path" == */ || "$(basename "$output_path")" != *.* ]]; then
    mkdir -p "$output_path"
    target_dir="$(cd "$output_path" && pwd -P)"
    printf '%s/%s\n' "$target_dir" "$generated_name"
    return 0
  fi

  dir_part="$(dirname "$output_path")"
  base_name="$(basename "$output_path")"
  mkdir -p "$dir_part"
  dir_part="$(cd "$dir_part" && pwd -P)"
  printf '%s/%s\n' "$dir_part" "$base_name"
}

AUTH_B64="$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_TOKEN" | base64 | tr -d '\n')"

api_get() {
  local url="$1"
  response=$(curl -sS -w "\n%{http_code}" \
    -H "Authorization: Basic ${AUTH_B64}" \
    -H "Accept: application/json" \
    "$url")

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "Jira API error ($http_code)"
    echo "$body"
    exit 1
  fi

  echo "$body"
}

ADF_TO_MD_JQ='
  def inline_marks($t; $marks):
    reduce ($marks // [])[] as $m ($t;
      if $m.type == "strong" then "**" + . + "**"
      elif $m.type == "em" then "_" + . + "_"
      elif $m.type == "code" then "`" + . + "`"
      elif $m.type == "link" then "[" + . + "](" + ($m.attrs.href // "") + ")"
      else .
      end
    );

  def render_inlines:
    if .type == "text" then inline_marks(.text; .marks)
    elif .type == "hardBreak" then "\n"
    else if has("content") then (.content | map(render_inlines) | join("")) else "" end
    end;

  def indent($n): (" " * $n);

  def render($node; $lvl):
    if $node == null then ""

    elif ($node.type // "") == "doc" then
      (
        ($node.content // []) | map(render(. ; $lvl)) | join("\n\n")
        | gsub("\n{3,}"; "\n\n")
      )

    elif $node.type == "heading" then
      (("#" * ($node.attrs.level // 1)) + " " + (($node.content // []) | map(render_inlines) | join("")))

    elif $node.type == "paragraph" then
      ((($node.content // []) | map(render_inlines) | join("")) | gsub("[ \t]+$"; ""))

    elif $node.type == "blockquote" then
      (
        (($node.content // []) | map(render(. ; 0)) | join("\n"))
        | split("\n") | map("> " + .) | join("\n")
      )

    elif $node.type == "codeBlock" then
      "```" + "\n" + ((($node.content // []) | map(render_inlines) | join(""))) + "\n```"

    elif $node.type == "bulletList" then
      (
        ($node.content // []) | map(
          (
            (.content // []) | map(render(. ; ($lvl + 2))) | join("\n")
          ) as $body
          | ($body | split("\n")) as $lines
          | if ($lines|length) == 0 then ""
            else
              (indent($lvl) + "- " + $lines[0])
              + (if ($lines|length) > 1 then
                   "\n" + ($lines[1:] | map(indent($lvl + 2) + .) | join("\n"))
                 else "" end)
            end
        ) | join("\n")
      )

    elif $node.type == "orderedList" then
      (
        ($node.content // []) | to_entries | map(
          ( (.key + 1) | tostring ) as $n
          | (
              (.value.content // []) | map(render(. ; ($lvl + 3))) | join("\n")
            ) as $body
          | ($body | split("\n")) as $lines
          | if ($lines|length) == 0 then ""
            else
              (indent($lvl) + $n + ". " + $lines[0])
              + (if ($lines|length) > 1 then
                   "\n" + ($lines[1:] | map(indent($lvl + 3) + .) | join("\n"))
                 else "" end)
            end
        ) | join("\n")
      )

    else
      if $node|has("content") then
        (($node.content) | map(render(. ; $lvl)) | join("\n"))
      else
        ""
      end
    end;

  def adf_to_md:
    if . == null then "" else render(. ; 0) end;
'

log "Fetching issue $ISSUE ..."

ISSUE_JSON="$(api_get "${JIRA_BASE}/rest/api/3/issue/${ISSUE}?fields=summary,description,status,reporter,assignee,updated,created,issuetype,project")"
COMMENTS_JSON="$(api_get "${JIRA_BASE}/rest/api/3/issue/${ISSUE}/comment?maxResults=100")"

summary="$(echo "$ISSUE_JSON" | jq -r '.fields.summary // ""')"
key="$(echo "$ISSUE_JSON" | jq -r '.key // "'"$ISSUE"'"')"
status="$(echo "$ISSUE_JSON" | jq -r '.fields.status.name // ""')"
issuetype="$(echo "$ISSUE_JSON" | jq -r '.fields.issuetype.name // ""')"
project="$(echo "$ISSUE_JSON" | jq -r '.fields.project.key // ""')"
created="$(echo "$ISSUE_JSON" | jq -r '.fields.created // ""')"
updated="$(echo "$ISSUE_JSON" | jq -r '.fields.updated // ""')"
reporter="$(echo "$ISSUE_JSON" | jq -r '.fields.reporter.displayName // ""')"
assignee="$(echo "$ISSUE_JSON" | jq -r '.fields.assignee.displayName // "Unassigned"')"

desc_text="$(echo "$ISSUE_JSON" | jq -r "${ADF_TO_MD_JQ} .fields.description | adf_to_md")"

comments_md="$(echo "$COMMENTS_JSON" | jq -r "${ADF_TO_MD_JQ}
  (.comments // [])
  | map(
      \"### \" + (.author.displayName // \"Unknown\") +
      \" — \" + (.created // \"\") + \"\n\n\" +
      ((.body // null) | adf_to_md)
    )
  | join(\"\n\n\")
")"

RENDERED_MD="$(cat <<EOF
# ${key} — ${summary}

- Project: ${project}
- Type: ${issuetype}
- Status: ${status}
- Reporter: ${reporter}
- Assignee: ${assignee}
- Created: ${created}
- Updated: ${updated}
- Jira: ${JIRA_BASE}/browse/${key}

## Description
${desc_text}

## Comments
${comments_md}
EOF
)"

if [[ $USE_STDOUT -eq 1 ]]; then
  printf '%s\n' "$RENDERED_MD"
else
  OUT_FILE="$(resolve_output_file "$OUTPUT_PATH" "${ISSUE}.md")"
  printf '%s\n' "$RENDERED_MD" > "$OUT_FILE"
  log "Saved to: $OUT_FILE"
fi

log "Config: $CONFIG_FILE"
