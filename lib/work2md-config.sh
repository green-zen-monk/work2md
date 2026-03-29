WORK2MD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/work2md"
WORK2MD_CONFIG_FILE="$WORK2MD_CONFIG_DIR/config"
WORK2MD_LEGACY_JIRA_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/jira2md/config"
WORK2MD_LEGACY_CONFLUENCE_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/confluence2md/config"
WORK2MD_JIRA_TOKEN_ENV_VAR="WORK2MD_JIRA_TOKEN"
WORK2MD_CONFLUENCE_TOKEN_ENV_VAR="WORK2MD_CONFLUENCE_TOKEN"
WORK2MD_DEFAULT_TOKEN_BACKEND="config"
WORK2MD_LOG_FORMAT="${WORK2MD_LOG_FORMAT:-text}"

_WORK2MD_STORED_JIRA_TOKEN=""
_WORK2MD_STORED_CONFLUENCE_TOKEN=""
_WORK2MD_JIRA_TOKEN_SOURCE="unset"
_WORK2MD_CONFLUENCE_TOKEN_SOURCE="unset"

if ! declare -F work2md_supports_color >/dev/null 2>&1; then
  work2md_supports_color() {
    [[ -t 2 ]] || return 1
    [[ "${TERM:-}" != "dumb" ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    return 0
  }
fi

if ! declare -F work2md_stderr_message >/dev/null 2>&1; then
  work2md_json_escape() {
    local value="${1-}"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
  }

  work2md_set_log_format() {
    local format="${1:-text}"

    case "$format" in
      text|json)
        WORK2MD_LOG_FORMAT="$format"
        ;;
      *)
        work2md_error "Unsupported log format: $format"
        return 1
        ;;
    esac
  }

  work2md_stderr_message() {
    local color_code="$1"
    local prefix="$2"
    shift 2
    local message="$*"

    if [[ "${WORK2MD_LOG_FORMAT:-text}" == "json" ]]; then
      printf '{"level":"%s","message":"%s"}\n' \
        "$(work2md_json_escape "${prefix,,}")" \
        "$(work2md_json_escape "$message")" >&2
      return 0
    fi

    if work2md_supports_color; then
      printf '\033[%sm%s:\033[0m %s\n' "$color_code" "$prefix" "$message" >&2
    else
      printf '%s: %s\n' "$prefix" "$message" >&2
    fi
  }
fi

if ! declare -F work2md_warn >/dev/null 2>&1; then
  work2md_warn() {
    work2md_stderr_message "33" "Warning" "$@"
  }
fi

if ! declare -F work2md_error >/dev/null 2>&1; then
  work2md_error() {
    work2md_stderr_message "31" "Error" "$@"
  }
fi

if ! declare -F work2md_success >/dev/null 2>&1; then
  work2md_success() {
    work2md_stderr_message "32" "Success" "$@"
  }
fi

if ! declare -F work2md_info >/dev/null 2>&1; then
  work2md_info() {
    work2md_stderr_message "36" "Info" "$@"
  }
fi

work2md_ensure_private_dir() {
  local dir_path="$1"

  if [[ -e "$dir_path" && ! -d "$dir_path" ]]; then
    work2md_error "Config path is not a directory: $dir_path"
    return 1
  fi

  mkdir -p "$dir_path"
  chmod 700 "$dir_path"
}

work2md_secure_existing_dir() {
  local dir_path="$1"

  if [[ ! -e "$dir_path" ]]; then
    return 0
  fi

  if [[ ! -d "$dir_path" ]]; then
    work2md_error "Config path is not a directory: $dir_path"
    return 1
  fi

  chmod 700 "$dir_path"
}

work2md_ensure_private_file() {
  local file_path="$1"

  if [[ ! -e "$file_path" ]]; then
    return 0
  fi

  if [[ ! -f "$file_path" ]]; then
    work2md_error "Config path is not a regular file: $file_path"
    return 1
  fi

  chmod 600 "$file_path"
}

work2md_secure_config_storage() {
  work2md_ensure_private_dir "$WORK2MD_CONFIG_DIR" || return 1
  work2md_ensure_private_file "$WORK2MD_CONFIG_FILE" || return 1
}

work2md_secure_existing_config_storage() {
  work2md_secure_existing_dir "$WORK2MD_CONFIG_DIR" || return 1
  work2md_ensure_private_file "$WORK2MD_CONFIG_FILE" || return 1
}

work2md_get_service_token_env_var_name() {
  local service="$1"

  case "$service" in
    jira) printf '%s\n' "$WORK2MD_JIRA_TOKEN_ENV_VAR" ;;
    confluence) printf '%s\n' "$WORK2MD_CONFLUENCE_TOKEN_ENV_VAR" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_validate_token_backend() {
  local backend="$1"

  case "$backend" in
    config|keyring) return 0 ;;
    *)
      work2md_error "Unsupported token backend: $backend"
      return 1
      ;;
  esac
}

