#!/usr/bin/env python3
"""Route downloaded books after they land in inbox/.

Default mode is a dry run. Use --apply after reviewing the proposed actions.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html as htmlmod
import json
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath


DEFAULT_INBOX = Path.home() / "repos" / "research-orchestrator" / "inbox"
DEFAULT_WIKI = Path.home() / "Library/Mobile Documents/iCloud~md~obsidian/Documents/wiki"
DEFAULT_TOKEN_FILE = Path.home() / ".config/readwise/api-token"
BOOK_EXTS = {".epub", ".pdf", ".mobi", ".azw3"}

SEMINARY_RULES = [
    (r"\b(new testament|paul|revelation)\b", "50_faith/seminary/newts-3323/assets/books"),
    (r"\b(mission|missionary|rainforest)\b", "50_faith/seminary/miss-3363/assets/books"),
    (r"\b(evangelism|gospel conversation|tell it often)\b", "50_faith/seminary/evang-3033/assets/books"),
    (r"\b(theology|problem of pain|suffering)\b", "50_faith/seminary/SYSTH-3013/assets/books"),
    (r"\b(calvin|institutes|reformation)\b", "50_faith/seminary/chaht-4333/assets/books"),
    (r"\b(psalms?|word biblical commentary)\b", "50_faith/seminary/BIBST-3203/assets/books"),
    (r"\b(praying|spurgeon|life together|ministry|bonhoeffer)\b", "50_faith/seminary/edmin3033/assets/books"),
    (r"\b(robert'?s rules|bylaws|governance)\b", "50_faith/seminary/swbts-3503/assets/books"),
]

QUARANTINE_RULES = [
    r"\bESP\b",
    r"\btime for a turning point\b",
    r"\blangchain\b",
]

TAG_RULES = [
    (r"100명|한글|한국어", ["korean", "language"]),
    (r"privacy", ["privacy", "reference"]),
    (r"comedy|stand.?up|funny|banter|witty|comic", ["comedy", "writing"]),
    (r"adhd|anxiety|mindfulness|recovery|well.?being|functioning|gratitude", ["health"]),
    (r"algorithm|architecture|distributed|latency|system design|programmers|software|machine learning|solutions architect", ["tech"]),
    (r"co-intelligence|ai|vibe|life 3", ["ai"]),
    (r"faith|theology|pain|lewis|spurgeon|bonhoeffer", ["faith"]),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Dry-run or apply routing for downloaded books in inbox/."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="Move files and upload to Readwise.")
    mode.add_argument("--review", action="store_true", help="Interactively approve proposed actions.")
    parser.add_argument("--inbox", type=Path, default=DEFAULT_INBOX)
    parser.add_argument("--file", type=Path, action="append", help="Process only this staged inbox file. Can be repeated.")
    parser.add_argument("--wiki", type=Path, default=DEFAULT_WIKI)
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE)
    parser.add_argument("--no-upload", action="store_true", help="Do not upload non-course books to Readwise.")
    parser.add_argument("--sleep", type=float, default=2.0, help="Seconds between Readwise uploads.")
    return parser.parse_args()


def review_root(inbox: Path) -> Path | None:
    """Use the current inbox format directory as review scope when applicable."""
    cwd = Path.cwd().resolve()
    inbox = inbox.resolve()
    if cwd.parent == inbox and cwd.name in {"epub", "pdf", "mobi", "azw3"}:
        return cwd
    return None


def iter_books(inbox: Path, selected: list[Path] | None = None, root: Path | None = None) -> list[Path]:
    if selected:
        return sorted(
            [path for path in selected if path.exists() and path.is_file() and path.suffix.lower() in BOOK_EXTS],
            key=lambda p: p.name.casefold(),
        )

    if root:
        return sorted(
            [path for path in root.iterdir() if path.is_file() and path.suffix.lower() in BOOK_EXTS],
            key=lambda p: p.name.casefold(),
        )

    files: list[Path] = []
    for folder in ("epub", "pdf", "mobi", "azw3"):
        root = inbox / folder
        if root.exists():
            files.extend(path for path in root.iterdir() if path.is_file() and path.suffix.lower() in BOOK_EXTS)
    return sorted(files, key=lambda p: p.name.casefold())


def parse_filename(path: Path) -> tuple[str, str]:
    stem = path.stem
    if " -- " in stem:
        title, author = stem.split(" -- ", 1)
        return title.strip(), author.strip()
    return stem.strip(), ""


def unique_dest(dest_dir: Path, filename: str) -> Path:
    dest = dest_dir / filename
    if not dest.exists():
        return dest
    stem = dest.stem
    suffix = dest.suffix
    counter = 1
    while True:
        candidate = dest_dir / f"{stem}_{counter}{suffix}"
        if not candidate.exists():
            return candidate
        counter += 1


def match_rule(name: str, rules: list[tuple[str, str]]) -> str | None:
    for pattern, dest in rules:
        if re.search(pattern, name, flags=re.IGNORECASE):
            return dest
    return None


def should_quarantine(name: str) -> bool:
    return any(re.search(pattern, name, flags=re.IGNORECASE) for pattern in QUARANTINE_RULES)


def tags_for(name: str) -> list[str]:
    tags = {"books-inbox", "local-import"}
    for pattern, values in TAG_RULES:
        if re.search(pattern, name, flags=re.IGNORECASE):
            tags.update(values)
    return sorted(tags)


def epub_html(path: Path) -> tuple[str, str, str, str, str]:
    fallback_title, fallback_author = parse_filename(path)
    with zipfile.ZipFile(path) as archive:
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        ns = {"c": "urn:oasis:names:tc:opendocument:xmlns:container"}
        rootfile = container.find(".//c:rootfile", ns).attrib["full-path"]
        opf_dir = str(PurePosixPath(rootfile).parent)
        if opf_dir == ".":
            opf_dir = ""
        opf = ET.fromstring(archive.read(rootfile))
        title, author = fallback_title, fallback_author
        for elem in opf.iter():
            tag = elem.tag.rsplit("}", 1)[-1].lower()
            text = "".join(elem.itertext()).strip()
            if tag == "title" and text and title == fallback_title:
                title = htmlmod.unescape(text)
            elif tag == "creator" and text and author == fallback_author:
                author = htmlmod.unescape(text)

        manifest: dict[str, tuple[str, str]] = {}
        spine: list[str] = []
        for elem in opf.iter():
            tag = elem.tag.rsplit("}", 1)[-1].lower()
            if tag == "item":
                item_id = elem.attrib.get("id")
                href = elem.attrib.get("href")
                media_type = elem.attrib.get("media-type", "")
                if item_id and href:
                    manifest[item_id] = (href, media_type)
            elif tag == "itemref":
                ref = elem.attrib.get("idref")
                if ref:
                    spine.append(ref)

        parts: list[str] = []
        for ref in spine:
            if ref not in manifest:
                continue
            href, media_type = manifest[ref]
            if "html" not in media_type and not href.lower().endswith((".html", ".xhtml", ".htm")):
                continue
            full_path = str(PurePosixPath(opf_dir) / href) if opf_dir else href
            try:
                raw = archive.read(full_path).decode("utf-8", errors="replace")
            except KeyError:
                continue
            match = re.search(r"<body[^>]*>(.*?)</body>", raw, flags=re.I | re.S)
            body = match.group(1) if match else raw
            body = re.sub(r"<script[\s\S]*?</script>", "", body, flags=re.I)
            body = re.sub(r"<style[\s\S]*?</style>", "", body, flags=re.I)
            parts.append(body)

    body = "\n<hr/>\n".join(parts)
    if not body.strip():
        raise RuntimeError("no EPUB HTML body extracted")
    document = (
        f'<html><head><meta charset="utf-8"><title>{htmlmod.escape(title)}</title></head>'
        f"<body><h1>{htmlmod.escape(title)}</h1><p><em>{htmlmod.escape(author)}</em></p>{body}</body></html>"
    )
    return title, author, document, "html", "epub"


def pdf_markdown(path: Path) -> tuple[str, str, str, str, str]:
    title, author = parse_filename(path)
    result = subprocess.run(
        ["pdftotext", "-layout", str(path), "-"],
        text=True,
        capture_output=True,
        timeout=180,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "pdftotext failed")
    text = result.stdout.strip()
    if not text:
        raise RuntimeError("empty PDF text")
    if len(text) > 1_500_000:
        text = f"{text[:1_500_000]}\n\n[Truncated during local import.]"
    markdown = f"# {title}\n\n*{author}*\n\n```text\n{text}\n```\n"
    return title, author, markdown, "markdown", "pdf"


def save_to_readwise(path: Path, token: str, tags: list[str]) -> dict:
    if path.suffix.lower() == ".epub":
        title, author, content, content_kind, category = epub_html(path)
    elif path.suffix.lower() == ".pdf":
        title, author, content, content_kind, category = pdf_markdown(path)
    else:
        raise RuntimeError(f"upload not supported for {path.suffix}")

    digest = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
    safe_name = urllib.parse.quote(path.name)
    payload = {
        "url": f"https://local.research-orchestrator.invalid/{category}/{digest}/{safe_name}",
        "title": title,
        "author": author,
        "category": category,
        "tags": tags,
        "notes": f"Imported from local inbox path: {path}",
        content_kind: content,
    }
    request = urllib.request.Request(
        "https://readwise.io/api/v3/save/",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Token {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=240) as response:
            return {
                "status": response.status,
                "title": title,
                "author": author,
                "category": category,
                "response": json.loads(response.read().decode("utf-8")),
            }
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")[:1000]
        return {"status": error.code, "title": title, "author": author, "category": category, "error": body}


def plan_for(path: Path, wiki: Path) -> dict:
    seminary_dest = match_rule(path.name, SEMINARY_RULES)
    if seminary_dest:
        dest_dir = wiki / seminary_dest
        return {
            "file": str(path),
            "action": "move-to-course",
            "destination": str(unique_dest(dest_dir, path.name)),
            "reason": seminary_dest,
        }
    if should_quarantine(path.name):
        dest_dir = path.parents[1] / "quarantine" / f"{dt.date.today().isoformat()}-low-value-or-duplicates"
        return {
            "file": str(path),
            "action": "quarantine",
            "destination": str(unique_dest(dest_dir, path.name)),
            "reason": "low-value-or-duplicate rule",
        }
    return {
        "file": str(path),
        "action": "upload-to-readwise",
        "destination": str(path.parents[1] / "uploaded-to-readwise" / dt.date.today().isoformat() / path.name),
        "tags": tags_for(path.name),
    }


def move_file(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dest))


def apply_actions(actions: list[dict], args: argparse.Namespace) -> list[dict]:
    token = ""
    if not args.no_upload and any(action["action"] == "upload-to-readwise" for action in actions):
        token = args.token_file.read_text().strip()

    results: list[dict] = []
    for action in actions:
        action = dict(action)
        src = Path(action["file"])
        dest = Path(action["destination"])
        try:
            if not src.exists():
                action["result"] = "missing-left-unapplied"
                results.append(action)
                continue
            if action["action"] in {"move-to-course", "quarantine"}:
                move_file(src, dest)
                action["result"] = "moved"
            elif action["action"] == "upload-to-readwise":
                if args.no_upload:
                    action["result"] = "skipped-upload"
                else:
                    upload = save_to_readwise(src, token, action["tags"])
                    action["readwise"] = upload
                    if 200 <= int(upload["status"]) < 300:
                        move_file(src, dest)
                        action["result"] = "uploaded-and-moved"
                    else:
                        action["result"] = "upload-failed-left-in-inbox"
                    time.sleep(args.sleep)
            results.append(action)
        except Exception as error:
            action["result"] = "error-left-in-inbox"
            action["error"] = str(error)
            results.append(action)

    return results


def action_label(action: dict) -> str:
    src = Path(action["file"])
    verb = action["action"]
    dest = action.get("destination", "")
    if verb == "move-to-course":
        return f"move to course: {src.name} -> {Path(dest).parent.name}"
    if verb == "quarantine":
        return f"quarantine: {src.name}"
    if verb == "upload-to-readwise":
        tags = ", ".join(action.get("tags", []))
        return f"upload to Readwise: {src.name} [{tags}]"
    return f"{verb}: {src.name}"


def print_review(actions: list[dict], scope: str) -> None:
    print(f"Book inbox review: {len(actions)} proposed action(s) in {scope}")
    for index, action in enumerate(actions, start=1):
        print(f"{index:>2}. {action_label(action)}")
        reason = action.get("reason")
        if reason:
            print(f"    reason: {reason}")
        destination = action.get("destination")
        if destination:
            print(f"    destination: {destination}")


def selected_indexes(raw: str, count: int) -> list[int]:
    selected: set[int] = set()
    for part in raw.replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            start_raw, end_raw = part.split("-", 1)
            start = int(start_raw)
            end = int(end_raw)
            if start > end:
                start, end = end, start
            selected.update(range(start, end + 1))
        else:
            selected.add(int(part))
    invalid = sorted(index for index in selected if index < 1 or index > count)
    if invalid:
        raise ValueError(f"out of range: {', '.join(str(index) for index in invalid)}")
    return sorted(selected)


def print_result_summary(results: list[dict], skipped: int = 0) -> None:
    counts: dict[str, int] = {}
    for result in results:
        key = result.get("result", "unknown")
        counts[key] = counts.get(key, 0) + 1
    if skipped:
        counts["skipped"] = skipped
    if not counts:
        print("No actions applied.")
        return
    summary = ", ".join(f"{key}: {value}" for key, value in sorted(counts.items()))
    print(f"Summary: {summary}")


def review_actions(actions: list[dict], args: argparse.Namespace, scope: str) -> None:
    if not actions:
        print(f"Book inbox review: no supported books found in {scope}.")
        return

    while True:
        print_review(actions, scope)
        choice = input("[a]pprove all, [s]elect, [o]ne by one, [r]efresh, [c]ancel: ").strip().lower()
        if choice in {"c", "cancel", "q", "quit", ""}:
            print("Cancelled. No actions applied.")
            return
        if choice in {"r", "refresh"}:
            root = review_root(args.inbox) if not args.file else None
            actions = [plan_for(path, args.wiki) for path in iter_books(args.inbox, args.file, root)]
            if not actions:
                print(f"Book inbox review: no supported books found in {scope}.")
                return
            continue
        if choice in {"a", "all", "approve"}:
            results = apply_actions(actions, args)
            print_result_summary(results)
            print(json.dumps({"mode": "review", "count": len(results), "actions": results}, indent=2, ensure_ascii=False))
            return
        if choice in {"s", "select", "selected"}:
            raw = input("Apply which numbers/ranges? ").strip()
            try:
                indexes = selected_indexes(raw, len(actions))
            except ValueError as error:
                print(f"Invalid selection: {error}")
                continue
            picked = [actions[index - 1] for index in indexes]
            results = apply_actions(picked, args)
            print_result_summary(results, skipped=len(actions) - len(picked))
            print(json.dumps({"mode": "review", "count": len(results), "actions": results}, indent=2, ensure_ascii=False))
            return
        if choice in {"o", "one", "one-by-one", "one by one"}:
            picked = []
            for action in actions:
                while True:
                    answer = input(f"Apply {action_label(action)}? [y]es/[s]kip/[c]ancel: ").strip().lower()
                    if answer in {"y", "yes"}:
                        picked.append(action)
                        break
                    if answer in {"s", "skip", "n", "no", ""}:
                        break
                    if answer in {"c", "cancel", "q", "quit"}:
                        print("Cancelled before applying. No actions applied.")
                        return
                    print("Choose yes, skip, or cancel.")
            results = apply_actions(picked, args)
            print_result_summary(results, skipped=len(actions) - len(picked))
            print(json.dumps({"mode": "review", "count": len(results), "actions": results}, indent=2, ensure_ascii=False))
            return
        print("Choose approve all, select, one by one, refresh, or cancel.")


def main() -> None:
    args = parse_args()
    root = review_root(args.inbox) if args.review and not args.file else None
    books = iter_books(args.inbox, args.file, root)
    actions = [plan_for(path, args.wiki) for path in books]
    scope = str(root or args.inbox)

    if args.review:
        review_actions(actions, args, scope)
        return

    if not args.apply:
        print(json.dumps({"mode": "dry-run", "count": len(actions), "actions": actions}, indent=2, ensure_ascii=False))
        return

    results = apply_actions(actions, args)
    print(json.dumps({"mode": "apply", "count": len(results), "actions": results}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
