if [[ -n "${WORK2MD_CLI_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
WORK2MD_CLI_LIB_LOADED=1

WORK2MD_CLI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORK2MD_SHARE_DIR="${WORK2MD_SHARE_DIR:-$(cd "$WORK2MD_CLI_LIB_DIR/.." && pwd -P)}"

if [[ -z "${WORK2MD_CONFIG_LIB_LOADED:-}" ]]; then
  # shellcheck source=lib/work2md-config.sh
  source "$WORK2MD_SHARE_DIR/lib/work2md-config.sh"
  WORK2MD_CONFIG_LIB_LOADED=1
fi

work2md_resolve_version() {
  local default_version="${1:-0.9.0}"
  local script_dir="${2:-${SCRIPT_DIR:-}}"
  local candidate

  if [[ -n "$script_dir" ]]; then
    candidate="$script_dir/VERSION"
    if [[ -f "$candidate" ]]; then
      head -n1 "$candidate"
      return 0
    fi
  fi

  candidate="$WORK2MD_SHARE_DIR/VERSION"
  if [[ -f "$candidate" ]]; then
    head -n1 "$candidate"
    return 0
  fi

  printf '%s\n' "$default_version"
}

work2md_require_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    work2md_error "Do not run this script with sudo/root."
    return 1
  fi
}

work2md_require_commands() {
  local cmd

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      work2md_error "$cmd is required."
      return 1
    fi
  done
}

work2md_build_basic_auth() {
  local email="$1"
  local token="$2"

  printf '%s:%s' "$email" "$token" | base64 | tr -d '\n'
}

work2md_prepare_service_auth() {
  local service="$1"
  local auth_var_name="${2:-WORK2MD_AUTH_B64}"
  local base_var email_var token_var

  work2md_load_config
  work2md_require_service_config "$service"
  work2md_warn_service_token_expiry "$service"

  case "$service" in
    jira)
      base_var="JIRA_BASE"
      email_var="JIRA_EMAIL"
      token_var="JIRA_TOKEN"
      ;;
    confluence)
      base_var="CONFLUENCE_BASE"
      email_var="CONFLUENCE_EMAIL"
      token_var="CONFLUENCE_TOKEN"
      ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac

  printf -v "$base_var" '%s' "$(work2md_normalize_base_url "$service" "${!base_var:-}")"
  printf -v "$auth_var_name" '%s' "$(work2md_build_basic_auth "${!email_var:-}" "${!token_var:-}")"
}

work2md_json_helper() {
  python3 "$WORK2MD_SHARE_DIR/scripts/atlassian_json_helper.py" "$@"
}

work2md_resolve_output_dir() {
  local output_path="$1"
  local default_group="$2"
  local generated_dir_name="$3"
  local base_dir resolved_dir

  if [[ -z "$output_path" ]]; then
    base_dir="$PWD/docs/$default_group"
  else
    if [[ "$output_path" != */ && "$(basename "$output_path")" == *.* ]]; then
      work2md_error "--output-dir expects a directory path, got: $output_path"
      return 1
    fi
    base_dir="$output_path"
  fi

  resolved_dir="$base_dir/$generated_dir_name"
  mkdir -p "$resolved_dir"
  resolved_dir="$(cd "$resolved_dir" && pwd -P)"
  printf '%s\n' "$resolved_dir"
}

work2md_http_request() {
  local method="$1"
  local url="$2"
  local payload="${3-}"
  local response
  local -a curl_args=(
    -sS
    -w $'\n%{http_code}'
    -X "$method"
    -H "Authorization: Basic ${WORK2MD_AUTH_B64:-}"
    -H "Accept: application/json"
  )

  if [[ "$method" == "POST" ]]; then
    curl_args+=(
      -H "Content-Type: application/json"
      --data "$payload"
    )
  fi

  response="$(curl "${curl_args[@]}" "$url")" || return 1
  WORK2MD_HTTP_STATUS="$(printf '%s' "$response" | tail -n1)"
  WORK2MD_HTTP_BODY="$(printf '%s' "$response" | sed '$d')"
}

work2md_api_get_or_die() {
  local error_prefix="$1"
  local url="$2"

  work2md_http_request GET "$url" || return 1

  if [[ "$WORK2MD_HTTP_STATUS" != "200" ]]; then
    work2md_error "${error_prefix} (${WORK2MD_HTTP_STATUS})"
    echo "$WORK2MD_HTTP_BODY" >&2
    return 1
  fi

  printf '%s\n' "$WORK2MD_HTTP_BODY"
}

work2md_api_get_optional() {
  local url="$1"

  work2md_http_request GET "$url" || return 1
  [[ "$WORK2MD_HTTP_STATUS" == "200" ]] || return 1
  printf '%s\n' "$WORK2MD_HTTP_BODY"
}

work2md_api_post_optional() {
  local url="$1"
  local payload="$2"

  work2md_http_request POST "$url" "$payload" || return 1

  case "$WORK2MD_HTTP_STATUS" in
    200|202)
      printf '%s\n' "$WORK2MD_HTTP_BODY"
      ;;
    *)
      return 1
      ;;
  esac
}

work2md_download_to_file() {
  local url="$1"
  local output_path="$2"

  curl -fsSL \
    -H "Authorization: Basic ${WORK2MD_AUTH_B64:-}" \
    -H "Accept: */*" \
    -o "$output_path" \
    "$url"
}

work2md_urlencode() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

work2md_sha256_file() {
  local file_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return 0
  fi

  python3 - "$file_path" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
sha = hashlib.sha256()
with path.open("rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        sha.update(chunk)
print(sha.hexdigest())
PY
}