work2md_get_keyring_provider() {
  if work2md_secret_tool_available; then
    printf '%s\n' "secret-tool"
    return 0
  fi

  printf '%s\n' "unavailable"
}

work2md_get_keyring_provider_hint() {
  local provider="${1:-$(work2md_get_keyring_provider)}"

  case "$provider" in
    secret-tool)
      printf '%s\n' "secret-tool from the libsecret-tools package"
      ;;
    unavailable)
      printf '%s\n' "secret-tool from the libsecret-tools package"
      ;;
  esac
}

work2md_get_service_token_backend() {
  local service="$1"
  local backend

  case "$service" in
    jira) backend="${JIRA_TOKEN_BACKEND:-$WORK2MD_DEFAULT_TOKEN_BACKEND}" ;;
    confluence) backend="${CONFLUENCE_TOKEN_BACKEND:-$WORK2MD_DEFAULT_TOKEN_BACKEND}" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac

  work2md_validate_token_backend "$backend" || return 1
  printf '%s\n' "$backend"
}

work2md_set_service_token_backend_value() {
  local service="$1"
  local backend="$2"

  work2md_validate_token_backend "$backend" || return 1

  case "$service" in
    jira) JIRA_TOKEN_BACKEND="$backend" ;;
    confluence) CONFLUENCE_TOKEN_BACKEND="$backend" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_get_service_stored_token() {
  local service="$1"

  case "$service" in
    jira) printf '%s\n' "${_WORK2MD_STORED_JIRA_TOKEN-}" ;;
    confluence) printf '%s\n' "${_WORK2MD_STORED_CONFLUENCE_TOKEN-}" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_get_service_token_source() {
  local service="$1"

  case "$service" in
    jira) printf '%s\n' "${_WORK2MD_JIRA_TOKEN_SOURCE-}" ;;
    confluence) printf '%s\n' "${_WORK2MD_CONFLUENCE_TOKEN_SOURCE-}" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_set_service_token_source() {
  local service="$1"
  local source="$2"

  case "$service" in
    jira) _WORK2MD_JIRA_TOKEN_SOURCE="$source" ;;
    confluence) _WORK2MD_CONFLUENCE_TOKEN_SOURCE="$source" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_set_service_token_state() {
  local service="$1"
  local value="$2"
  local source="${3:-config}"
  local persist="${4:-yes}"

  case "$service" in
    jira)
      JIRA_TOKEN="$value"
      _WORK2MD_JIRA_TOKEN_SOURCE="$source"
      if [[ "$persist" == "yes" ]]; then
        _WORK2MD_STORED_JIRA_TOKEN="$value"
      fi
      ;;
    confluence)
      CONFLUENCE_TOKEN="$value"
      _WORK2MD_CONFLUENCE_TOKEN_SOURCE="$source"
      if [[ "$persist" == "yes" ]]; then
        _WORK2MD_STORED_CONFLUENCE_TOKEN="$value"
      fi
      ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_secret_tool_available() {
  command -v secret-tool >/dev/null 2>&1
}

work2md_store_service_token_in_keyring() {
  local service="$1"
  local value="$2"
  local label provider

  provider="$(work2md_get_keyring_provider)"

  case "$service" in
    jira) label="work2md Jira API token" ;;
    confluence) label="work2md Confluence API token" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac

  case "$provider" in
    secret-tool)
      if ! printf '%s' "$value" | secret-tool store --label="$label" application work2md service "$service" secret token >/dev/null; then
        work2md_error "Failed to store the ${service} token in the system keyring."
        return 1
      fi
      ;;
    *)
      work2md_error "The keyring token backend is unavailable. Use ${WORK2MD_JIRA_TOKEN_ENV_VAR}/${WORK2MD_CONFLUENCE_TOKEN_ENV_VAR}, switch to the config backend, or configure $(work2md_get_keyring_provider_hint "$provider")."
      return 1
      ;;
  esac
}

work2md_lookup_service_token_in_keyring() {
  local service="$1"
  local provider

  provider="$(work2md_get_keyring_provider)"

  case "$provider" in
    secret-tool)
      secret-tool lookup application work2md service "$service" secret token
      ;;
    *)
      return 1
      ;;
  esac
}

work2md_set_service_token_for_backend() {
  local service="$1"
  local value="$2"
  local backend

  backend="$(work2md_get_service_token_backend "$service")" || return 1

  case "$backend" in
    config)
      work2md_set_service_token_state "$service" "$value" config yes
      ;;
    keyring)
      work2md_store_service_token_in_keyring "$service" "$value" || return 1
      work2md_set_service_token_state "$service" "$value" keyring no
      case "$service" in
        jira) _WORK2MD_STORED_JIRA_TOKEN="" ;;
        confluence) _WORK2MD_STORED_CONFLUENCE_TOKEN="" ;;
      esac
      ;;
  esac
}

