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

# confluence2md
# Usage: confluence2md PAGE_ID_OR_URL [--output PATH] [--stdout] [--version]
# Exports a Confluence Cloud page -> Markdown
# - config: ~/.config/confluence2md/config
# - default output: ./docs/confluence/PAGE_ID-slug.md
# - --output PATH: write to a specific file or directory
# - --stdout: print Markdown to stdout and do not write a file

print_usage() {
  cat <<'EOF'
Usage: confluence2md PAGE_ID_OR_URL [--output PATH] [--stdout] [--version]
Examples:
  confluence2md 123456789
  confluence2md 123456789 --output ./export
  confluence2md 123456789 --output ./export/page.md
  confluence2md 123456789 --stdout
  confluence2md https://company.atlassian.net/wiki/spaces/TEAM/pages/123456789/Page+Title
  confluence2md --version
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

INPUT=""
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
      printf 'confluence2md %s\n' "$TOOL_VERSION"
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$INPUT" ]]; then
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

if [[ -z "$INPUT" ]]; then
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
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/confluence2md"
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
CONFLUENCE_BASE=${CONFLUENCE_BASE@Q}
CONFLUENCE_EMAIL=${CONFLUENCE_EMAIL@Q}
CONFLUENCE_TOKEN=${CONFLUENCE_TOKEN@Q}
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

normalize_base_url() {
  local value="$1"
  value="${value%/}"
  value="${value%/wiki}"
  printf '%s\n' "$value"
}

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

  echo "Unsupported input: expected a numeric Page ID or a Confluence page URL containing /pages/{id}." >&2
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
  python3 - <<'PY'
import html
import re
import sys
import xml.etree.ElementTree as ET
from html.entities import name2codepoint

raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)


def replace_named_entities(text: str) -> str:
    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        if name in {"lt", "gt", "amp", "quot", "apos"}:
            return match.group(0)
        codepoint = name2codepoint.get(name)
        if codepoint is None:
            return match.group(0)
        return f"&#{codepoint};"

    return re.sub(r"&([A-Za-z][A-Za-z0-9]+);", repl, text)


def sanitize_xml(text: str) -> str:
    text = replace_named_entities(text)
    text = re.sub(
        r"<(/?)([A-Za-z_][\w.-]*):([A-Za-z_][\w.-]*)",
        lambda m: f"<{m.group(1)}{m.group(2)}_{m.group(3)}",
        text,
    )
    text = re.sub(
        r"([ \t\r\n])([A-Za-z_][\w.-]*):([A-Za-z_][\w.-]*)=",
        lambda m: f"{m.group(1)}{m.group(2)}_{m.group(3)}=",
        text,
    )
    return text


sanitized = sanitize_xml(raw)
wrapped = f"<root>{sanitized}</root>"

try:
    root = ET.fromstring(wrapped)
except ET.ParseError:
    fallback = html.unescape(re.sub(r"<[^>]+>", "", raw))
    fallback = re.sub(r"\r\n?", "\n", fallback)
    fallback = re.sub(r"\n{3,}", "\n\n", fallback)
    print(fallback.strip())
    sys.exit(0)


BLOCK_TAGS = {
    "ac_layout",
    "ac_layout-section",
    "ac_layout-cell",
    "ac_rich-text-body",
    "blockquote",
    "div",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hr",
    "ol",
    "p",
    "pre",
    "table",
    "tbody",
    "td",
    "th",
    "thead",
    "tr",
    "ul",
}


