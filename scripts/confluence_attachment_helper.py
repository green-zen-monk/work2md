#!/usr/bin/env python3
"""Helpers for discovering and rewriting Confluence attachment references."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import urllib.parse
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


def absolutize_url(url: str, base: str) -> str:
    url = html.unescape((url or "").strip())
    if not url:
        return ""
    if url.startswith(("http://", "https://")):
        return url
    parsed_base = urllib.parse.urlsplit(base)
    origin = f"{parsed_base.scheme}://{parsed_base.netloc}" if parsed_base.scheme and parsed_base.netloc else base.rstrip("/")
    if url.startswith("/"):
        return origin + url
    return base.rstrip("/") + "/" + url.lstrip("/")


def construct_download_url(link_base: str, page_id: str, filename: str) -> str:
    encoded = urllib.parse.quote(filename, safe="")
    return f"{link_base.rstrip('/')}/download/attachments/{page_id}/{encoded}?api=v2"


def construct_download_url_with_version(link_base: str, content_id: str, filename: str, version: str) -> str:
    encoded = urllib.parse.quote(filename, safe="")
    if version:
      return f"{link_base.rstrip('/')}/download/attachments/{content_id}/{encoded}?version={urllib.parse.quote(version, safe='')}&api=v2"
    return construct_download_url(link_base, content_id, filename)


def canonical_filename_from_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    path = urllib.parse.unquote(parsed.path)
    return path.rsplit("/", 1)[-1].replace("+", " ").strip()


def looks_like_attachment_filename(filename: str) -> bool:
    return bool(re.match(r".+\.[A-Za-z0-9]{1,10}$", (filename or "").strip()))


def is_attachment_url(url: str) -> bool:
    return "/download/attachments/" in url or "/download/thumbnails/" in url


def is_direct_download_url(url: str) -> bool:
    return "/download/attachments/" in url


def download_url_score(url: str) -> int:
    if not url:
        return 0
    score = 0
    if is_direct_download_url(url):
        score += 20
    parsed = urllib.parse.urlsplit(url)
    params = urllib.parse.parse_qs(parsed.query)
    if "version" in params:
        score += 10
    if "modificationDate" in params:
        score += 5
    if "cacheVersion" in params:
        score += 3
    if "api" in params:
        score += 1
    return score


def choose_download_url(current: str, candidate: str) -> str:
    if not candidate:
        return current
    if not current:
        return candidate
    if download_url_score(candidate) >= download_url_score(current):
        return candidate
    return current


def add_entry(mapping: dict[str, dict[str, Any]], filename: str, download_url: str, aliases: list[str] | None = None) -> None:
    filename = html.unescape((filename or "").strip())
    if not filename or not looks_like_attachment_filename(filename):
        return
    entry = mapping.setdefault(filename, {"download_url": "", "aliases": []})
    entry["download_url"] = choose_download_url(str(entry.get("download_url") or "").strip(), download_url)

    alias_list = entry.setdefault("aliases", [])
    for alias in aliases or []:
        alias = html.unescape((alias or "").strip())
        if alias and alias not in alias_list:
            alias_list.append(alias)
    if filename not in alias_list:
        alias_list.append(filename)


def feed_storage(mapping: dict[str, dict[str, Any]], raw: str, page_id: str, link_base: str) -> None:
    pattern = re.compile(
        r"<ri:attachment\b(?P<attrs>[^>]*)>(?P<body>.*?)</ri:attachment>|<ri:attachment\b(?P<self_attrs>[^>]*)/>",
        re.IGNORECASE | re.DOTALL,
    )
    for match in pattern.finditer(raw or ""):
        attrs = match.group("attrs") or match.group("self_attrs") or ""
        body = match.group("body") or ""
        filename_match = re.search(r'ri:filename="([^"]+)"', attrs, re.IGNORECASE)
        if not filename_match:
            continue
        filename = html.unescape(filename_match.group(1)).strip()
        if not filename or not looks_like_attachment_filename(filename):
            continue
        content_id_match = re.search(r'ri:content-id="([^"]+)"', body, re.IGNORECASE)
        version_match = re.search(r'ri:version-at-save="([^"]+)"', attrs, re.IGNORECASE)
        content_id = (content_id_match.group(1).strip() if content_id_match else "") or page_id
        version = version_match.group(1).strip() if version_match else ""
        add_entry(
            mapping,
            filename,
            construct_download_url_with_version(link_base, content_id, filename, version),
            [filename],
        )


class AttachmentHtmlParser(HTMLParser):
    def __init__(self, mapping: dict[str, dict[str, Any]], page_id: str, link_base: str) -> None:
        super().__init__()
        self.mapping = mapping
        self.page_id = page_id
        self.link_base = link_base

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr_map = {key: html.unescape(value or "").strip() for key, value in attrs}

        if tag == "img":
            filename = attr_map.get("alt") or attr_map.get("title") or ""
            direct_url = ""
            data_image_src = absolutize_url(attr_map.get("data-image-src") or "", self.link_base)
            src = absolutize_url(attr_map.get("src") or "", self.link_base)

            if is_direct_download_url(data_image_src):
                direct_url = data_image_src
            elif is_direct_download_url(src):
                direct_url = src
            elif filename and ("placeholder/unknown-attachment" in src or "/download/thumbnails/" in src):
                direct_url = construct_download_url(self.link_base, self.page_id, filename)

            aliases = [filename]
            if src:
                aliases.append(src)
            if data_image_src:
                aliases.append(data_image_src)
            if (not filename or not looks_like_attachment_filename(filename)) and direct_url:
                filename = canonical_filename_from_url(direct_url)
            add_entry(self.mapping, filename, direct_url, aliases)
            return

        if tag != "a":
            return

        href = absolutize_url(attr_map.get("href") or "", self.link_base)
        if not is_attachment_url(href):
            return

        filename = canonical_filename_from_url(href)
        title = attr_map.get("title") or ""
        if not looks_like_attachment_filename(filename) and looks_like_attachment_filename(title):
            filename = title
        if not looks_like_attachment_filename(filename):
            return
        direct_url = href
        if "/download/thumbnails/" in href and filename:
            direct_url = construct_download_url(self.link_base, self.page_id, filename)
        add_entry(self.mapping, filename, direct_url, [filename, href])


def feed_html(mapping: dict[str, dict[str, Any]], raw: str, page_id: str, link_base: str) -> None:
    raw = raw or ""
    if not raw.strip():
        return
    parser = AttachmentHtmlParser(mapping, page_id, link_base)
    parser.feed(raw)


def extract_map(page_json: dict[str, Any], comments: list[dict[str, Any]], page_id: str, link_base: str) -> dict[str, dict[str, Any]]:
    mapping: dict[str, dict[str, Any]] = {}

    page_body = page_json.get("body") or {}
    for field in ("storage", "view", "export_view", "styled_view"):
        raw = ((page_body.get(field) or {}).get("value") or "")
        if field == "storage":
            feed_storage(mapping, raw, page_id, link_base)
        else:
            feed_html(mapping, raw, page_id, link_base)

    for item in comments:
        body = item.get("body") or {}
        for field in ("storage", "view", "export_view", "styled_view"):
            raw = ((body.get(field) or {}).get("value") or "")
            if field == "storage":
                feed_storage(mapping, raw, page_id, link_base)
            else:
                feed_html(mapping, raw, page_id, link_base)

    for filename, entry in mapping.items():
        if not str(entry.get("download_url") or "").strip():
            entry["download_url"] = construct_download_url(link_base, page_id, filename)

    return mapping


def command_extract_map(args: argparse.Namespace) -> int:
    with open(args.page_file, "r", encoding="utf-8") as fh:
        page_json = json.load(fh)

    comments: list[dict[str, Any]] = []
    with open(args.comments_file, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if raw_line:
                comments.append(json.loads(raw_line))

    mapping = extract_map(page_json, comments, args.page_id, args.link_base)
    json.dump(mapping, sys.stdout, ensure_ascii=False, sort_keys=True)
    return 0


def command_build_rewrite_map(args: argparse.Namespace) -> int:
    with open(args.mapping_file, "r", encoding="utf-8") as fh:
        mapping = json.load(fh)

    rewrite_map: dict[str, str] = {}
    prefix = args.asset_prefix.rstrip("/")
    for filename, entry in mapping.items():
        rel_path = str((entry or {}).get("path") or "").strip()
        if not rel_path:
            rel_path = f"{prefix}/{filename}"
        rewrite_map[filename] = rel_path
        for alias in (entry.get("aliases") or []):
            alias = str(alias or "").strip()
            if alias:
                rewrite_map[alias] = rel_path

    json.dump(rewrite_map, sys.stdout, ensure_ascii=False, sort_keys=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Confluence attachment helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract_parser = subparsers.add_parser("extract-map")
    extract_parser.add_argument("--page-file", required=True)
    extract_parser.add_argument("--comments-file", required=True)
    extract_parser.add_argument("--page-id", required=True)
    extract_parser.add_argument("--link-base", required=True)
    extract_parser.set_defaults(func=command_extract_map)

    rewrite_parser = subparsers.add_parser("build-rewrite-map")
    rewrite_parser.add_argument("--mapping-file", required=True)
    rewrite_parser.add_argument("--asset-prefix", default="assets")
    rewrite_parser.set_defaults(func=command_build_rewrite_map)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