work2md_load_service_token_for_backend() {
  local service="$1"
  local backend token=""

  backend="$(work2md_get_service_token_backend "$service")" || return 1

  case "$backend" in
    config)
      token="$(work2md_get_service_stored_token "$service")" || return 1
      if [[ -n "$token" ]]; then
        work2md_set_service_token_state "$service" "$token" config no
      else
        work2md_set_service_token_state "$service" "" unset no
      fi
      ;;
    keyring)
      if [[ "$(work2md_get_keyring_provider)" == "unavailable" ]]; then
        work2md_set_service_token_state "$service" "" keyring-unavailable no
        return 0
      fi

      token="$(work2md_lookup_service_token_in_keyring "$service" 2>/dev/null || true)"
      if [[ -n "$token" ]]; then
        work2md_set_service_token_state "$service" "$token" keyring no
      else
        work2md_set_service_token_state "$service" "" keyring-missing no
      fi
      ;;
  esac
}

work2md_apply_token_sources() {
  local env_var env_value

  _WORK2MD_STORED_JIRA_TOKEN="${JIRA_TOKEN-}"
  _WORK2MD_STORED_CONFLUENCE_TOKEN="${CONFLUENCE_TOKEN-}"

  work2md_load_service_token_for_backend jira || return 1
  work2md_load_service_token_for_backend confluence || return 1

  env_var="$WORK2MD_JIRA_TOKEN_ENV_VAR"
  env_value="${!env_var-}"
  if [[ -n "$env_value" ]]; then
    work2md_set_service_token_state jira "$env_value" env no || return 1
  fi

  env_var="$WORK2MD_CONFLUENCE_TOKEN_ENV_VAR"
  env_value="${!env_var-}"
  if [[ -n "$env_value" ]]; then
    work2md_set_service_token_state confluence "$env_value" env no || return 1
  fi
}

work2md_load_config() {
  local legacy_file

  work2md_secure_existing_config_storage || return 1

  if [[ -f "$WORK2MD_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$WORK2MD_CONFIG_FILE"
  fi

  for legacy_file in "$WORK2MD_LEGACY_JIRA_CONFIG_FILE" "$WORK2MD_LEGACY_CONFLUENCE_CONFIG_FILE"; do
    if [[ -f "$legacy_file" ]]; then
      work2md_secure_existing_dir "$(dirname "$legacy_file")" || return 1
      work2md_ensure_private_file "$legacy_file" || return 1
      # shellcheck disable=SC1090
      source "$legacy_file"
    fi
  done

  if [[ -n "${JIRA_BASE-}" ]]; then
    JIRA_BASE="$(work2md_normalize_base_url jira "$JIRA_BASE")"
  fi
  if [[ -n "${CONFLUENCE_BASE-}" ]]; then
    CONFLUENCE_BASE="$(work2md_normalize_base_url confluence "$CONFLUENCE_BASE")"
  fi

  JIRA_TOKEN_BACKEND="${JIRA_TOKEN_BACKEND:-$WORK2MD_DEFAULT_TOKEN_BACKEND}"
  CONFLUENCE_TOKEN_BACKEND="${CONFLUENCE_TOKEN_BACKEND:-$WORK2MD_DEFAULT_TOKEN_BACKEND}"
  work2md_validate_token_backend "$JIRA_TOKEN_BACKEND" || return 1
  work2md_validate_token_backend "$CONFLUENCE_TOKEN_BACKEND" || return 1

  work2md_apply_token_sources || return 1
}

work2md_get_service_label() {
  local service="$1"

  case "$service" in
    jira) printf '%s\n' "Jira" ;;
    confluence) printf '%s\n' "Confluence" ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_get_service_value() {
  local service="$1"
  local field="$2"

  case "$service:$field" in
    jira:base) printf '%s\n' "${JIRA_BASE-}" ;;
    jira:email) printf '%s\n' "${JIRA_EMAIL-}" ;;
    jira:token) printf '%s\n' "${JIRA_TOKEN-}" ;;
    jira:token_expiry) printf '%s\n' "${JIRA_TOKEN_EXPIRES_AT-}" ;;
    confluence:base) printf '%s\n' "${CONFLUENCE_BASE-}" ;;
    confluence:email) printf '%s\n' "${CONFLUENCE_EMAIL-}" ;;
    confluence:token) printf '%s\n' "${CONFLUENCE_TOKEN-}" ;;
    confluence:token_expiry) printf '%s\n' "${CONFLUENCE_TOKEN_EXPIRES_AT-}" ;;
    *)
      work2md_error "Unknown setting: ${service} ${field}"
      return 1
      ;;
  esac
}

work2md_shell_quote() {
  local value="${1-}"
  printf '%q' "$value"
}

