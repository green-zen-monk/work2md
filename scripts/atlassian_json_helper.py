#!/usr/bin/env python3
import argparse
import json
import shlex
import sys
from typing import Any


def read_stdin_json() -> Any:
    raw = sys.stdin.read()
    if not raw.strip():
        return None
    return json.loads(raw)


def body_as_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        inner = value.get("value")
        return inner if isinstance(inner, str) else ""
    return ""


def split_path(path: str) -> list[str]:
    if not path or path == ".":
        return []
    return [part for part in path.split(".") if part]


def get_path(data: Any, path: str) -> Any:
    current = data
    for part in split_path(path):
        if isinstance(current, dict):
            if part not in current:
                return None
            current = current[part]
            continue
        if isinstance(current, list):
            try:
                index = int(part)
            except ValueError:
                return None
            if index < 0 or index >= len(current):
                return None
            current = current[index]
            continue
        return None
    return current


def coerce_string(value: Any, default: str = "") -> str:
    if value is None:
        return default
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, bool):
        return "true" if value else "false"
    return default


def emit_shell_assignments(mapping: dict[str, Any]) -> None:
    for key, value in mapping.items():
        print(f"{key}={shlex.quote(coerce_string(value, ''))}")


def command_debug_body_candidates(args: argparse.Namespace) -> int:
    data = read_stdin_json()

    def body_len(path: str) -> int:
        value = get_path(data or {}, path)
        return len(body_as_text(value))

    parts = [
        args.label,
        f"storage={body_len('body.storage')}",
        f"view={body_len('body.view')}",
        f"export_view={body_len('body.export_view')}",
        f"styled_view={body_len('body.styled_view')}",
        f"atlas_doc_format={body_len('body.atlas_doc_format')}",
        f"value={len(coerce_string(get_path(data or {}, 'value'), ''))}",
    ]
    print("[debug] " + " ".join(parts))
    return 0