def norm_ws(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def escape_md(text: str) -> str:
    return text.replace("\\", "\\\\").replace("|", "\\|")


def text_content(node: ET.Element) -> str:
    parts: list[str] = []
    if node.text:
        parts.append(node.text)
    for child in list(node):
        parts.append(text_content(child))
        if child.tail:
            parts.append(child.tail)
    return "".join(parts)


def fenced_code(body: str, language: str = "") -> str:
    body = body.replace("\r\n", "\n").replace("\r", "\n").strip("\n")
    if not body:
        return "```" + language + "\n```"
    return f"```{language}\n{body}\n```"


def macro_parameter(node: ET.Element, name: str) -> str:
    for child in list(node):
        if child.tag == "ac_parameter" and child.attrib.get("ac_name") == name:
            return norm_ws(text_content(child))
    return ""


def render_inline(node: ET.Element) -> str:
    tag = node.tag

    if tag == "br":
        return "\n"

    if tag == "a":
        label = render_inline_children(node).strip() or node.attrib.get("href", "")
        href = node.attrib.get("href", "").strip()
        if href:
            return f"[{label}]({href})"
        return label

    if tag in {"strong", "b"}:
        value = render_inline_children(node).strip()
        return f"**{value}**" if value else ""

    if tag in {"em", "i"}:
        value = render_inline_children(node).strip()
        return f"_{value}_" if value else ""

    if tag == "code":
        value = text_content(node).strip()
        return f"`{value}`" if value else ""

    if tag == "ri_url":
        return node.attrib.get("ri_value", "").strip()

    if tag == "ri_page":
        return node.attrib.get("ri_content-title", "").strip()

    if tag == "ri_attachment":
        return node.attrib.get("ri_filename", "").strip()

    if tag == "ac_plain-text-link-body":
        return text_content(node).strip()

    if tag == "ac_link":
        label = ""
        target = ""
        for child in list(node):
            if child.tag == "ac_plain-text-link-body":
                label = text_content(child).strip()
            elif child.tag == "ri_url":
                target = child.attrib.get("ri_value", "").strip()
            elif child.tag == "ri_page":
                target = child.attrib.get("ri_content-title", "").strip()
            elif child.tag == "ri_attachment":
                target = child.attrib.get("ri_filename", "").strip()
            elif child.tag == "ac_link-body" and not label:
                label = render_inline_children(child).strip()
        label = label or target or "link"
        if target:
            return f"[{label}]({target})"
        return label

    if tag == "ac_image":
        alt = ""
        src = ""
        for child in list(node):
            if child.tag == "ri_attachment":
                alt = child.attrib.get("ri_filename", "").strip()
                src = alt
            elif child.tag == "ri_url":
                src = child.attrib.get("ri_value", "").strip()
        alt = alt or "image"
        if src:
            return f"![{alt}]({src})"
        return f"![{alt}]()"

    return render_inline_children(node)


def render_inline_children(node: ET.Element) -> str:
    parts: list[str] = []
    if node.text:
        parts.append(html.unescape(node.text))
    for child in list(node):
        parts.append(render_inline(child))
        if child.tail:
          parts.append(html.unescape(child.tail))
    text = "".join(parts)
    text = text.replace("\xa0", " ")
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text


def blockquote(text: str, prefix: str = "> ") -> str:
    lines = text.splitlines() or [""]
    return "\n".join(prefix + line if line else prefix.rstrip() for line in lines)


def table_to_md(node: ET.Element) -> str:
    rows: list[list[str]] = []
    header_flags: list[bool] = []

    for tr in node.findall(".//tr"):
        row: list[str] = []
        row_has_header = False
        for cell in list(tr):
            if cell.tag not in {"th", "td"}:
                continue
            cell_text = render_inline_children(cell).replace("\n", "<br>")
            cell_text = escape_md(norm_ws(cell_text))
            row.append(cell_text)
            if cell.tag == "th":
                row_has_header = True
        if row:
            rows.append(row)
            header_flags.append(row_has_header)

    if not rows:
        return ""

    width = max(len(row) for row in rows)
    rows = [row + [""] * (width - len(row)) for row in rows]

    if header_flags and header_flags[0]:
        header = rows[0]
        data_rows = rows[1:]
    else:
        header = rows[0]
        data_rows = rows[1:]

    md_rows = [
        "| " + " | ".join(header) + " |",
        "| " + " | ".join(["---"] * width) + " |",
    ]
    md_rows.extend("| " + " | ".join(row) + " |" for row in data_rows)
    return "\n".join(md_rows)


def render_macro(node: ET.Element) -> str:
    name = (node.attrib.get("ac_name") or "").strip().lower()

    if name in {"code", "noformat"}:
        language = macro_parameter(node, "language")
        body = ""
        for child in list(node):
            if child.tag == "ac_plain-text-body":
                body = text_content(child)
                break
            if child.tag == "ac_rich-text-body":
                body = text_content(child)
                break
        return fenced_code(body, language)

    if name in {"info", "note", "tip", "warning"}:
        body_blocks: list[str] = []
        for child in list(node):
            if child.tag == "ac_rich-text-body":
                body_blocks = render_children_blocks(child)
                break
        label = name.upper()
        content = "\n\n".join(body_blocks).strip() or f"[{label}]"
        lines = content.splitlines() or [""]
        rendered: list[str] = []
        for index, line in enumerate(lines):
            if index == 0:
                rendered.append(f"> [{label}] {line}".rstrip())
            else:
                rendered.append(f"> {line}".rstrip())
        return "\n".join(rendered)

    body_text = ""
    for child in list(node):
        if child.tag == "ac_rich-text-body":
            body_text = "\n\n".join(render_children_blocks(child)).strip()
            break
    placeholder = f"[Unsupported macro: {name or 'unknown'}]"
    if body_text:
        return placeholder + "\n\n" + body_text
    return placeholder


def render_list(node: ET.Element, indent: int, ordered: bool) -> str:
    lines: list[str] = []
    index = 1
    for child in list(node):
        if child.tag != "li":
            continue
        marker = f"{index}. " if ordered else "- "
        lines.extend(render_list_item(child, indent, marker))
        if ordered:
            index += 1
    return "\n".join(lines)


def render_list_item(node: ET.Element, indent: int, marker: str) -> list[str]:
    prefix = " " * indent
    continuation = " " * (indent + len(marker))

    main_text_parts: list[str] = []
    nested_blocks: list[str] = []

    if node.text and node.text.strip():
        main_text_parts.append(norm_ws(node.text))

    for child in list(node):
        if child.tag in {"ul", "ol"}:
            rendered = render_block(child, indent + len(marker))
            if rendered:
                nested_blocks.append(rendered)
        elif child.tag == "p":
            paragraph = render_inline_children(child).strip()
            if paragraph:
                if not main_text_parts:
                    main_text_parts.append(paragraph)
                else:
                    nested_blocks.append(paragraph)
        elif child.tag in {"pre", "blockquote", "table", "ac_structured-macro"}:
            rendered = render_block(child, indent + len(marker))
            if rendered:
                nested_blocks.append(rendered)
        else:
            inline = render_inline(child).strip()
            if inline:
                main_text_parts.append(inline)
        if child.tail and child.tail.strip():
            main_text_parts.append(norm_ws(child.tail))

    main_text = " ".join(part for part in main_text_parts if part).strip()
    if not main_text:
        main_text = "-"

    lines = [prefix + marker + main_text]
    for block in nested_blocks:
        block_lines = block.splitlines()
        for line in block_lines:
            if line:
                lines.append(continuation + line)
            else:
                lines.append("")
    return lines


def render_block(node: ET.Element, indent: int = 0) -> str:
    tag = node.tag

    if tag in {"div", "ac_layout", "ac_layout-section", "ac_layout-cell", "ac_rich-text-body"}:
        return "\n\n".join(render_children_blocks(node))

    if tag in {"p", "td", "th"}:
        return render_inline_children(node).strip()

    if tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
        level = int(tag[1])
        text = render_inline_children(node).strip()
        return ("#" * level) + " " + text if text else ""

    if tag == "blockquote":
        content = "\n\n".join(render_children_blocks(node)).strip()
        if not content:
            content = render_inline_children(node).strip()
        return blockquote(content)

    if tag == "pre":
        language = ""
        code = text_content(node)
        for child in list(node):
            if child.tag == "code":
                code = text_content(child)
                break
        return fenced_code(code, language)

    if tag == "ul":
        return render_list(node, indent, False)

    if tag == "ol":
        return render_list(node, indent, True)

    if tag == "table":
        return table_to_md(node)

    if tag == "hr":
        return "---"

    if tag == "ac_structured-macro":
        return render_macro(node)

    if tag == "li":
        return "\n".join(render_list_item(node, indent, "- "))

    if list(node):
        return "\n\n".join(render_children_blocks(node))

    return render_inline_children(node).strip()


def render_children_blocks(node: ET.Element) -> list[str]:
    blocks: list[str] = []
    inline_buffer: list[str] = []

    if node.text and node.text.strip():
        inline_buffer.append(norm_ws(node.text))

    for child in list(node):
        if child.tag in BLOCK_TAGS or child.tag == "ac_structured-macro":
            if inline_buffer:
                paragraph = " ".join(part for part in inline_buffer if part).strip()
                if paragraph:
                    blocks.append(paragraph)
                inline_buffer = []
            rendered = render_block(child)
            if rendered.strip():
                blocks.append(rendered.strip())
        else:
            inline_value = render_inline(child)
            if inline_value.strip():
                inline_buffer.append(inline_value.strip())
        if child.tail and child.tail.strip():
            inline_buffer.append(norm_ws(child.tail))

    if inline_buffer:
        paragraph = " ".join(part for part in inline_buffer if part).strip()
        if paragraph:
            blocks.append(paragraph)

    return blocks


output = "\n\n".join(render_children_blocks(root)).strip()
output = re.sub(r"\n{3,}", "\n\n", output)
print(output)
PY
}