work2md_save_config() {
  local jira_base jira_email jira_token jira_token_expires_at
  local jira_token_backend
  local confluence_base confluence_email confluence_token confluence_token_expires_at
  local confluence_token_backend
  local tmp

  work2md_secure_config_storage || return 1
  tmp="$(umask 077; mktemp "$WORK2MD_CONFIG_DIR/.config.XXXXXX")"

  jira_base="${JIRA_BASE-}"
  jira_email="${JIRA_EMAIL-}"
  jira_token="${_WORK2MD_STORED_JIRA_TOKEN-}"
  jira_token_expires_at="${JIRA_TOKEN_EXPIRES_AT-}"
  jira_token_backend="$(work2md_get_service_token_backend jira)"
  confluence_base="${CONFLUENCE_BASE-}"
  confluence_email="${CONFLUENCE_EMAIL-}"
  confluence_token="${_WORK2MD_STORED_CONFLUENCE_TOKEN-}"
  confluence_token_expires_at="${CONFLUENCE_TOKEN_EXPIRES_AT-}"
  confluence_token_backend="$(work2md_get_service_token_backend confluence)"

  cat > "$tmp" <<EOF
JIRA_BASE=$(work2md_shell_quote "$jira_base")
JIRA_EMAIL=$(work2md_shell_quote "$jira_email")
JIRA_TOKEN=$(work2md_shell_quote "$jira_token")
JIRA_TOKEN_EXPIRES_AT=$(work2md_shell_quote "$jira_token_expires_at")
JIRA_TOKEN_BACKEND=$(work2md_shell_quote "$jira_token_backend")
CONFLUENCE_BASE=$(work2md_shell_quote "$confluence_base")
CONFLUENCE_EMAIL=$(work2md_shell_quote "$confluence_email")
CONFLUENCE_TOKEN=$(work2md_shell_quote "$confluence_token")
CONFLUENCE_TOKEN_EXPIRES_AT=$(work2md_shell_quote "$confluence_token_expires_at")
CONFLUENCE_TOKEN_BACKEND=$(work2md_shell_quote "$confluence_token_backend")
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$WORK2MD_CONFIG_FILE"
  chmod 600 "$WORK2MD_CONFIG_FILE"
}

work2md_normalize_base_url() {
  local service="$1"
  local value="$2"

  value="${value%/}"
  if [[ "$service" == "confluence" ]]; then
    value="${value%/wiki}"
  fi
  printf '%s\n' "$value"
}

work2md_mask_secret() {
  local value="$1"
  local length="${#value}"

  if [[ -z "$value" ]]; then
    printf '%s\n' "(unset)"
    return 0
  fi

  if (( length <= 8 )); then
    printf '%s\n' "********"
    return 0
  fi

  printf '%s\n' "${value:0:4}...${value: -4}"
}

work2md_describe_service_token() {
  local service="$1"
  local token="$2"
  local source env_var provider

  source="$(work2md_get_service_token_source "$service")" || return 1
  case "$source" in
    env)
      env_var="$(work2md_get_service_token_env_var_name "$service")" || return 1
      printf '%s\n' "(from environment variable ${env_var})"
      ;;
    keyring)
      provider="$(work2md_get_keyring_provider)"
      case "$provider" in
        secret-tool)
          printf '%s\n' "(stored in system keyring via secret-tool)"
          ;;
        *)
          printf '%s\n' "(stored in system keyring)"
          ;;
      esac
      ;;
    keyring-unavailable)
      env_var="$(work2md_get_service_token_env_var_name "$service")" || return 1
      printf '%s\n' "(system keyring unavailable; use ${env_var} or configure a supported keyring backend)"
      ;;
    keyring-missing)
      printf '%s\n' "(not found in system keyring)"
      ;;
    *)
      work2md_mask_secret "$token"
      ;;
  esac
}

work2md_show_service_config() {
  local service="$1"
  local title base email token token_expiry token_backend

  case "$service" in
    jira)
      title="Jira"
      base="${JIRA_BASE-}"
      email="${JIRA_EMAIL-}"
      token="${JIRA_TOKEN-}"
      token_expiry="${JIRA_TOKEN_EXPIRES_AT-}"
      token_backend="$(work2md_get_service_token_backend jira)"
      ;;
    confluence)
      title="Confluence"
      base="${CONFLUENCE_BASE-}"
      email="${CONFLUENCE_EMAIL-}"
      token="${CONFLUENCE_TOKEN-}"
      token_expiry="${CONFLUENCE_TOKEN_EXPIRES_AT-}"
      token_backend="$(work2md_get_service_token_backend confluence)"
      ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac

  cat <<EOF
${title}
- Base: ${base:-"(unset)"}
- Email: ${email:-"(unset)"}
- Token backend: ${token_backend}
- Token: $(work2md_describe_service_token "$service" "$token")
- Token expiry: ${token_expiry:-"(unset)"}
EOF
}

