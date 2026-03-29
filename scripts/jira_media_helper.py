#!/usr/bin/env python3
"""Helpers for Jira media attachment mapping and markdown rewriting."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from collections import defaultdict
from typing import Any


def walk_media(node: Any, refs_by_id: dict[str, dict[str, Any]], order: list[str], context: dict[str, Any]) -> None:
    if isinstance(node, dict):
        node_type = node.get("type")
        if node_type == "mediaSingle":
            attrs = node.get("attrs") or {}
            child_context = {
                "container": "mediaSingle",
                "layout": str(attrs.get("layout") or "").strip(),
                "width": attrs.get("width"),
            }
            for item in node.get("content") or []:
                walk_media(item, refs_by_id, order, child_context)
            return
        if node_type == "mediaGroup":
            child_context = {
                "container": "mediaGroup",
                "layout": "",
                "width": None,
            }
            for item in node.get("content") or []:
                walk_media(item, refs_by_id, order, child_context)
            return
        if node_type == "media":
            attrs = node.get("attrs") or {}
            if attrs.get("type") == "file":
                media_id = str(attrs.get("id") or "").strip()
                label = str(attrs.get("alt") or "").strip() or str(attrs.get("fileName") or "").strip()
                if media_id:
                    record = refs_by_id.setdefault(
                        media_id,
                        {
                            "label": "",
                            "container": "",
                            "layout": "",
                            "width": None,
                        },
                    )
                    if media_id not in order:
                        order.append(media_id)
                    if label and not record.get("label"):
                        record["label"] = label
                    if context.get("container") and not record.get("container"):
                        record["container"] = context["container"]
                    if context.get("layout") and not record.get("layout"):
                        record["layout"] = context["layout"]
                    if context.get("width") and record.get("width") in {None, ""}:
                        record["width"] = context["width"]
        for value in node.values():
            walk_media(value, refs_by_id, order, context)
    elif isinstance(node, list):
        for item in node:
            walk_media(item, refs_by_id, order, context)


def canonicalize_attachment(
    attachment: dict[str, Any],
    attachments_by_filename: dict[str, list[dict[str, Any]]],
    media_id: str,
) -> dict[str, Any]:
    filename = str(attachment.get("filename") or "").strip()
    match = re.match(rf"^(?P<base>.+) \({re.escape(media_id)}\)(?P<ext>\.[^.]+)$", filename)
    if not match:
        return attachment
    original_filename = f"{match.group('base')}{match.group('ext')}"
    candidates = attachments_by_filename.get(original_filename) or []
    if len(candidates) == 1:
        return candidates[0]
    return attachment


def build_media_mapping(issue: dict[str, Any], comments: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    refs_by_id: dict[str, dict[str, Any]] = {}
    order: list[str] = []

    walk_media(((issue.get("fields") or {}).get("description") or {}), refs_by_id, order, {})
    for comment in comments:
        walk_media((comment.get("body") or {}), refs_by_id, order, {})

    attachments = list((issue.get("fields") or {}).get("attachment") or [])
    attachments_by_filename: dict[str, list[dict[str, Any]]] = defaultdict(list)
    used_attachment_ids: set[str] = set()
    mapping: dict[str, dict[str, Any]] = {}

    for attachment in attachments:
        filename = str(attachment.get("filename") or "").strip()
        if filename:
            attachments_by_filename[filename].append(attachment)

    for media_id in order:
        ref = refs_by_id.get(media_id) or {}
        label = str(ref.get("label") or "").strip()
        selected = None
        used_attachment_id = ""

        for attachment in attachments:
            attachment_id = str(attachment.get("id") or "").strip()
            filename = str(attachment.get("filename") or "").strip()
            if not filename or not attachment_id or attachment_id in used_attachment_ids:
                continue
            if f"({media_id})" in filename or media_id in filename:
                selected = canonicalize_attachment(attachment, attachments_by_filename, media_id)
                used_attachment_id = attachment_id
                break

        if selected is None and label:
            candidates = attachments_by_filename.get(label) or []
            if len(candidates) == 1:
                selected = candidates[0]
                used_attachment_id = str(selected.get("id") or "").strip()
            else:
                for attachment in candidates:
                    attachment_id = str(attachment.get("id") or "").strip()
                    if attachment_id and attachment_id not in used_attachment_ids:
                        selected = attachment
                        used_attachment_id = attachment_id
                        break

        if selected is None:
            continue

        attachment_id = str(selected.get("id") or "").strip()
        if used_attachment_id:
            used_attachment_ids.add(used_attachment_id)

        mapping[f"media:{media_id}"] = {
            "attachment_id": attachment_id,
            "content_url": str(selected.get("content") or "").strip(),
            "label": str(selected.get("filename") or "").strip(),
            "mime_type": str(selected.get("mimeType") or "").strip(),
            "container": str(ref.get("container") or "").strip(),
            "layout": str(ref.get("layout") or "").strip(),
            "width": ref.get("width"),
        }

    unresolved = [media_id for media_id in order if f"media:{media_id}" not in mapping]
    unresolved_without_label = [
        media_id
        for media_id in unresolved
        if not str((refs_by_id.get(media_id) or {}).get("label") or "").strip()
    ]
    unused = [
        attachment
        for attachment in attachments
        if str(attachment.get("id") or "").strip() not in used_attachment_ids
    ]

    if unresolved and len(unused) == 1 and len(unresolved_without_label) == len(unresolved):
        attachment = unused[0]
        for media_id in unresolved:
            ref = refs_by_id.get(media_id) or {}
            mapping[f"media:{media_id}"] = {
                "attachment_id": str(attachment.get("id") or "").strip(),
                "content_url": str(attachment.get("content") or "").strip(),
                "label": str(attachment.get("filename") or "").strip(),
                "mime_type": str(attachment.get("mimeType") or "").strip(),
                "container": str(ref.get("container") or "").strip(),
                "layout": str(ref.get("layout") or "").strip(),
                "width": ref.get("width"),
            }

    return mapping


def normalize_destination(destination: str) -> str:
    destination = destination.strip()
    if destination.startswith("<") and destination.endswith(">"):
        return destination[1:-1].strip()
    return destination


def rewrite_label(label: str, destination: str, replacement: dict[str, Any]) -> str:
    if label == destination or label.startswith("media:") or destination.startswith("media:"):
        return str(replacement.get("label") or label)
    return label


def as_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def render_replacement(label: str, normalized_destination: str, replacement: dict[str, Any], profile: str) -> str:
    rewritten_label = rewrite_label(label, normalized_destination, replacement)
    rewritten_path = str(replacement.get("path") or normalized_destination)
    mime_type = str(replacement.get("mime_type") or "").strip().lower()
    layout = str(replacement.get("layout") or "").strip().lower()
    width = as_int(replacement.get("width"))

    if profile == "ai-friendly":
        if mime_type.startswith("image/"):
            alt = str(replacement.get("label") or rewritten_label or "image")
            lines = [f"[Image: {alt}](<{rewritten_path}>)", "- Type: image"]
            if layout:
                lines.append(f"- Original layout: {layout}")
            if width:
                lines.append(f"- Original width: {width}")
            return "\n".join(lines)
        attachment_label = str(replacement.get("label") or rewritten_label or "attachment")
        return f"[Attachment: {attachment_label}](<{rewritten_path}>)"

    if mime_type.startswith("image/"):
        alt = str(replacement.get("label") or rewritten_label or "image")
        escaped_alt = html.escape(alt, quote=True)
        if layout in {"wrap-left", "wrap-right"}:
            return f"[{rewritten_label}](<{rewritten_path}>)"
        if layout == "center":
            width_attr = f' width="{width}"' if width else ""
            return f'<div style="text-align: center"><img src="{rewritten_path}" alt="{escaped_alt}"{width_attr} /></div>'
        if layout in {"align-end", "right"}:
            width_attr = f' width="{width}"' if width else ""
            return f'<div style="text-align: right"><img src="{rewritten_path}" alt="{escaped_alt}"{width_attr} /></div>'
        if width:
            return f'<img src="{rewritten_path}" alt="{escaped_alt}" width="{width}" />'
        return f"![{alt}](<{rewritten_path}>)"

    return f"[{rewritten_label}](<{rewritten_path}>)"


def rewrite_markdown(text: str, mapping: dict[str, dict[str, Any]], profile: str) -> str:
    markdown_link_pattern = re.compile(r"(\[)([^\]]+)(\]\()([^)\n]+)(\))")
    html_attr_pattern = re.compile(r"((?:src|href)=[\"'])([^\"']+)([\"'])")

    def markdown_repl(match: re.Match[str]) -> str:
        label = match.group(2)
        destination = match.group(4)
        normalized_destination = normalize_destination(destination)
        replacement = mapping.get(normalized_destination)
        if replacement is None:
            return match.group(0)
        return render_replacement(label, normalized_destination, replacement, profile)

    def html_attr_repl(match: re.Match[str]) -> str:
        destination = match.group(2)
        normalized_destination = normalize_destination(destination)
        replacement = mapping.get(normalized_destination)
        if replacement is None:
            return match.group(0)
        rewritten_path = replacement.get("path") or normalized_destination
        return f"{match.group(1)}{rewritten_path}{match.group(3)}"

    text = markdown_link_pattern.sub(markdown_repl, text)
    return html_attr_pattern.sub(html_attr_repl, text)


def command_extract_map(args: argparse.Namespace) -> int:
    with open(args.issue_file, "r", encoding="utf-8") as fh:
        issue = json.load(fh)

    comments: list[dict[str, Any]] = []
    with open(args.comments_file, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if raw_line:
                comments.append(json.loads(raw_line))

    json.dump(build_media_mapping(issue, comments), sys.stdout, ensure_ascii=False, sort_keys=True)
    return 0


def command_rewrite_markdown(args: argparse.Namespace) -> int:
    with open(args.mapping_file, "r", encoding="utf-8") as fh:
        mapping = json.load(fh)

    text = os.environ.get("JIRA_MARKDOWN_INPUT")
    if text is None:
        text = sys.stdin.read()

    sys.stdout.write(rewrite_markdown(text, mapping, args.profile))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Jira media helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract_map_parser = subparsers.add_parser("extract-map")
    extract_map_parser.add_argument("--issue-file", required=True)
    extract_map_parser.add_argument("--comments-file", required=True)
    extract_map_parser.set_defaults(func=command_extract_map)

    rewrite_parser = subparsers.add_parser("rewrite-markdown")
    rewrite_parser.add_argument("--mapping-file", required=True)
    rewrite_parser.add_argument("--profile", default="default")
    rewrite_parser.set_defaults(func=command_rewrite_markdown)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