resolve_output_file() {
  local output_path="$1"
  local generated_name="$2"
  local target_dir dir_part base_name

  if [[ -z "$output_path" ]]; then
    target_dir="$PWD/docs/confluence"
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

load_config

if [[ -z "${CONFLUENCE_BASE:-}" ]]; then
  read -rp "Confluence base URL (https://company.atlassian.net): " CONFLUENCE_BASE
fi
CONFLUENCE_BASE="$(normalize_base_url "$CONFLUENCE_BASE")"

if [[ -z "${CONFLUENCE_EMAIL:-}" ]]; then
  read -rp "Confluence email: " CONFLUENCE_EMAIL
fi
if [[ -z "${CONFLUENCE_TOKEN:-}" ]]; then
  read -rsp "Confluence API token: " CONFLUENCE_TOKEN
  echo ""
fi

save_config

PAGE_ID="$(resolve_page_id "$INPUT")"

AUTH_B64="$(printf '%s:%s' "$CONFLUENCE_EMAIL" "$CONFLUENCE_TOKEN" | base64 | tr -d '\n')"

api_get() {
  local url="$1"
  local response http_code body

  response="$(curl -sS -w "\n%{http_code}" \
    -H "Authorization: Basic ${AUTH_B64}" \
    -H "Accept: application/json" \
    "$url")"

  http_code="$(echo "$response" | tail -n1)"
  body="$(echo "$response" | sed '$d')"

  case "$http_code" in
    200)
      printf '%s\n' "$body"
      ;;
    401|403)
      echo "Confluence API error ($http_code): authentication failed or access is denied." >&2
      echo "$body" >&2
      exit 1
      ;;
    404)
      echo "Confluence API error (404): page not found: $PAGE_ID" >&2
      echo "$body" >&2
      exit 1
      ;;
    *)
      echo "Confluence API error ($http_code)" >&2
      echo "$body" >&2
      exit 1
      ;;
  esac
}