work2md_token_expiry_info() {
  local value="${1-}"

  python3 - "$value" <<'PY'
import datetime as dt
import shlex
import sys

value = (sys.argv[1] or "").strip()

def emit(mapping):
    for key, raw in mapping.items():
        print(f"{key}={shlex.quote(str(raw))}")

if not value:
    emit({"expiry_status": "missing", "expiry_days": "", "expiry_normalized": ""})
    raise SystemExit(0)

try:
    parsed_date = dt.date.fromisoformat(value)
except ValueError:
    parsed_date = None

if parsed_date is not None:
    today = dt.datetime.now(dt.timezone.utc).date()
    delta_days = (parsed_date - today).days
    if delta_days < 0:
        status = "expired"
    elif delta_days <= 14:
        status = "expires_soon"
    else:
        status = "ok"
    emit(
        {
            "expiry_status": status,
            "expiry_days": delta_days,
            "expiry_normalized": parsed_date.isoformat(),
        }
    )
    raise SystemExit(0)

candidate = value[:-1] + "+00:00" if value.endswith("Z") else value
try:
    parsed_dt = dt.datetime.fromisoformat(candidate)
except ValueError:
    emit({"expiry_status": "invalid", "expiry_days": "", "expiry_normalized": value})
    raise SystemExit(0)

if parsed_dt.tzinfo is None:
    parsed_dt = parsed_dt.replace(tzinfo=dt.timezone.utc)
else:
    parsed_dt = parsed_dt.astimezone(dt.timezone.utc)

now = dt.datetime.now(dt.timezone.utc)
remaining = parsed_dt - now
delta_days = int(remaining.total_seconds() // 86400)
if remaining.total_seconds() < 0:
    status = "expired"
elif remaining <= dt.timedelta(days=14):
    status = "expires_soon"
else:
    status = "ok"

emit(
    {
        "expiry_status": status,
        "expiry_days": delta_days,
        "expiry_normalized": parsed_dt.isoformat().replace("+00:00", "Z"),
    }
)
PY
}

work2md_prompt_optional_value() {
  local prompt="$1"
  local current_value="$2"
  local result_var="$3"
  local raw_value=""

  if [[ -n "$current_value" ]]; then
    read -rp "${prompt} [${current_value}]: " raw_value
    raw_value="${raw_value:-$current_value}"
  else
    read -rp "${prompt}: " raw_value
  fi

  printf -v "$result_var" '%s' "$raw_value"
}

work2md_live_api_check() {
  local service="$1"
  local base email token url http_code

  base="$(work2md_get_service_value "$service" base)"
  email="$(work2md_get_service_value "$service" email)"
  token="$(work2md_get_service_value "$service" token)"

  case "$service" in
    jira)
      url="${base}/rest/api/3/myself"
      ;;
    confluence)
      url="${base}/wiki/rest/api/user/current"
      ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "curl-missing"
    return 1
  fi

  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -u "${email}:${token}" \
    -H 'Accept: application/json' \
    --max-time 20 \
    "$url" || printf '000')"

  if [[ "$http_code" == "200" ]]; then
    printf '%s\n' "ok"
    return 0
  fi

  printf '%s\n' "$http_code"
  return 1
}