def command_body_value(_: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    for path in ("body.storage", "body.view", "body.export_view", "body.styled_view", "value"):
        text = body_as_text(get_path(data, path)).strip()
        if text:
            print(text)
            return 0
    print("")
    return 0


def command_body_field(args: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    if args.field == "value":
        print(coerce_string(get_path(data, "value"), ""))
        return 0
    print(body_as_text(get_path(data, f"body.{args.field}")))
    return 0


def command_adf_body(_: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    text = body_as_text(get_path(data, "body.atlas_doc_format"))
    print(text if text else "")
    return 0


def command_get_string(args: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    for path in args.paths:
        value = get_path(data, path)
        text = coerce_string(value, "").strip()
        if text:
            print(text)
            return 0
    print(args.default)
    return 0


def command_get_string_file(args: argparse.Namespace) -> int:
    data = load_json_file(args.file)
    for path in args.paths:
        value = get_path(data, path)
        text = coerce_string(value, "").strip()
        if text:
            print(text)
            return 0
    print(args.default)
    return 0


def command_dump_json(args: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    value = get_path(data, args.path)
    if value is None:
        sys.stdout.write(args.default_json)
        return 0
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    return 0


def command_array_to_jsonl(args: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    value = get_path(data, args.path)
    if not isinstance(value, list):
        return 0
    for item in value:
        sys.stdout.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


def command_array_field(args: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    value = get_path(data, args.path)
    if not isinstance(value, list):
        return 0
    for item in value:
        text = coerce_string(get_path(item, args.field), "").strip()
        if text:
            print(text)
    return 0


def command_confluence_page_meta(args: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    page_id = coerce_string(get_path(data, "id"), args.default_page_id)
    base = coerce_string(get_path(data, "_links.base"), "")
    webui = coerce_string(get_path(data, "_links.webui"), "")
    emit_shell_assignments(
        {
            "title": coerce_string(get_path(data, "title"), f"Page {page_id}"),
            "page_id": page_id,
            "space_key": coerce_string(get_path(data, "space.key"), ""),
            "version_number": coerce_string(get_path(data, "version.number"), ""),
            "created": coerce_string(get_path(data, "history.createdDate"), ""),
            "updated": coerce_string(get_path(data, "version.when"), ""),
            "created_by": coerce_string(get_path(data, "history.createdBy.displayName"), ""),
            "updated_by": coerce_string(get_path(data, "version.by.displayName"), ""),
            "confluence_link_base": base,
            "page_url": (base + webui) if base and webui else "",
        }
    )
    return 0


def command_confluence_comment_meta(_: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    emit_shell_assignments(
        {
            "comment_id": coerce_string(get_path(data, "id"), ""),
            "comment_author": coerce_string(
                get_path(data, "history.createdBy.displayName"),
                coerce_string(
                    get_path(data, "version.by.displayName"),
                    coerce_string(get_path(data, "version.authorId"), "Unknown"),
                ),
            ),
            "comment_created": coerce_string(
                get_path(data, "history.createdDate"),
                coerce_string(
                    get_path(data, "version.createdAt"),
                    coerce_string(
                        get_path(data, "version.when"),
                        coerce_string(get_path(data, "version.createdAt"), ""),
                    ),
                ),
            ),
            "comment_updated": coerce_string(
                get_path(data, "version.when"),
                coerce_string(
                    get_path(data, "version.createdAt"),
                    coerce_string(get_path(data, "version.createdAt"), ""),
                ),
            ),
            "comment_webui": coerce_string(get_path(data, "_links.webui"), ""),
        }
    )
    return 0


def command_confluence_list_meta(_: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    emit_shell_assignments(
        {
            "size": coerce_string(get_path(data, "size"), "0"),
            "total": coerce_string(get_path(data, "total"), ""),
            "next_relative": coerce_string(get_path(data, "_links.next"), ""),
        }
    )
    return 0


def command_confluence_attachment_meta(_: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    emit_shell_assignments(
        {
            "filename": coerce_string(get_path(data, "title"), ""),
            "download_rel": coerce_string(get_path(data, "_links.download"), ""),
            "media_type": coerce_string(
                get_path(data, "metadata.mediaType"),
                coerce_string(get_path(data, "extensions.mediaType"), ""),
            ),
        }
    )
    return 0


def command_jira_issue_meta(args: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    description = get_path(data, "fields.description")
    labels = get_path(data, "fields.labels")
    if isinstance(labels, list):
        label_values = [coerce_string(item, "").strip() for item in labels]
        label_values = [item for item in label_values if item]
    else:
        label_values = []
    emit_shell_assignments(
        {
            "summary": coerce_string(get_path(data, "fields.summary"), ""),
            "key": coerce_string(get_path(data, "key"), args.default_issue),
            "status": coerce_string(get_path(data, "fields.status.name"), ""),
            "issuetype": coerce_string(get_path(data, "fields.issuetype.name"), ""),
            "project": coerce_string(get_path(data, "fields.project.key"), ""),
            "priority": coerce_string(get_path(data, "fields.priority.name"), ""),
            "labels": ", ".join(label_values),
            "created": coerce_string(get_path(data, "fields.created"), ""),
            "updated": coerce_string(get_path(data, "fields.updated"), ""),
            "reporter": coerce_string(get_path(data, "fields.reporter.displayName"), ""),
            "assignee": coerce_string(get_path(data, "fields.assignee.displayName"), "Unassigned"),
            "description_json": json.dumps(description, ensure_ascii=False, separators=(",", ":")),
        }
    )
    return 0


def command_jira_comment_meta(_: argparse.Namespace) -> int:
    data = read_stdin_json() or {}
    body = get_path(data, "body")
    emit_shell_assignments(
        {
            "comment_id": coerce_string(get_path(data, "id"), ""),
            "comment_author": coerce_string(get_path(data, "author.displayName"), "Unknown"),
            "comment_created": coerce_string(get_path(data, "created"), ""),
            "comment_updated": coerce_string(get_path(data, "updated"), ""),
            "comment_body_json": json.dumps(body, ensure_ascii=False, separators=(",", ":")),
        }
    )
    return 0


def load_json_file(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def command_json_map_keys(args: argparse.Namespace) -> int:
    data = load_json_file(args.file)
    if isinstance(data, dict):
        for key in data.keys():
            print(key)
    return 0


def command_json_map_get(args: argparse.Namespace) -> int:
    data = load_json_file(args.file)
    entry = data.get(args.key) if isinstance(data, dict) else None
    value = get_path(entry or {}, args.field)
    print(coerce_string(value, args.default))
    return 0


def command_file_map_get(args: argparse.Namespace) -> int:
    data = load_json_file(args.file)
    parent = get_path(data, args.path)
    entry = parent.get(args.key) if isinstance(parent, dict) else None
    value = get_path(entry or {}, args.field)
    print(coerce_string(value, args.default))
    return 0


def command_json_map_set(args: argparse.Namespace) -> int:
    data = load_json_file(args.file)
    if not isinstance(data, dict):
        data = {}
    if args.field in {"", "."}:
        data[args.key] = args.value
        with open(args.file, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
        return 0

    entry = data.get(args.key)
    if not isinstance(entry, dict):
        entry = {}
        data[args.key] = entry

    current = entry
    parts = split_path(args.field)
    if not parts:
        return 1
    for part in parts[:-1]:
        next_value = current.get(part)
        if not isinstance(next_value, dict):
            next_value = {}
            current[part] = next_value
        current = next_value
    current[parts[-1]] = args.value

    with open(args.file, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    debug_parser = subparsers.add_parser("debug-body-candidates")
    debug_parser.add_argument("--label", required=True)
    debug_parser.set_defaults(func=command_debug_body_candidates)

    body_value_parser = subparsers.add_parser("body-value")
    body_value_parser.set_defaults(func=command_body_value)

    body_field_parser = subparsers.add_parser("body-field")
    body_field_parser.add_argument("--field", required=True)
    body_field_parser.set_defaults(func=command_body_field)

    adf_body_parser = subparsers.add_parser("adf-body")
    adf_body_parser.set_defaults(func=command_adf_body)

    get_string_parser = subparsers.add_parser("get-string")
    get_string_parser.add_argument("--default", default="")
    get_string_parser.add_argument("--path", dest="paths", action="append", required=True)
    get_string_parser.set_defaults(func=command_get_string)

    get_string_file_parser = subparsers.add_parser("get-string-file")
    get_string_file_parser.add_argument("--file", required=True)
    get_string_file_parser.add_argument("--default", default="")
    get_string_file_parser.add_argument("--path", dest="paths", action="append", required=True)
    get_string_file_parser.set_defaults(func=command_get_string_file)

    dump_json_parser = subparsers.add_parser("dump-json")
    dump_json_parser.add_argument("--path", required=True)
    dump_json_parser.add_argument("--default-json", default="null")
    dump_json_parser.set_defaults(func=command_dump_json)

    array_to_jsonl_parser = subparsers.add_parser("array-to-jsonl")
    array_to_jsonl_parser.add_argument("--path", required=True)
    array_to_jsonl_parser.set_defaults(func=command_array_to_jsonl)

    array_field_parser = subparsers.add_parser("array-field")
    array_field_parser.add_argument("--path", required=True)
    array_field_parser.add_argument("--field", required=True)
    array_field_parser.set_defaults(func=command_array_field)

    confluence_page_meta_parser = subparsers.add_parser("confluence-page-meta")
    confluence_page_meta_parser.add_argument("--default-page-id", required=True)
    confluence_page_meta_parser.set_defaults(func=command_confluence_page_meta)

    confluence_comment_meta_parser = subparsers.add_parser("confluence-comment-meta")
    confluence_comment_meta_parser.set_defaults(func=command_confluence_comment_meta)

    confluence_list_meta_parser = subparsers.add_parser("confluence-list-meta")
    confluence_list_meta_parser.set_defaults(func=command_confluence_list_meta)

    confluence_attachment_meta_parser = subparsers.add_parser("confluence-attachment-meta")
    confluence_attachment_meta_parser.set_defaults(func=command_confluence_attachment_meta)

    jira_issue_meta_parser = subparsers.add_parser("jira-issue-meta")
    jira_issue_meta_parser.add_argument("--default-issue", required=True)
    jira_issue_meta_parser.set_defaults(func=command_jira_issue_meta)

    jira_comment_meta_parser = subparsers.add_parser("jira-comment-meta")
    jira_comment_meta_parser.set_defaults(func=command_jira_comment_meta)

    json_map_keys_parser = subparsers.add_parser("json-map-keys")
    json_map_keys_parser.add_argument("--file", required=True)
    json_map_keys_parser.set_defaults(func=command_json_map_keys)

    json_map_get_parser = subparsers.add_parser("json-map-get")
    json_map_get_parser.add_argument("--file", required=True)
    json_map_get_parser.add_argument("--key", required=True)
    json_map_get_parser.add_argument("--field", required=True)
    json_map_get_parser.add_argument("--default", default="")
    json_map_get_parser.set_defaults(func=command_json_map_get)

    file_map_get_parser = subparsers.add_parser("file-map-get")
    file_map_get_parser.add_argument("--file", required=True)
    file_map_get_parser.add_argument("--path", required=True)
    file_map_get_parser.add_argument("--key", required=True)
    file_map_get_parser.add_argument("--field", required=True)
    file_map_get_parser.add_argument("--default", default="")
    file_map_get_parser.set_defaults(func=command_file_map_get)

    json_map_set_parser = subparsers.add_parser("json-map-set")
    json_map_set_parser.add_argument("--file", required=True)
    json_map_set_parser.add_argument("--key", required=True)
    json_map_set_parser.add_argument("--field", required=True)
    json_map_set_parser.add_argument("--value", required=True)
    json_map_set_parser.set_defaults(func=command_json_map_set)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
