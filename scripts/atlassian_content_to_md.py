#!/usr/bin/env python3
import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from html.entities import name2codepoint
from html.parser import HTMLParser


LIST_INDENT = 4


def norm_ws(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def escape_md(text: str) -> str:
    return text.replace("\\", "\\\\").replace("|", "\\|")


def fenced_code(body: str, language: str = "") -> str:
    body = body.replace("\r\n", "\n").replace("\r", "\n").strip("\n")
    if not body:
        return "```" + language + "\n```"
    return f"```{language}\n{body}\n```"


def render_admonition(label: str, content: str, profile: str = "default") -> str:
    icons = {
        "INFO": "ℹ️",
        "NOTE": "📝",
        "TIP": "💡",
        "SUCCESS": "✅",
        "WARNING": "⚠️",
        "ERROR": "❌",
        "PANEL": "📌",
    }
    marker = f"[{label}]" if profile == "ai-friendly" else icons.get(label, f"[{label}]")
    lines = content.splitlines() or [""]
    rendered: list[str] = []
    for index, line in enumerate(lines):
        if index == 0:
            rendered.append(f"> {marker} {line}".rstrip())
        else:
            rendered.append(f"> {line}".rstrip())
    return "\n".join(rendered)


def render_decision_block(items: list[str], profile: str = "default") -> str:
    if not items:
        return ""

    heading = "[DECISION]" if profile == "ai-friendly" else "🌳 Decision"
    lines = [heading, ""]
    for index, item in enumerate(items, start=1):
        lines.append(f"{index}. {item}")
    return blockquote("\n".join(lines))


def blockquote(text: str, prefix: str = "> ") -> str:
    lines = text.splitlines() or [""]
    return "\n".join(prefix + line if line else prefix.rstrip() for line in lines)


class FallbackTextExtractor(HTMLParser):
    BLOCK_TAGS = {
        "article",
        "br",
        "div",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "header",
        "hr",
        "li",
        "ol",
        "p",
        "pre",
        "section",
        "table",
        "tr",
        "ul",
    }

    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in {"script", "style"}:
            self.skip_depth += 1
            return
        if self.skip_depth == 0 and tag in self.BLOCK_TAGS:
            self.parts.append("\n")
        if self.skip_depth == 0 and tag == "li":
            self.parts.append("- ")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style"} and self.skip_depth > 0:
            self.skip_depth -= 1
            return
        if self.skip_depth == 0 and tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self.skip_depth == 0:
            self.parts.append(data)

    def get_text(self) -> str:
        text = "".join(self.parts)
        text = html.unescape(text)
        text = re.sub(r"\r\n?", "\n", text)
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n[ \t]+", "\n", text)
        text = re.sub(r"[ \t]{2,}", " ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()


class ConfluenceStorageRenderer:
    def __init__(self, panel_map: dict[str, dict[str, str]] | None = None, profile: str = "default") -> None:
        self.panel_map = panel_map or {}
        self.profile = profile

    BLOCK_TAGS = {
        "ac_adf-extension",
        "ac_adf-fallback",
        "ac_layout",
        "ac_layout-section",
        "ac_layout-cell",
        "ac_rich-text-body",
        "ac_task-list",
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

    def render(self, raw: str) -> str:
        if not raw.strip():
            return ""

        sanitized = self.sanitize_xml(raw)
        wrapped = f"<root>{sanitized}</root>"

        try:
            root = ET.fromstring(wrapped)
        except ET.ParseError:
            parser = FallbackTextExtractor()
            parser.feed(raw)
            return parser.get_text()

        output = "\n\n".join(self.render_children_blocks(root)).strip()
        output = re.sub(r"\n{3,}", "\n\n", output)
        return output

    def replace_named_entities(self, text: str) -> str:
        def repl(match: re.Match[str]) -> str:
            name = match.group(1)
            if name in {"lt", "gt", "amp", "quot", "apos"}:
                return match.group(0)
            codepoint = name2codepoint.get(name)
            if codepoint is None:
                return match.group(0)
            return f"&#{codepoint};"

        return re.sub(r"&([A-Za-z][A-Za-z0-9]+);", repl, text)

    def sanitize_xml(self, text: str) -> str:
        text = self.replace_named_entities(text)
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

    def tag_name(self, node: ET.Element) -> str:
        tag = node.tag
        if "}" in tag:
            return tag.rsplit("}", 1)[1]
        return tag

    def text_content(self, node: ET.Element) -> str:
        parts: list[str] = []
        if node.text:
            parts.append(node.text)
        for child in list(node):
            parts.append(self.text_content(child))
            if child.tail:
                parts.append(child.tail)
        return "".join(parts)

    def macro_parameter(self, node: ET.Element, name: str) -> str:
        for child in list(node):
            if self.tag_name(child) == "ac_parameter" and child.attrib.get("ac_name") == name:
                return norm_ws(self.text_content(child))
        return ""

    def panel_label_for_macro(self, node: ET.Element, macro_name: str) -> str:
        local_id = (
            node.attrib.get("ac_local-id", "").strip()
            or node.attrib.get("local-id", "").strip()
        )
        if local_id:
            panel_type = str((self.panel_map.get(local_id) or {}).get("panelType") or "").strip()
            if panel_type:
                return "PANEL" if panel_type.lower() == "custom" else panel_type.upper()
        return macro_name.upper()

    def inline_style(self, node: ET.Element) -> str:
        style = node.attrib.get("style", "")
        parts: list[str] = []
        for prop in ("color", "background-color"):
            match = re.search(rf"(?:^|;)\s*{re.escape(prop)}\s*:\s*([^;]+)", style, re.IGNORECASE)
            if match:
                parts.append(f"{prop}: {match.group(1).strip()}")
        return "; ".join(parts)

    def render_macro_inline(self, node: ET.Element) -> str:
        name = (node.attrib.get("ac_name") or "").strip().lower()

        if name == "status":
            title = self.macro_parameter(node, "title") or "status"
            return f"[{title}]"

        if name == "view-file":
            for child in list(node):
                if self.tag_name(child) != "ac_parameter":
                    continue
                if child.attrib.get("ac_name") != "name":
                    continue
                for grandchild in list(child):
                    if self.tag_name(grandchild) == "ri_attachment":
                        filename = grandchild.attrib.get("ri_filename", "").strip()
                        if filename:
                            return f"[{filename}]({filename})"

        if name == "profile-picture":
            return ""

        return norm_ws(self.text_content(node))

    def mention_placeholder(self, account_id: str) -> str:
        account_id = account_id.strip()
        if not account_id:
            return "@user"
        return f"__WORK2MD_USER_MENTION__{account_id}__"

    def is_ai_friendly(self) -> bool:
        return self.profile == "ai-friendly"

    def image_layout(self, node: ET.Element) -> str:
        return (node.attrib.get("ac_layout") or "").strip().lower()

    def render_image(self, node: ET.Element) -> str:
        alt = (node.attrib.get("ac_alt") or "").strip()
        src = ""
        width = (node.attrib.get("ac_width") or "").strip()
        height = (node.attrib.get("ac_height") or "").strip()
        align = (node.attrib.get("ac_align") or "").strip().lower()
        layout = self.image_layout(node)
        caption = ""

        for child in list(node):
            child_tag = self.tag_name(child)
            if child_tag == "ri_attachment":
                filename = child.attrib.get("ri_filename", "").strip()
                if filename:
                    src = filename
                    if not alt:
                        alt = filename
            elif child_tag == "ri_url":
                src = child.attrib.get("ri_value", "").strip()
            elif child_tag == "ac_caption":
                caption = "\n".join(self.render_children_blocks(child)).strip() or self.render_inline_children(child).strip()

        alt = alt or "image"
        if not src:
            return f"![{alt}]()"

        if self.is_ai_friendly():
            lines = [f"[Image: {alt}](<{src}>)", "- Type: image"]
            if layout:
                lines.append(f"- Original layout: {layout}")
            if align:
                lines.append(f"- Original alignment: {align}")
            if width.isdigit():
                lines.append(f"- Original width: {width}")
            if height.isdigit():
                lines.append(f"- Original height: {height}")
            if caption:
                lines.append(f"- Caption: {caption}")
            return "\n".join(lines)

        if layout in {"wrap-left", "wrap-right"}:
            layout_label = "Wrap-left" if layout == "wrap-left" else "Wrap-right"
            return f"[{alt} ({layout_label})]({src})"

        use_html = any((width, height, align, layout, caption))
        if not use_html:
            return f"![{alt}]({src})"

        img_attrs = [
            f'src="{html.escape(src, quote=True)}"',
            f'alt="{html.escape(alt, quote=True)}"',
        ]
        if width.isdigit():
            img_attrs.append(f'width="{width}"')
        if height.isdigit():
            img_attrs.append(f'height="{height}"')

        wrapper_style_parts: list[str] = []
        if align == "center" or layout == "center":
            wrapper_style_parts.append("text-align: center")
        elif align == "right" or layout in {"align-end", "right"}:
            wrapper_style_parts.append("text-align: right")

        img_tag = f"<img {' '.join(img_attrs)} />"

        if caption:
            figure_style_parts = ["margin: 1rem 0"]
            figure_style_parts.extend(wrapper_style_parts)
            figure_style = f' style="{html.escape("; ".join(figure_style_parts), quote=True)}"' if figure_style_parts else ""
            return (
                f"<figure{figure_style}>\n"
                f"{img_tag}\n"
                f"<figcaption>{caption}</figcaption>\n"
                f"</figure>"
            )

        if wrapper_style_parts:
            wrapper_style = html.escape("; ".join(wrapper_style_parts), quote=True)
            return f'<div style="{wrapper_style}">{img_tag}</div>'

        return img_tag

    def render_inline(self, node: ET.Element) -> str:
        tag = self.tag_name(node)

        if tag == "br":
            return "\n"

        if tag == "a":
            label = self.render_inline_children(node).strip() or node.attrib.get("href", "")
            href = node.attrib.get("href", "").strip()
            if href:
                return f"[{label}]({href})"
            return label

        if tag in {"strong", "b"}:
            value = self.render_inline_children(node).strip()
            return f"**{value}**" if value else ""

        if tag in {"em", "i"}:
            value = self.render_inline_children(node).strip()
            return f"_{value}_" if value else ""

        if tag == "u":
            value = self.render_inline_children(node).strip()
            return f"<u>{value}</u>" if value else ""

        if tag in {"del", "s", "strike"}:
            value = self.render_inline_children(node).strip()
            return f"~~{value}~~" if value else ""

        if tag == "sub":
            value = self.render_inline_children(node).strip()
            return f"<sub>{value}</sub>" if value else ""

        if tag == "sup":
            value = self.render_inline_children(node).strip()
            return f"<sup>{value}</sup>" if value else ""

        if tag == "code":
            value = self.text_content(node).strip()
            return f"`{value}`" if value else ""

        if tag == "span":
            value = self.render_inline_children(node).strip()
            if not value:
                return ""
            if self.is_ai_friendly():
                return value
            style = self.inline_style(node)
            if style:
                return f'<span style="{html.escape(style, quote=True)}">{value}</span>'
            return value

        if tag == "time":
            return node.attrib.get("datetime", "").strip() or self.render_inline_children(node).strip()

        if tag == "ac_structured-macro":
            return self.render_macro_inline(node)

        if tag == "ac_emoticon":
            return (
                node.attrib.get("ac_emoji-fallback", "").strip()
                or node.attrib.get("ac_emoji-shortname", "").strip()
                or node.attrib.get("ac_name", "").strip()
            )

        if tag == "ri_url":
            return node.attrib.get("ri_value", "").strip()

        if tag == "ri_page":
            return node.attrib.get("ri_content-title", "").strip()

        if tag == "ri_attachment":
            return node.attrib.get("ri_filename", "").strip()

        if tag == "ri_user":
            account_id = node.attrib.get("ri_account-id", "").strip()
            if account_id:
                return self.mention_placeholder(account_id)
            return "@user"

        if tag == "ac_plain-text-link-body":
            return self.text_content(node).strip()

        if tag == "ac_link":
            label = ""
            target = ""
            target_is_url = False
            target_is_attachment = False
            for child in list(node):
                child_tag = self.tag_name(child)
                if child_tag == "ac_plain-text-link-body":
                    label = self.text_content(child).strip()
                elif child_tag == "ri_url":
                    target = child.attrib.get("ri_value", "").strip()
                    target_is_url = True
                elif child_tag == "ri_page":
                    target = child.attrib.get("ri_content-title", "").strip()
                elif child_tag == "ri_attachment":
                    target = child.attrib.get("ri_filename", "").strip()
                    target_is_attachment = True
                elif child_tag == "ri_user" and not label:
                    label = self.render_inline(child).strip()
                elif child_tag == "ac_link-body" and not label:
                    label = self.render_inline_children(child).strip()
            label = label or target or "link"
            if target and (target_is_url or target_is_attachment):
                return f"[{label}]({target})"
            return label

        if tag == "ac_image":
            return self.render_image(node)

        return self.render_inline_children(node)

    def render_inline_children(self, node: ET.Element) -> str:
        parts: list[str] = []
        if node.text:
            parts.append(html.unescape(node.text))
        for child in list(node):
            parts.append(self.render_inline(child))
            if child.tail:
                parts.append(html.unescape(child.tail))
        text = "".join(parts)
        text = text.replace("\xa0", " ")
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n[ \t]+", "\n", text)
        text = re.sub(r"[ \t]{2,}", " ", text)
        return text

    def text_alignment(self, node: ET.Element) -> str:
        style = node.attrib.get("style", "")
        match = re.search(r"(?:^|;)\s*text-align\s*:\s*(left|center|right|justify)\s*(?:;|$)", style, re.IGNORECASE)
        return match.group(1).lower() if match else ""

    def render_task_list(self, node: ET.Element, indent: int = 0) -> str:
        lines: list[str] = []
        children = list(node)
        index = 0

        while index < len(children):
            child = children[index]
            child_tag = self.tag_name(child)

            if child_tag != "ac_task":
                if child_tag == "ac_task-list":
                    nested = self.render_task_list(child, indent)
                    if nested:
                        lines.extend(nested.splitlines())
                index += 1
                continue

            status = " "
            body = ""
            for task_child in list(child):
                task_child_tag = self.tag_name(task_child)
                if task_child_tag == "ac_task-status":
                    status_value = norm_ws(self.text_content(task_child)).lower()
                    status = "x" if status_value == "complete" else " "
                elif task_child_tag == "ac_task-body":
                    body = self.render_inline_children(task_child).strip() or norm_ws(self.text_content(task_child))

            marker = f"- [{status}] "
            prefix = " " * indent
            lines.append(prefix + marker + (body or "Task"))

            index += 1
            while index < len(children) and self.tag_name(children[index]) == "ac_task-list":
                nested = self.render_task_list(children[index], indent + LIST_INDENT)
                if nested:
                    lines.extend(nested.splitlines())
                index += 1

        return "\n".join(lines)

    def adf_attribute(self, node: ET.Element, key: str) -> str:
        for child in list(node):
            if self.tag_name(child) == "ac_adf-attribute" and child.attrib.get("key") == key:
                return norm_ws(self.text_content(child))
        return ""

    def find_first_child(self, node: ET.Element, wanted_tag: str) -> ET.Element | None:
        for child in list(node):
            if self.tag_name(child) == wanted_tag:
                return child
        return None

    def render_adf_extension(self, node: ET.Element, indent: int = 0) -> str:
        adf_node = self.find_first_child(node, "ac_adf-node")
        fallback = self.find_first_child(node, "ac_adf-fallback")

        if adf_node is not None:
            node_type = (adf_node.attrib.get("type") or "").strip().lower()

            if node_type == "panel":
                label = self.adf_attribute(adf_node, "panel-type").upper() or "PANEL"
                content_node = self.find_first_child(adf_node, "ac_adf-content")
                content = ""
                if content_node is not None:
                    content = "\n\n".join(self.render_children_blocks(content_node)).strip()
                if content:
                    return render_admonition(label, content, self.profile)

            if node_type == "decision-list":
                items: list[str] = []
                for child in list(adf_node):
                    if self.tag_name(child) != "ac_adf-node":
                        continue
                    if (child.attrib.get("type") or "").strip().lower() != "decision-item":
                        continue
                    content_node = self.find_first_child(child, "ac_adf-content")
                    if content_node is None:
                        continue
                    item_text = self.render_inline_children(content_node).strip() or norm_ws(self.text_content(content_node))
                    if item_text:
                        items.append(item_text)
                if items:
                    return render_decision_block(items, self.profile)

        if fallback is not None:
            return self.render_block(fallback, indent)

        return "\n\n".join(self.render_children_blocks(node))

    def table_to_md(self, node: ET.Element) -> str:
        rows: list[list[str]] = []
        header_flags: list[bool] = []

        for tr in node.iter():
            if self.tag_name(tr) != "tr":
                continue
            row: list[str] = []
            row_has_header = False
            for cell in list(tr):
                cell_tag = self.tag_name(cell)
                if cell_tag not in {"th", "td"}:
                    continue
                cell_text = self.render_inline_children(cell).replace("\n", "<br>")
                cell_text = escape_md(norm_ws(cell_text))
                row.append(cell_text)
                if cell_tag == "th":
                    row_has_header = True
            if row:
                rows.append(row)
                header_flags.append(row_has_header)

        if not rows:
            return ""

        width = max(len(row) for row in rows)
        rows = [row + [""] * (width - len(row)) for row in rows]
        header = rows[0]
        data_rows = rows[1:]

        md_rows = [
            "| " + " | ".join(header) + " |",
            "| " + " | ".join(["---"] * width) + " |",
        ]
        md_rows.extend("| " + " | ".join(row) + " |" for row in data_rows)
        return "\n".join(md_rows)

    def render_macro(self, node: ET.Element) -> str:
        name = (node.attrib.get("ac_name") or "").strip().lower()

        if name in {"code", "noformat"}:
            language = self.macro_parameter(node, "language")
            body = ""
            for child in list(node):
                child_tag = self.tag_name(child)
                if child_tag in {"ac_plain-text-body", "ac_rich-text-body"}:
                    body = self.text_content(child)
                    break
            return fenced_code(body, language)

        if name in {"info", "note", "tip", "warning", "success", "error"}:
            body_blocks: list[str] = []
            for child in list(node):
                if self.tag_name(child) == "ac_rich-text-body":
                    body_blocks = self.render_children_blocks(child)
                    break
            label = self.panel_label_for_macro(node, name)
            content = "\n\n".join(body_blocks).strip() or f"[{label}]"
            return render_admonition(label, content, self.profile)

        if name == "panel":
            body_blocks: list[str] = []
            for child in list(node):
                if self.tag_name(child) == "ac_rich-text-body":
                    body_blocks = self.render_children_blocks(child)
                    break
            content = "\n\n".join(body_blocks).strip()
            if not content:
                return ""
            return render_admonition("PANEL", content, self.profile)

        if name == "expand":
            title = self.macro_parameter(node, "title") or "Details"
            body_blocks: list[str] = []
            for child in list(node):
                if self.tag_name(child) == "ac_rich-text-body":
                    body_blocks = self.render_children_blocks(child)
                    break
            content = "\n\n".join(body_blocks).strip()
            if self.is_ai_friendly():
                heading = f"### Expanded Section: {title}"
                return f"{heading}\n\n{content}" if content else heading
            if content:
                return f"<details>\n<summary>{html.escape(title)}</summary>\n\n{content}\n\n</details>"
            return f"<details>\n<summary>{html.escape(title)}</summary>\n\n</details>"

        if name == "status":
            return self.render_macro_inline(node)

        if name == "attachments":
            return "__WORK2MD_ATTACHMENTS_MACRO__"

        if name == "profile-picture":
            return ""

        body_text = ""
        for child in list(node):
            if self.tag_name(child) == "ac_rich-text-body":
                body_text = "\n\n".join(self.render_children_blocks(child)).strip()
                break
        placeholder = f"[Unsupported macro: {name or 'unknown'}]"
        if body_text:
            return placeholder + "\n\n" + body_text
        return placeholder

    def render_list(self, node: ET.Element, indent: int, ordered: bool) -> str:
        lines: list[str] = []
        index = 1
        for child in list(node):
            if self.tag_name(child) != "li":
                continue
            marker = f"{index}. " if ordered else "- "
            lines.extend(self.render_list_item(child, indent, marker))
            if ordered:
                index += 1
        return "\n".join(lines)

    def render_list_item(self, node: ET.Element, indent: int, marker: str) -> list[str]:
        prefix = " " * indent
        continuation = " " * (indent + LIST_INDENT)

        main_text_parts: list[str] = []
        nested_parts: list[tuple[str, bool]] = []

        if node.text and node.text.strip():
            main_text_parts.append(norm_ws(node.text))

        for child in list(node):
            child_tag = self.tag_name(child)
            if child_tag in {"ul", "ol", "ac_task-list"}:
                rendered = self.render_block(child, indent + LIST_INDENT)
                if rendered:
                    nested_parts.append((rendered, True))
            elif child_tag == "p":
                paragraph = self.render_inline_children(child).strip()
                if paragraph:
                    if not main_text_parts:
                        main_text_parts.append(paragraph)
                    else:
                        nested_parts.append((paragraph, False))
            elif child_tag in {"pre", "blockquote", "table", "ac_structured-macro", "ac_adf-extension"}:
                rendered = self.render_block(child, indent + LIST_INDENT)
                if rendered:
                    nested_parts.append((rendered, False))
            else:
                inline = self.render_inline(child).strip()
                if inline:
                    main_text_parts.append(inline)
            if child.tail and child.tail.strip():
                main_text_parts.append(norm_ws(child.tail))

        main_text = " ".join(part for part in main_text_parts if part).strip() or "-"

        lines = [prefix + marker + main_text]
        for block, already_indented in nested_parts:
            for line in block.splitlines():
                if line:
                    lines.append(line if already_indented else continuation + line)
                else:
                    lines.append("")
        return lines

    def render_layout_cell(self, node: ET.Element, column_index: int) -> str:
        content = "\n\n".join(self.render_children_blocks(node)).strip()
        if self.is_ai_friendly():
            heading = f"### Column {column_index}"
            return f"{heading}\n\n{content}".strip() if content else heading
        lines = [f'<div class="confluence-layout-cell" data-column="{column_index}">']
        if content:
            lines.append(content)
        lines.append("</div>")
        return "\n".join(lines)

    def layout_column_widths(self, layout_type: str, column_count: int) -> list[str]:
        layout_type = (layout_type or "").strip().lower()
        presets = {
            "two_equal": ["1 1 0", "1 1 0"],
            "three_equal": ["1 1 0", "1 1 0", "1 1 0"],
            "four_equal": ["1 1 0", "1 1 0", "1 1 0", "1 1 0"],
            "five_equal": ["1 1 0", "1 1 0", "1 1 0", "1 1 0", "1 1 0"],
            "two_left_sidebar": ["0 0 28%", "1 1 0"],
            "two_right_sidebar": ["1 1 0", "0 0 28%"],
            "three_with_sidebars": ["0 0 22%", "1 1 0", "0 0 22%"],
        }
        widths = presets.get(layout_type)
        if widths and len(widths) == column_count:
            return widths
        return ["1 1 0"] * column_count

    def render_layout_cell_with_style(self, node: ET.Element, column_index: int, flex_value: str) -> str:
        if self.is_ai_friendly():
            return self.render_layout_cell(node, column_index)
        content = "\n\n".join(self.render_children_blocks(node)).strip()
        style = f"flex: {flex_value}; min-width: 0; box-sizing: border-box;"
        lines = [
            f'<div class="confluence-layout-cell" data-column="{column_index}" '
            f'style="{html.escape(style, quote=True)}">'
        ]
        if content:
            lines.append(content)
        lines.append("</div>")
        return "\n".join(lines)

    def render_layout_section(self, node: ET.Element, section_index: int) -> str:
        layout_type = (node.attrib.get("ac_type") or "").strip()
        cell_nodes = [child for child in list(node) if self.tag_name(child) == "ac_layout-cell"]

        if len(cell_nodes) <= 1:
            target = cell_nodes[0] if cell_nodes else node
            return "\n\n".join(self.render_children_blocks(target)).strip()

        if self.is_ai_friendly():
            cells = [
                self.render_layout_cell(child, index)
                for index, child in enumerate(cell_nodes, start=1)
            ]
            heading = f"## Layout Section {section_index}"
            body = "\n\n".join(cell for cell in cells if cell.strip()).strip()
            return f"{heading}\n\n{body}" if body else heading

        attr = f' data-layout="{html.escape(layout_type, quote=True)}"' if layout_type else ""
        flex_values = self.layout_column_widths(layout_type, len(cell_nodes))
        cells = [
            self.render_layout_cell_with_style(child, index, flex_value)
            for index, (child, flex_value) in enumerate(zip(cell_nodes, flex_values), start=1)
        ]

        section_style = "display: flex; gap: 1rem; align-items: flex-start; margin: 1rem 0;"
        lines = [
            f'<div class="confluence-layout-section" data-section="{section_index}"{attr} '
            f'style="{html.escape(section_style, quote=True)}">'
        ]
        lines.extend(cells)
        lines.append("</div>")
        return "\n".join(lines)

    def render_layout(self, node: ET.Element) -> str:
        sections: list[str] = []
        section_index = 1
        for child in list(node):
            if self.tag_name(child) != "ac_layout-section":
                continue
            rendered = self.render_layout_section(child, section_index)
            if rendered:
                sections.append(rendered)
                section_index += 1
        if sections:
            return "\n\n".join(section for section in sections if section.strip()).strip()
        return "\n\n".join(self.render_children_blocks(node)).strip()

    def render_block(self, node: ET.Element, indent: int = 0) -> str:
        tag = self.tag_name(node)

        if tag == "ac_layout":
            return self.render_layout(node)
        if tag == "ac_layout-section":
            return self.render_layout_section(node, 1)
        if tag == "ac_layout-cell":
            return self.render_layout_cell(node, 1)
        if tag in {"div", "ac_adf-fallback", "ac_rich-text-body"}:
            return "\n\n".join(self.render_children_blocks(node))
        if tag == "p":
            text = self.render_inline_children(node).strip()
            if not text:
                return ""
            if self.is_ai_friendly():
                return text
            alignment = self.text_alignment(node)
            if alignment in {"center", "right", "justify"}:
                return f'<div align="{alignment}">{text}</div>'
            return text
        if tag in {"td", "th"}:
            return self.render_inline_children(node).strip()
        if tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            level = int(tag[1])
            text = self.render_inline_children(node).strip()
            return ("#" * level) + " " + text if text else ""
        if tag == "blockquote":
            content = "\n\n".join(self.render_children_blocks(node)).strip() or self.render_inline_children(node).strip()
            return blockquote(content)
        if tag == "pre":
            language = ""
            code = self.text_content(node)
            for child in list(node):
                if self.tag_name(child) == "code":
                    code = self.text_content(child)
                    break
            return fenced_code(code, language)
        if tag == "ul":
            return self.render_list(node, indent, False)
        if tag == "ol":
            return self.render_list(node, indent, True)
        if tag == "table":
            return self.table_to_md(node)
        if tag == "hr":
            return "---"
        if tag == "ac_task-list":
            return self.render_task_list(node, indent)
        if tag == "ac_structured-macro":
            return self.render_macro(node)
        if tag == "ac_adf-extension":
            return self.render_adf_extension(node, indent)
        if tag == "li":
            return "\n".join(self.render_list_item(node, indent, "- "))
        if list(node):
            return "\n\n".join(self.render_children_blocks(node))
        return self.render_inline_children(node).strip()

    def render_children_blocks(self, node: ET.Element) -> list[str]:
        blocks: list[str] = []
        inline_buffer: list[str] = []

        if node.text and node.text.strip():
            inline_buffer.append(norm_ws(node.text))

        for child in list(node):
            child_tag = self.tag_name(child)
            if child_tag in self.BLOCK_TAGS or child_tag == "ac_structured-macro":
                if inline_buffer:
                    paragraph = " ".join(part for part in inline_buffer if part).strip()
                    if paragraph:
                        blocks.append(paragraph)
                    inline_buffer = []
                rendered = self.render_block(child)
                if rendered.strip():
                    blocks.append(rendered.strip())
            else:
                inline_value = self.render_inline(child)
                if inline_value.strip():
                    inline_buffer.append(inline_value.strip())
            if child.tail and child.tail.strip():
                inline_buffer.append(norm_ws(child.tail))

        if inline_buffer:
            paragraph = " ".join(part for part in inline_buffer if part).strip()
            if paragraph:
                blocks.append(paragraph)

        return blocks


class JiraADFRenderer:
    def __init__(self, profile: str = "default") -> None:
        self.profile = profile

    def is_ai_friendly(self) -> bool:
        return self.profile == "ai-friendly"

    def render(self, raw: str) -> str:
        if not raw.strip() or raw.strip() == "null":
            return ""
        doc = json.loads(raw)
        output = self.render_block(doc, 0).strip()
        return re.sub(r"\n{3,}", "\n\n", output)

    def apply_marks(self, text: str, marks: list[dict] | None) -> str:
        rendered = text
        for mark in marks or []:
            mark_type = mark.get("type", "")
            attrs = mark.get("attrs") or {}
            if mark_type == "strong":
                rendered = f"**{rendered}**"
            elif mark_type == "em":
                rendered = f"_{rendered}_"
            elif mark_type == "code":
                rendered = f"`{rendered}`"
            elif mark_type == "link":
                href = attrs.get("href", "")
                if href:
                    rendered = f"[{rendered}]({href})"
            elif mark_type == "underline":
                rendered = f"<u>{rendered}</u>"
            elif mark_type == "strike":
                rendered = f"~~{rendered}~~"
            elif mark_type == "subsup":
                kind = attrs.get("type", "")
                if kind == "sub":
                    rendered = f"<sub>{rendered}</sub>"
                elif kind == "sup":
                    rendered = f"<sup>{rendered}</sup>"
            elif mark_type == "textColor":
                color = attrs.get("color", "")
                if color and not self.is_ai_friendly():
                    rendered = f'<span style="color: {html.escape(color, quote=True)}">{rendered}</span>'
        return rendered

    def render_inline(self, node: dict | None) -> str:
        if not isinstance(node, dict):
            return ""

        node_type = node.get("type", "")
        attrs = node.get("attrs") or {}
        content = node.get("content") or []

        if node_type == "text":
            return self.apply_marks(node.get("text", ""), node.get("marks"))
        if node_type == "hardBreak":
            return "\n"
        if node_type == "mention":
            mention_text = attrs.get("text", "@mentioned-user")
            if self.is_ai_friendly():
                return mention_text.lstrip("@") or mention_text
            return mention_text
        if node_type == "emoji":
            return attrs.get("text", "") or attrs.get("shortName", "")
        if node_type == "status":
            return f"[{attrs.get('text', 'status')}]"
        if node_type == "date":
            timestamp = attrs.get("timestamp")
            try:
                return datetime.fromtimestamp(int(timestamp) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            except (TypeError, ValueError, OSError):
                return ""
        if node_type == "inlineCard":
            url = attrs.get("url", "")
            return f"[{url}]({url})" if url else ""
        if node_type == "inlineExtension":
            if attrs.get("extensionKey") == "profile-picture":
                return ""
            return ""
        if node_type == "media":
            return self.render_media(node)
        if node_type == "image":
            url = ((node.get("data") or {}).get("url") or "").strip()
            if not url:
                return ""
            label = attrs.get("alt") or url
            return f"[{label}]({url})"

        return "".join(self.render_inline(child) for child in content)

    def render_media(self, node: dict, layout: str = "") -> str:
        attrs = node.get("attrs") or {}
        media_id = attrs.get("id", "")
        alt = attrs.get("alt", "").strip() or attrs.get("fileName", "").strip()
        label = alt or f"media:{media_id}"
        destination = f"media:{media_id}" if media_id else ""
        if layout in {"wrap-left", "wrap-right"}:
            layout_label = "Wrap-left" if layout == "wrap-left" else "Wrap-right"
            label = f"{label} ({layout_label})"
        if destination:
            return f"[{label}](<{destination}>)"
        return label

    def render_inline_children(self, node: dict | None) -> str:
        if not isinstance(node, dict):
            return ""
        text = "".join(self.render_inline(child) for child in (node.get("content") or []))
        text = text.replace("\xa0", " ")
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n[ \t]+", "\n", text)
        text = re.sub(r"[ \t]{2,}", " ", text)
        return text

    def paragraph_alignment(self, node: dict) -> str:
        attrs = node.get("attrs") or {}
        return (attrs.get("textAlign") or attrs.get("layout") or "").strip().lower()

    def render_task_list(self, node: dict, indent: int = 0) -> str:
        lines: list[str] = []
        children = node.get("content") or []
        index = 0

        while index < len(children):
            child = children[index]
            child_type = child.get("type", "")

            if child_type != "taskItem":
                if child_type == "taskList":
                    nested = self.render_task_list(child, indent)
                    if nested:
                        lines.extend(nested.splitlines())
                index += 1
                continue

            state = ((child.get("attrs") or {}).get("state") or "").upper()
            status = "x" if state == "DONE" else " "
            body = self.render_inline_children(child).strip() or "Task"
            lines.append((" " * indent) + f"- [{status}] {body}")

            index += 1
            while index < len(children) and (children[index].get("type") == "taskList"):
                nested = self.render_task_list(children[index], indent + LIST_INDENT)
                if nested:
                    lines.extend(nested.splitlines())
                index += 1

        return "\n".join(lines)

    def render_table(self, node: dict) -> str:
        rows: list[list[str]] = []
        for row_node in node.get("content") or []:
            if row_node.get("type") != "tableRow":
                continue
            row: list[str] = []
            for cell in row_node.get("content") or []:
                if cell.get("type") not in {"tableHeader", "tableCell"}:
                    continue
                cell_lines: list[str] = []
                for block in cell.get("content") or []:
                    rendered = self.render_block(block, 0).strip()
                    if rendered:
                        cell_lines.append(rendered)
                row.append(escape_md("<br>".join(cell_lines)))
            if row:
                rows.append(row)

        if not rows:
            return ""

        width = max(len(row) for row in rows)
        rows = [row + [""] * (width - len(row)) for row in rows]
        header = rows[0]
        data_rows = rows[1:]

        md_rows = [
            "| " + " | ".join(header) + " |",
            "| " + " | ".join(["---"] * width) + " |",
        ]
        md_rows.extend("| " + " | ".join(row) + " |" for row in data_rows)
        return "\n".join(md_rows)

    def render_media_single(self, node: dict) -> str:
        attrs = node.get("attrs") or {}
        layout = (attrs.get("layout") or "").strip().lower()
        items = [child for child in (node.get("content") or []) if isinstance(child, dict) and child.get("type") == "media"]
        if not items:
            return ""
        return self.render_media(items[0], layout=layout)

    def render_media_group(self, node: dict) -> str:
        items = []
        for child in node.get("content") or []:
            if isinstance(child, dict) and child.get("type") == "media":
                rendered = self.render_media(child)
                if rendered:
                    items.append(rendered)
        return "\n".join(items)

    def render_list(self, node: dict, indent: int, ordered: bool) -> str:
        lines: list[str] = []
        index = 1
        for child in node.get("content") or []:
            if child.get("type") != "listItem":
                continue
            marker = f"{index}. " if ordered else "- "
            lines.extend(self.render_list_item(child, indent, marker))
            if ordered:
                index += 1
        return "\n".join(lines)

    def render_list_item(self, node: dict, indent: int, marker: str) -> list[str]:
        prefix = " " * indent
        continuation = " " * (indent + LIST_INDENT)

        main_text = ""
        nested_parts: list[tuple[str, bool]] = []

        for child in node.get("content") or []:
            child_type = child.get("type", "")
            if child_type in {"bulletList", "orderedList", "taskList"}:
                rendered = self.render_block(child, indent + LIST_INDENT)
                if rendered:
                    nested_parts.append((rendered, True))
            elif child_type == "paragraph":
                paragraph = self.render_inline_children(child).strip()
                if paragraph:
                    if not main_text:
                        main_text = paragraph
                    else:
                        nested_parts.append((paragraph, False))
            else:
                rendered = self.render_block(child, indent + LIST_INDENT)
                if rendered:
                    nested_parts.append((rendered, False))

        main_text = main_text or "-"
        lines = [prefix + marker + main_text]
        for block, already_indented in nested_parts:
            for line in block.splitlines():
                if line:
                    lines.append(line if already_indented else continuation + line)
                else:
                    lines.append("")
        return lines

    def render_decision_list(self, node: dict) -> str:
        items: list[str] = []
        for child in node.get("content") or []:
            if child.get("type") != "decisionItem":
                continue
            text = self.render_inline_children(child).strip()
            if text:
                items.append(text)
        return render_decision_block(items, self.profile)

    def render_block(self, node: dict | None, indent: int = 0) -> str:
        if not isinstance(node, dict):
            return ""

        node_type = node.get("type", "")
        content = node.get("content") or []
        attrs = node.get("attrs") or {}

        if node_type == "doc":
            parts = [self.render_block(child, indent).strip() for child in content]
            return "\n\n".join(part for part in parts if part)
        if node_type == "heading":
            level = max(1, min(6, int(attrs.get("level", 1))))
            text = self.render_inline_children(node).strip()
            return ("#" * level) + " " + text if text else ""
        if node_type == "paragraph":
            text = self.render_inline_children(node).strip()
            if not text:
                return ""
            if self.is_ai_friendly():
                return text
            alignment = self.paragraph_alignment(node)
            if alignment in {"center", "right", "justify"}:
                return f'<div align="{alignment}">{text}</div>'
            return text
        if node_type == "blockquote":
            rendered = "\n\n".join(self.render_block(child, 0).strip() for child in content if self.render_block(child, 0).strip())
            return blockquote(rendered)
        if node_type == "codeBlock":
            language = (attrs.get("language") or "").strip()
            text = self.render_inline_children(node)
            return fenced_code(text, language)
        if node_type == "bulletList":
            return self.render_list(node, indent, False)
        if node_type == "orderedList":
            return self.render_list(node, indent, True)
        if node_type == "taskList":
            return self.render_task_list(node, indent)
        if node_type == "panel":
            label = (attrs.get("panelType") or "panel").upper()
            body = "\n\n".join(self.render_block(child, 0).strip() for child in content if self.render_block(child, 0).strip())
            return render_admonition(label, body, self.profile)
        if node_type == "rule":
            return "---"
        if node_type == "expand":
            title = attrs.get("title") or "Details"
            body = "\n\n".join(self.render_block(child, 0).strip() for child in content if self.render_block(child, 0).strip())
            if self.is_ai_friendly():
                heading = f"### Expanded Section: {title}"
                return f"{heading}\n\n{body}" if body else heading
            if body:
                return f"<details>\n<summary>{html.escape(title)}</summary>\n\n{body}\n\n</details>"
            return f"<details>\n<summary>{html.escape(title)}</summary>\n\n</details>"
        if node_type == "decisionList":
            return self.render_decision_list(node)
        if node_type == "table":
            return self.render_table(node)
        if node_type == "mediaSingle":
            return self.render_media_single(node)
        if node_type == "mediaGroup":
            return self.render_media_group(node)
        if node_type == "blockCard":
            url = attrs.get("url", "")
            return f"[{url}]({url})" if url else ""
        if node_type in {"inlineCard", "status", "date"}:
            return self.render_inline(node)

        if content:
            parts = [self.render_block(child, indent).strip() for child in content]
            return "\n\n".join(part for part in parts if part)

        return self.render_inline(node)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", required=True, choices=["confluence-storage", "jira-adf"])
    parser.add_argument("--confluence-panel-map")
    parser.add_argument("--profile", choices=["default", "ai-friendly"], default="default")
    args = parser.parse_args()

    raw = sys.stdin.read()
    if args.format == "confluence-storage":
        panel_map = {}
        if args.confluence_panel_map:
            with open(args.confluence_panel_map, "r", encoding="utf-8") as fh:
                panel_map = json.load(fh)
        output = ConfluenceStorageRenderer(panel_map=panel_map, profile=args.profile).render(raw)
    else:
        output = JiraADFRenderer(profile=args.profile).render(raw)

    if output:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