work2md_service_probe_url() {
  local service="$1"
  local base

  base="$(work2md_get_service_value "$service" base)"
  case "$service" in
    jira)
      printf '%s\n' "${base}/rest/api/3/myself"
      ;;
    confluence)
      printf '%s\n' "${base}/wiki/rest/api/user/current"
      ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_validate_base_url() {
  local service="$1"
  local value="$2"

  value="$(work2md_normalize_base_url "$service" "$value")"
  if [[ -z "$value" ]]; then
    printf '%s\n' "missing"
    return 1
  fi

  if [[ "$value" =~ ^https?://[A-Za-z0-9._:-]+$ ]]; then
    printf '%s\n' "ok"
    return 0
  fi

  printf '%s\n' "invalid"
  return 1
}

work2md_doctor_service_config() {
  local service="$1"
  local title base email token token_backend token_source token_expiry
  local base_status auth_status probe_status probe_url
  local expiry_status expiry_days expiry_normalized
  local keyring_provider keyring_status
  local result=0

  title="$(work2md_get_service_label "$service")" || return 1
  base="$(work2md_get_service_value "$service" base)"
  email="$(work2md_get_service_value "$service" email)"
  token="$(work2md_get_service_value "$service" token)"
  token_backend="$(work2md_get_service_token_backend "$service")"
  token_source="$(work2md_get_service_token_source "$service")"
  token_expiry="$(work2md_get_service_value "$service" token_expiry)"
  keyring_provider="$(work2md_get_keyring_provider)"
  probe_url="$(work2md_service_probe_url "$service")"

  printf '%s\n' "$title doctor"

  base_status="$(work2md_validate_base_url "$service" "$base" || true)"
  case "$base_status" in
    ok)
      printf '%s\n' "- Base URL: OK (${base})"
      ;;
    missing)
      printf '%s\n' "- Base URL: missing"
      work2md_error "${title} base URL is not configured."
      result=1
      ;;
    *)
      printf '%s\n' "- Base URL: invalid (${base:-unset})"
      work2md_error "${title} base URL must look like https://company.atlassian.net"
      result=1
      ;;
  esac

  if [[ -n "$email" && -n "$token" ]]; then
    auth_status="ok"
    printf '%s\n' "- Auth fields: OK (email present, token source: ${token_source})"
  else
    auth_status="missing"
    printf '%s\n' "- Auth fields: incomplete"
    [[ -n "$email" ]] || work2md_error "${title} email is not configured."
    if [[ -z "$token" ]]; then
      work2md_explain_missing_service_token "$service" || true
      work2md_error "${title} token is not configured."
    fi
    result=1
  fi

  if [[ "$token_backend" == "keyring" ]]; then
    case "$token_source" in
      keyring)
        keyring_status="ok"
        printf '%s\n' "- Keyring: OK (${keyring_provider})"
        ;;
      keyring-unavailable)
        keyring_status="unavailable"
        printf '%s\n' "- Keyring: unavailable"
        work2md_error "${title} keyring backend is configured, but no supported provider is available."
        result=1
        ;;
      keyring-missing)
        keyring_status="missing-token"
        printf '%s\n' "- Keyring: reachable (${keyring_provider}), but token missing"
        work2md_error "${title} keyring backend is configured, but no token is stored."
        result=1
        ;;
      *)
        keyring_status="unexpected-source"
        printf '%s\n' "- Keyring: backend=${token_backend}, token source=${token_source}"
        ;;
    esac
  else
    keyring_status="not-used"
    printf '%s\n' "- Keyring: not used (backend=${token_backend})"
  fi

  eval "$(work2md_token_expiry_info "$token_expiry")"
  case "$expiry_status" in
    missing)
      printf '%s\n' "- Token expiry: missing"
      work2md_warn "${title} token expiry is not configured."
      ;;
    invalid)
      printf '%s\n' "- Token expiry: invalid (${token_expiry})"
      work2md_error "${title} token expiry has invalid format. Use YYYY-MM-DD or ISO-8601 datetime."
      result=1
      ;;
    expired)
      printf '%s\n' "- Token expiry: expired (${expiry_normalized})"
      work2md_error "${title} token is past its configured expiry date."
      result=1
      ;;
    expires_soon)
      printf '%s\n' "- Token expiry: expires soon (${expiry_normalized}, ${expiry_days} day(s) remaining)"
      work2md_warn "${title} token expires in ${expiry_days} day(s)."
      ;;
    ok)
      printf '%s\n' "- Token expiry: OK (${expiry_normalized}, ${expiry_days} day(s) remaining)"
      ;;
  esac

  if [[ "$base_status" == "ok" && "$auth_status" == "ok" ]]; then
    probe_status="$(work2md_live_api_check "$service" || true)"
    case "$probe_status" in
      ok)
        printf '%s\n' "- API probe: OK (${probe_url})"
        ;;
      curl-missing)
        printf '%s\n' "- API probe: skipped (curl missing)"
        work2md_error "curl is required to run the API probe."
        result=1
        ;;
      401|403)
        printf '%s\n' "- API probe: FAILED (${probe_status}, ${probe_url})"
        work2md_error "${title} credentials were rejected or lack access."
        result=1
        ;;
      000)
        printf '%s\n' "- API probe: FAILED (network, ${probe_url})"
        work2md_error "${title} API probe could not reach the Atlassian endpoint."
        result=1
        ;;
      *)
        printf '%s\n' "- API probe: FAILED (${probe_status:-unknown}, ${probe_url})"
        work2md_error "${title} API probe returned an unexpected status."
        result=1
        ;;
    esac
  else
    printf '%s\n' "- API probe: skipped (configuration incomplete)"
  fi

  return "$result"
}