fetch_all_comments() {
  local page_id="$1"
  local start=0
  local limit=100
  local page_json size total

  while :; do
    page_json="$(api_get "${CONFLUENCE_BASE}/wiki/rest/api/content/${page_id}/child/comment?expand=body.storage,version,history&limit=${limit}&start=${start}")"

    echo "$page_json" | jq -c '.results[]?' >> "$COMMENTS_JSONL_FILE"

    size="$(echo "$page_json" | jq -r '.size // 0')"
    total="$(echo "$page_json" | jq -r '.total // empty')"

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

TMP_DIR="$(mktemp -d)"
COMMENTS_JSONL_FILE="$TMP_DIR/comments.jsonl"
trap 'rm -rf "$TMP_DIR"' EXIT
touch "$COMMENTS_JSONL_FILE"

log "Fetching Confluence page $PAGE_ID ..."

PAGE_JSON="$(api_get "${CONFLUENCE_BASE}/wiki/rest/api/content/${PAGE_ID}?expand=body.storage,version,space,history")"
fetch_all_comments "$PAGE_ID"

title="$(echo "$PAGE_JSON" | jq -r '.title // ("Page " + (.id // "'"$PAGE_ID"'"))')"
page_id="$(echo "$PAGE_JSON" | jq -r '.id // "'"$PAGE_ID"'"')"
space_key="$(echo "$PAGE_JSON" | jq -r '.space.key // ""')"
version_number="$(echo "$PAGE_JSON" | jq -r '.version.number // ""')"
created="$(echo "$PAGE_JSON" | jq -r '.history.createdDate // ""')"
updated="$(echo "$PAGE_JSON" | jq -r '.version.when // ""')"
created_by="$(echo "$PAGE_JSON" | jq -r '.history.createdBy.displayName // ""')"
updated_by="$(echo "$PAGE_JSON" | jq -r '.version.by.displayName // ""')"
storage_body="$(echo "$PAGE_JSON" | jq -r '.body.storage.value // ""')"

page_url="$(echo "$PAGE_JSON" | jq -r '
  if (._links.base // "") != "" and (._links.webui // "") != "" then
    ._links.base + ._links.webui
  else
    ""
  end
')"
if [[ -z "$page_url" ]]; then
  page_url="${CONFLUENCE_BASE}/wiki/spaces/${space_key}/pages/${page_id}"
fi

slug="$(slugify "$title")"
if [[ -z "$slug" ]]; then
  slug="page-${page_id}"
fi
GENERATED_FILE_NAME="${page_id}-${slug}.md"

body_md="$(printf '%s' "$storage_body" | storage_to_markdown)"
if [[ -z "$body_md" ]]; then
  body_md="_No content exported._"
fi

comments_md=""
if [[ -s "$COMMENTS_JSONL_FILE" ]]; then
  while IFS= read -r comment_json; do
    [[ -z "$comment_json" ]] && continue

    comment_author="$(echo "$comment_json" | jq -r '.history.createdBy.displayName // .version.by.displayName // "Unknown"')"
    comment_created="$(echo "$comment_json" | jq -r '.history.createdDate // .version.when // ""')"
    comment_body="$(echo "$comment_json" | jq -r '.body.storage.value // ""')"
    comment_md="$(printf '%s' "$comment_body" | storage_to_markdown)"
    if [[ -z "$comment_md" ]]; then
      comment_md="_No comment content exported._"
    fi

    if [[ -n "$comments_md" ]]; then
      comments_md+=$'\n\n'
    fi
    comments_md+="### ${comment_author} - ${comment_created}"$'\n\n'"${comment_md}"
  done < "$COMMENTS_JSONL_FILE"
else
  comments_md="_No comments found._"
fi

RENDERED_MD="$(cat <<EOF
# ${title}

- Space: ${space_key}
- Page ID: ${page_id}
- Version: ${version_number}
- Created: ${created}
- Updated: ${updated}
- Created by: ${created_by}
- Last updated by: ${updated_by}
- Confluence URL: ${page_url}

## Content
${body_md}

## Comments
${comments_md}
EOF
)"

if [[ $USE_STDOUT -eq 1 ]]; then
  printf '%s\n' "$RENDERED_MD"
else
  OUT_FILE="$(resolve_output_file "$OUTPUT_PATH" "$GENERATED_FILE_NAME")"
  printf '%s\n' "$RENDERED_MD" > "$OUT_FILE"
  log "Saved to: $OUT_FILE"
fi

log "Config: $CONFIG_FILE"
