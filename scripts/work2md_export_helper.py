#!/usr/bin/env python3
"""Helpers for export post-processing tasks."""

from __future__ import annotations

import argparse
import re
import sys
from collections import OrderedDict


def read_stdin_text() -> str:
    return sys.stdin.read()


def normalize_key(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "_", value.strip().lower())
    normalized = re.sub(r"_+", "_", normalized).strip("_")
    return normalized


def yaml_scalar(value: str) -> str:
    if value == "":
        return '""'
    if re.fullmatch(r"[A-Za-z0-9._:/@+-]+", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def command_filter_metadata_markdown(args: argparse.Namespace) -> int:
    raw = read_stdin_text()
    dropped = {normalize_key(item) for item in args.drop_field}
    output_lines: list[str] = []

    for line in raw.splitlines():
        match = re.match(r"^\s*-\s+([^:]+):", line)
        if match and normalize_key(match.group(1)) in dropped:
            continue
        output_lines.append(line)

    sys.stdout.write("\n".join(output_lines))
    if raw.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def parse_metadata_markdown(raw: str) -> OrderedDict[str, str]:
    fields: OrderedDict[str, str] = OrderedDict()
    for line in raw.splitlines():
        match = re.match(r"^\s*-\s+([^:]+):\s*(.*)\s*$", line)
        if not match:
            continue
        label = match.group(1).strip()
        value = match.group(2).strip()
        fields[normalize_key(label)] = value
    return fields


def command_markdown_metadata_to_front_matter(_: argparse.Namespace) -> int:
    raw = read_stdin_text()
    fields = parse_metadata_markdown(raw)

    title = fields.get("title", "")
    source = fields.get("source", "")
    source_id = fields.get("issue_key") or fields.get("page_id") or ""
    if title:
        fields.move_to_end("title", last=False)
    if source:
        fields.move_to_end("source", last=False)
    if source_id:
        fields["source_id"] = source_id
        fields.move_to_end("source_id", last=False)

    lines = ["---"]
    for key, value in fields.items():
        lines.append(f"{key}: {yaml_scalar(value)}")
    lines.append("---")
    sys.stdout.write("\n".join(lines) + "\n\n")
    return 0


def redact_emails(text: str) -> str:
    return re.sub(
        r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
        "[redacted-email]",
        text,
        flags=re.IGNORECASE,
    )


def redact_account_ids(text: str) -> str:
    text = re.sub(
        r"([?&]accountId=)[^&\s)]+",
        r"\1[redacted-account-id]",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"__WORK2MD_USER_MENTION__[A-Za-z0-9:._-]+__",
        "[redacted-account-id]",
        text,
    )
    text = re.sub(
        r"(\[~accountid:)[^\]]+(\])",
        r"\1[redacted-account-id]\2",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"\b[0-9]+:[0-9a-fA-F-]{8,}\b",
        "[redacted-account-id]",
        text,
    )
    return text


def redact_internal_urls(text: str, base_urls: list[str]) -> str:
    normalized_bases = sorted(
        {item.rstrip("/") for item in base_urls if item.strip()},
        key=len,
        reverse=True,
    )
    if not normalized_bases:
        return text

    url_pattern = re.compile(r"https?://[^\s<>)\"']+")

    def replace(match: re.Match[str]) -> str:
        url = match.group(0)
        for base in normalized_bases:
            if url.startswith(base):
                return "[redacted-internal-url]"
        return url

    return url_pattern.sub(replace, text)


def command_redact_text(args: argparse.Namespace) -> int:
    text = read_stdin_text()
    rules = []
    for value in args.rule:
        rules.extend([item.strip().lower() for item in value.split(",") if item.strip()])

    for rule in rules:
        if rule == "email":
            text = redact_emails(text)
        elif rule == "account-id":
            text = redact_account_ids(text)
        elif rule == "internal-url":
            text = redact_internal_urls(text, args.base_url)
        else:
            raise SystemExit(f"Unsupported redaction rule: {rule}")

    sys.stdout.write(text)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="work2md export helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    filter_parser = subparsers.add_parser("filter-metadata-markdown")
    filter_parser.add_argument("--drop-field", action="append", default=[])
    filter_parser.set_defaults(func=command_filter_metadata_markdown)

    front_matter_parser = subparsers.add_parser("markdown-metadata-to-front-matter")
    front_matter_parser.set_defaults(func=command_markdown_metadata_to_front_matter)

    redact_parser = subparsers.add_parser("redact-text")
    redact_parser.add_argument("--rule", action="append", default=[])
    redact_parser.add_argument("--base-url", action="append", default=[])
    redact_parser.set_defaults(func=command_redact_text)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