work2md_validate_service_config() {
  local service="$1"
  local title token_expiry validation_status live_status
  local expiry_status expiry_days expiry_normalized
  local result=0
  local missing=()

  title="$(work2md_get_service_label "$service")" || return 1

  case "$service" in
    jira)
      [[ -n "${JIRA_BASE-}" ]] || missing+=("base")
      [[ -n "${JIRA_EMAIL-}" ]] || missing+=("email")
      [[ -n "${JIRA_TOKEN-}" ]] || missing+=("token")
      ;;
    confluence)
      [[ -n "${CONFLUENCE_BASE-}" ]] || missing+=("base")
      [[ -n "${CONFLUENCE_EMAIL-}" ]] || missing+=("email")
      [[ -n "${CONFLUENCE_TOKEN-}" ]] || missing+=("token")
      ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac

  printf '%s\n' "$title"
  if (( ${#missing[@]} == 0 )); then
    printf '%s\n' "- Config: OK"
  else
    if [[ " ${missing[*]} " == *" token "* ]]; then
      work2md_explain_missing_service_token "$service" || true
    fi
    work2md_error "${service}: missing $(IFS=', '; echo "${missing[*]}")"
    return 1
  fi

  token_expiry="$(work2md_get_service_value "$service" token_expiry)"
  eval "$(work2md_token_expiry_info "$token_expiry")"
  case "$expiry_status" in
    missing)
      printf '%s\n' "- Token expiry: (unset)"
      work2md_warn "${title} token expiry is not configured. Run: work2md-config ${service} set token-expiry YYYY-MM-DD"
      ;;
    invalid)
      printf '%s\n' "- Token expiry: ${token_expiry}"
      work2md_error "${title} token expiry has invalid format. Use YYYY-MM-DD or ISO-8601 datetime."
      result=1
      ;;
    expired)
      printf '%s\n' "- Token expiry: ${expiry_normalized}"
      work2md_error "${title} token is past its configured expiry date."
      result=1
      ;;
    expires_soon)
      printf '%s\n' "- Token expiry: ${expiry_normalized}"
      work2md_warn "${title} token expires in ${expiry_days} day(s)."
      ;;
    ok)
      printf '%s\n' "- Token expiry: ${expiry_normalized}"
      printf '%s\n' "- Expiry status: OK (${expiry_days} day(s) remaining)"
      ;;
  esac

  live_status="$(work2md_live_api_check "$service" || true)"
  case "$live_status" in
    ok)
      printf '%s\n' "- Live API check: OK"
      ;;
    curl-missing)
      printf '%s\n' "- Live API check: skipped"
      work2md_error "curl is required to run the live API check."
      result=1
      ;;
    401|403)
      printf '%s\n' "- Live API check: FAILED (${live_status})"
      work2md_error "${title} token is not usable with the current credentials or access rights."
      result=1
      ;;
    000)
      printf '%s\n' "- Live API check: FAILED (network)"
      work2md_error "${title} live API check could not reach the Atlassian endpoint."
      result=1
      ;;
    *)
      printf '%s\n' "- Live API check: FAILED (${live_status:-unknown})"
      work2md_error "${title} live API check returned an unexpected status."
      result=1
      ;;
  esac

  return "$result"
}

work2md_warn_service_token_expiry() {
  local service="$1"
  local title token_expiry
  local expiry_status expiry_days expiry_normalized

  title="$(work2md_get_service_label "$service")" || return 1
  token_expiry="$(work2md_get_service_value "$service" token_expiry)"
  eval "$(work2md_token_expiry_info "$token_expiry")"

  case "$expiry_status" in
    invalid)
      work2md_warn "${title} token expiry has invalid format: ${token_expiry}. Use YYYY-MM-DD or ISO-8601 datetime."
      ;;
    expired)
      work2md_warn "${title} token is past its configured expiry date (${expiry_normalized}). Export will still be attempted."
      ;;
    expires_soon)
      work2md_warn "${title} token expires in ${expiry_days} day(s) (${expiry_normalized})."
      ;;
  esac
}

work2md_explain_missing_service_token() {
  local service="$1"
  local title source env_var

  title="$(work2md_get_service_label "$service")" || return 1
  source="$(work2md_get_service_token_source "$service")" || return 1
  env_var="$(work2md_get_service_token_env_var_name "$service")" || return 1

  case "$source" in
    keyring-unavailable)
      work2md_error "${title} token backend is set to keyring, but no supported keyring command is available. Set ${env_var}, switch to the config backend, or configure $(work2md_get_keyring_provider_hint unavailable)."
      ;;
    keyring-missing)
      work2md_error "${title} token backend is set to keyring, but no token is stored in the system keyring."
      ;;
  esac
}

work2md_require_service_config() {
  local service="$1"
  local command_name

  if work2md_validate_service_config "$service" >/dev/null 2>&1; then
    return 0
  fi

  case "$service" in
    jira)
      command_name="work2md-config jira init"
      ;;
    confluence)
      command_name="work2md-config confluence init"
      ;;
    *)
      work2md_error "Unknown service: $service"
      exit 1
      ;;
  esac

  work2md_error "Missing ${service} configuration. Run: ${command_name}"
  exit 1
}

work2md_prompt_value() {
  local prompt="$1"
  local current_value="$2"
  local result_var="$3"
  local service="$4"
  local raw_value=""

  if [[ -n "$current_value" ]]; then
    read -rp "${prompt} [${current_value}]: " raw_value
    raw_value="${raw_value:-$current_value}"
  else
    while [[ -z "$raw_value" ]]; do
      read -rp "${prompt}: " raw_value
    done
  fi

  if [[ "$prompt" == *"base URL"* ]]; then
    raw_value="$(work2md_normalize_base_url "$service" "$raw_value")"
  fi

  printf -v "$result_var" '%s' "$raw_value"
}

work2md_prompt_secret() {
  local prompt="$1"
  local current_value="$2"
  local result_var="$3"
  local raw_value=""

  if [[ -n "$current_value" ]]; then
    read -rsp "${prompt} [press Enter to keep current]: " raw_value
    echo ""
    raw_value="${raw_value:-$current_value}"
  else
    while [[ -z "$raw_value" ]]; do
      read -rsp "${prompt}: " raw_value
      echo ""
    done
  fi

  printf -v "$result_var" '%s' "$raw_value"
}

work2md_prompt_service_token() {
  local service="$1"
  local prompt="$2"
  local current_value env_var env_value raw_value=""

  current_value="$(work2md_get_service_value "$service" token)" || return 1
  env_var="$(work2md_get_service_token_env_var_name "$service")" || return 1
  env_value="${!env_var-}"

  if [[ -n "$current_value" ]]; then
    work2md_prompt_secret "$prompt" "$current_value" raw_value
    work2md_set_service_token_for_backend "$service" "$raw_value"
    return 0
  fi

  if [[ -n "$env_value" ]]; then
    read -rsp "${prompt} [press Enter to keep ${env_var} from environment]: " raw_value
    echo ""
    if [[ -z "$raw_value" ]]; then
      work2md_set_service_token_for_backend "$service" "$env_value"
      return 0
    fi
  else
    while [[ -z "$raw_value" ]]; do
      read -rsp "${prompt}: " raw_value
      echo ""
    done
  fi

  work2md_set_service_token_for_backend "$service" "$raw_value"
}

work2md_configure_service_token_backend() {
  local service="$1"
  local backend="$2"
  local current_token=""

  current_token="$(work2md_get_service_value "$service" token)" || return 1
  work2md_set_service_token_backend_value "$service" "$backend" || return 1

  case "$backend" in
    config)
      if [[ -n "$current_token" ]]; then
        work2md_set_service_token_state "$service" "$current_token" config yes
      fi
      ;;
    keyring)
      if [[ -n "$current_token" ]]; then
        work2md_set_service_token_for_backend "$service" "$current_token" || return 1
      else
        work2md_set_service_token_state "$service" "" keyring-missing no
        case "$service" in
          jira) _WORK2MD_STORED_JIRA_TOKEN="" ;;
          confluence) _WORK2MD_STORED_CONFLUENCE_TOKEN="" ;;
        esac
      fi
      ;;
  esac
}

work2md_init_service_config() {
  local service="$1"

  case "$service" in
    jira)
      work2md_prompt_value "Jira base URL (https://company.atlassian.net)" "${JIRA_BASE-}" JIRA_BASE jira
      work2md_prompt_value "Jira email" "${JIRA_EMAIL-}" JIRA_EMAIL jira
      work2md_prompt_value "Jira token backend (config|keyring)" "$(work2md_get_service_token_backend jira)" JIRA_TOKEN_BACKEND jira
      work2md_prompt_service_token jira "Jira API token"
      work2md_prompt_optional_value "Jira token expiry (YYYY-MM-DD, optional)" "${JIRA_TOKEN_EXPIRES_AT-}" JIRA_TOKEN_EXPIRES_AT
      ;;
    confluence)
      work2md_prompt_value "Confluence base URL (https://company.atlassian.net)" "${CONFLUENCE_BASE-}" CONFLUENCE_BASE confluence
      work2md_prompt_value "Confluence email" "${CONFLUENCE_EMAIL-}" CONFLUENCE_EMAIL confluence
      work2md_prompt_value "Confluence token backend (config|keyring)" "$(work2md_get_service_token_backend confluence)" CONFLUENCE_TOKEN_BACKEND confluence
      work2md_prompt_service_token confluence "Confluence API token"
      work2md_prompt_optional_value "Confluence token expiry (YYYY-MM-DD, optional)" "${CONFLUENCE_TOKEN_EXPIRES_AT-}" CONFLUENCE_TOKEN_EXPIRES_AT
      ;;
    *)
      work2md_error "Unknown service: $service"
      return 1
      ;;
  esac
}

work2md_set_service_value() {
  local service="$1"
  local field="$2"
  local value="$3"

  case "$service:$field" in
    jira:base)
      JIRA_BASE="$(work2md_normalize_base_url jira "$value")"
      ;;
    jira:email)
      JIRA_EMAIL="$value"
      ;;
    jira:token)
      work2md_set_service_token_for_backend jira "$value"
      ;;
    jira:token-expiry)
      JIRA_TOKEN_EXPIRES_AT="$value"
      ;;
    jira:token-backend)
      work2md_configure_service_token_backend jira "$value"
      ;;
    confluence:base)
      CONFLUENCE_BASE="$(work2md_normalize_base_url confluence "$value")"
      ;;
    confluence:email)
      CONFLUENCE_EMAIL="$value"
      ;;
    confluence:token)
      work2md_set_service_token_for_backend confluence "$value"
      ;;
    confluence:token-expiry)
      CONFLUENCE_TOKEN_EXPIRES_AT="$value"
      ;;
    confluence:token-backend)
      work2md_configure_service_token_backend confluence "$value"
      ;;
    *)
      work2md_error "Unsupported setting: ${service} ${field}"
      return 1
      ;;
  esac
}
