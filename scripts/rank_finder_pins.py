#!/usr/bin/env python3
"""Deterministic ranker for Finder sidebar pins managed via mysides.

Combines:
1. Top N most recent registered wiki projects from 99_meta/.project_registry
   (always including the currently focused Active_Inbox project if set).
2. Top M recently created workspace directories (by st_birthtime within lookback days).
3. Top K frequently visited directories from zoxide + Finder FXRecentFolders,
   with a deterministic boost for directories matching ChatGPT Projects in
   99_meta/conversations/pinned/chat-shortcut-routes.json.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote, urlparse


DEFAULT_WIKI_PATH = Path.home() / "wiki"
DEFAULT_PROJECT_SLOTS = 3
DEFAULT_CREATED_SLOTS = 3
DEFAULT_CREATED_DAYS = 14.0
DEFAULT_FREQUENT_SLOTS = 6

DENY_EXACT_NAMES = {
    ".git",
    ".github",
    ".obsidian",
    ".beads",
    ".venv",
    "venv",
    "node_modules",
    "build",
    "dist",
    "target",
    "__pycache__",
    "tmp",
    "temp",
    "logs",
    "output",
    "outputs",
}


@dataclass
class WikiProject:
    project_id: int
    raw_id: str
    name: str
    path: Path
    birthtime: float = 0.0
    mtime: float = 0.0
    is_focused: bool = False
    zoxide_score: float = 0.0
    finder_rank: int | None = None
    chatgpt_match: bool = False

    @property
    def label(self) -> str:
        display = re.sub(r"_+", " ", self.name)
        return f"[{self.raw_id}] {display}"


@dataclass
class CandidateDir:
    path: Path
    birthtime: float = 0.0
    mtime: float = 0.0
    zoxide_score: float = 0.0
    finder_rank: int | None = None
    chatgpt_match: bool = False
    in_canonical_root: bool = False
    sources: set[str] = field(default_factory=set)

    @property
    def frequent_score(self) -> float:
        z_part = math.log10(1.0 + max(0.0, self.zoxide_score))
        f_part = (
            1.5 * max(0.0, 1.0 - (self.finder_rank / 10.0))
            if self.finder_rank is not None and self.finder_rank < 10
            else 0.0
        )
        c_part = 0.75 if self.chatgpt_match else 0.0
        return round(z_part + f_part + c_part, 3)


def normalize_key(value: str) -> str:
    text = unicodedata.normalize("NFKC", value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "_", text)
    return re.sub(r"_+", "_", text).strip("_")


def safe_resolve(path: Path) -> Path:
    try:
        return path.resolve()
    except OSError:
        return path.expanduser()


def parse_file_url(url_or_path: str) -> Path | None:
    raw = url_or_path.strip()
    if not raw:
        return None
    if raw.startswith("file://"):
        parsed = urlparse(raw)
        decoded = unquote(parsed.path)
        if not decoded:
            return None
        return Path(decoded)
    return Path(raw)


def load_manual_sidebar_paths(
    sidebar_lines: list[str], owned_labels: set[str]
) -> set[Path]:
    """Return resolved paths that are already pinned in Finder outside managed pins."""
    manual_paths: set[Path] = set()
    for line in sidebar_lines:
        if " -> " not in line:
            continue
        label, target = line.split(" -> ", 1)
        label = label.strip()
        if label in owned_labels:
            continue
        parsed = parse_file_url(target)
        if parsed is not None:
            manual_paths.add(safe_resolve(parsed))
            manual_paths.add(parsed)
    return manual_paths


def load_owned_labels(pin_state_path: Path, registry_projects: list[WikiProject]) -> set[str]:
    owned: set[str] = {proj.label for proj in registry_projects}
    if pin_state_path.is_file():
        try:
            for line in pin_state_path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                label = line.split("\t", 1)[0].strip()
                if label:
                    owned.add(label)
        except OSError:
            pass
    return owned


def load_chatgpt_project_keys(routes_paths: list[Path]) -> set[str]:
    keys: set[str] = set()
    for path in routes_paths:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        lookup = data.get("project_lookup")
        if isinstance(lookup, dict):
            for k, v in lookup.items():
                if isinstance(k, str) and k.strip():
                    keys.add(normalize_key(k))
                if isinstance(v, dict) and isinstance(v.get("name"), str):
                    keys.add(normalize_key(v["name"]))
        projects = data.get("projects")
        if isinstance(projects, list):
            for item in projects:
                if isinstance(item, dict) and isinstance(item.get("name"), str):
                    keys.add(normalize_key(item["name"]))
    keys.discard("")
    return keys


def stat_times(path: Path) -> tuple[float, float]:
    try:
        st = path.stat()
        birth = getattr(st, "st_birthtime", st.st_mtime)
        return float(birth), float(st.st_mtime)
    except OSError:
        return 0.0, 0.0


def load_registry_projects(
    registry_path: Path, active_inbox_path: Path
) -> list[WikiProject]:
    if not registry_path.is_file():
        raise RuntimeError(f"Failed to read project registry: {registry_path}")

    focused_inbox: Path | None = None
    if active_inbox_path.is_symlink():
        try:
            focused_inbox = safe_resolve(Path(os.readlink(active_inbox_path)))
        except OSError:
            focused_inbox = None

    projects: list[WikiProject] = []
    seen_ids: set[str] = set()
    for line in registry_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        raw_id, name, raw_path = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not raw_id or not name or not raw_path or raw_id in seen_ids:
            continue
        seen_ids.add(raw_id)
        try:
            numeric_id = int(raw_id)
        except ValueError:
            numeric_id = -1
        proj_path = Path(raw_path)
        birth, mtime = stat_times(proj_path) if proj_path.is_dir() else (0.0, 0.0)
        is_focused = False
        if focused_inbox is not None and proj_path.is_dir():
            is_focused = safe_resolve(proj_path / "inbox") == focused_inbox
        projects.append(
            WikiProject(
                project_id=numeric_id,
                raw_id=raw_id,
                name=name,
                path=proj_path,
                birthtime=birth,
                mtime=mtime,
                is_focused=is_focused,
            )
        )
    return projects


def discover_default_roots(home: Path) -> list[Path]:
    roots: list[Path] = []
    repo_roots_script = home / "repos" / "repo-roots.sh"
    if repo_roots_script.is_file():
        try:
            proc = subprocess.run(
                ["bash", str(repo_roots_script)],
                capture_output=True,
                text=True,
                check=False,
                timeout=3,
            )
            if proc.returncode == 0:
                for line in proc.stdout.splitlines():
                    parts = line.split("\t")
                    if len(parts) >= 2 and parts[1].strip():
                        roots.append(Path(parts[1].strip()))
        except (OSError, subprocess.SubprocessError):
            pass

    for fallback in ("repos", "chrome", "obsidian", "github", "apps"):
        candidate = home / fallback
        if candidate not in roots:
            roots.append(candidate)
    return [r for r in roots if r.is_dir()]


def resolve_zoxide_binary(explicit_bin: str | None) -> str | None:
    if explicit_bin:
        if explicit_bin == "none":
            return None
        return explicit_bin if shutil.which(explicit_bin) or Path(explicit_bin).is_file() else None
    for candidate in (
        shutil.which("zoxide"),
        "/opt/homebrew/bin/zoxide",
        str(Path.home() / ".local/bin/zoxide"),
        str(Path.home() / ".cargo/bin/zoxide"),
    ):
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def query_zoxide_scores(zoxide_bin: str | None) -> list[tuple[float, Path]]:
    if not zoxide_bin:
        return []
    try:
        proc = subprocess.run(
            [zoxide_bin, "query", "-ls"],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []

    results: list[tuple[float, Path]] = []
    for line in proc.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            score = float(parts[0])
        except ValueError:
            continue
        results.append((score, Path(parts[1])))
    return results


def query_finder_recent_folders(recents_file: Path | None) -> list[Path]:
    if recents_file is not None:
        if not recents_file.is_file():
            return []
        paths: list[Path] = []
        for line in recents_file.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if "\t" in stripped:
                _, raw_path = stripped.split("\t", 1)
            else:
                raw_path = stripped
            paths.append(Path(raw_path.strip()))
        return paths

    swift_bin = shutil.which("swift")
    if not swift_bin or sys.platform != "darwin":
        return []

    swift_code = """
import Foundation
if let defaults = UserDefaults(suiteName: "com.apple.finder"),
   let recents = defaults.array(forKey: "FXRecentFolders") as? [[String: Any]] {
    for item in recents.prefix(20) {
        if let data = item["file-bookmark"] as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                print(url.path)
            }
        }
    }
}
"""
    try:
        proc = subprocess.run(
            [swift_bin, "-e", swift_code],
            capture_output=True,
            text=True,
            check=False,
            timeout=4,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    return [Path(line.strip()) for line in proc.stdout.splitlines() if line.strip()]


def canonicalize_candidate(
    raw_path: Path,
    canonical_roots: list[Path],
    known_workspaces: dict[Path, CandidateDir],
    wiki_projects_by_path: dict[Path, WikiProject],
    home: Path,
    wiki_path: Path,
) -> tuple[Path | None, WikiProject | None, bool]:
    """Map a visited path to (canonical_dir, matching_wiki_project, in_canonical_root)."""
    if not raw_path.is_dir():
        return None, None, False

    resolved = safe_resolve(raw_path)

    # 1. Check if inside a registered wiki project first.
    for proj_resolved, proj in wiki_projects_by_path.items():
        if resolved == proj_resolved or proj_resolved in resolved.parents:
            return proj.path, proj, False

    # 2. Check if inside a known workspace candidate (handles symlinked workspaces like keybinding).
    for ws_resolved, cand in known_workspaces.items():
        if resolved == ws_resolved or ws_resolved in resolved.parents:
            return cand.path, None, cand.in_canonical_root

    # 3. Check if inside one of the canonical workspace parent roots (e.g. ~/repos/<project>).
    for root in canonical_roots:
        root_resolved = safe_resolve(root)
        if resolved == root_resolved:
            return None, None, False
        if root_resolved in resolved.parents:
            rel_parts = resolved.relative_to(root_resolved).parts
            if not rel_parts:
                return None, None, False
            top_child = safe_resolve(root / rel_parts[0])
            if top_child.name.startswith(".") or top_child.name.lower() in DENY_EXACT_NAMES:
                return None, None, False
            if top_child.is_dir():
                return top_child, None, True
            return None, None, False

    # Reject root/home/system/noisy paths outside canonical roots.
    deny_paths = {
        Path("/"),
        home,
        home / "Downloads",
        home / "Documents",
        home / "Desktop",
        home / "Library",
        safe_resolve(wiki_path),
        safe_resolve(wiki_path / "99_meta"),
        safe_resolve(wiki_path / "99_meta/scripts"),
    }
    if resolved in deny_paths:
        return None, None, False

    # Reject hidden directories or denied component names.
    for part in resolved.parts:
        if part.startswith(".") or part.lower() in DENY_EXACT_NAMES:
            return None, None, False

    return None, None, False


def format_disambiguated_labels(
    items: list[tuple[str, Path, dict]],
) -> list[tuple[str, Path, dict]]:
    """Ensure every generated pin has a unique label in mysides."""
    base_counts: dict[str, int] = {}
    for prefix, path, _meta in items:
        label = f"{prefix} {path.name}" if prefix else path.name
        base_counts[label] = base_counts.get(label, 0) + 1

    output: list[tuple[str, Path, dict]] = []
    seen_labels: set[str] = set()
    for prefix, path, meta in items:
        label = f"{prefix} {path.name}" if prefix else path.name
        if base_counts.get(label, 0) > 1 or label in seen_labels:
            parent_name = path.parent.name
            label = f"{label} ({parent_name})"
        seen_labels.add(label)
        output.append((label, path, meta))
    return output


def rank_pins(
    *,
    wiki_path: Path,
    registry_path: Path,
    pin_state_path: Path,
    active_inbox_path: Path,
    sidebar_lines: list[str],
    canonical_roots: list[Path],
    chatgpt_routes_paths: list[Path],
    zoxide_bin: str | None,
    finder_recents_file: Path | None,
    project_slots: int,
    created_slots: int,
    created_days: float,
    frequent_slots: int,
    now_ts: float,
    enable_dynamic: bool,
) -> tuple[list[tuple[str, Path, dict]], set[str]]:
    registry_projects = load_registry_projects(registry_path, active_inbox_path)
    owned_labels = load_owned_labels(pin_state_path, registry_projects)
    manual_paths = load_manual_sidebar_paths(sidebar_lines, owned_labels)
    chatgpt_keys = load_chatgpt_project_keys(chatgpt_routes_paths) if enable_dynamic else set()

    wiki_projects_by_path: dict[Path, WikiProject] = {
        safe_resolve(p.path): p for p in registry_projects if p.path.is_dir()
    }
    for proj in registry_projects:
        if normalize_key(proj.name) in chatgpt_keys or normalize_key(proj.path.name) in chatgpt_keys:
            proj.chatgpt_match = True

    home = Path.home()
    candidates: dict[Path, CandidateDir] = {}

    def get_or_create_candidate(path: Path, in_root: bool = True) -> CandidateDir:
        resolved = safe_resolve(path)
        if resolved not in candidates:
            birth, mtime = stat_times(resolved)
            key = normalize_key(resolved.name)
            candidates[resolved] = CandidateDir(
                path=resolved,
                birthtime=birth,
                mtime=mtime,
                chatgpt_match=(key in chatgpt_keys),
                in_canonical_root=in_root,
            )
        return candidates[resolved]

    if enable_dynamic:
        # 1. Scan canonical roots for all immediate workspace directories (birth/mtime + ChatGPT match).
        for root in canonical_roots:
            if not root.is_dir():
                continue
            try:
                children = sorted(root.iterdir(), key=lambda p: p.name)
            except OSError:
                continue
            for child in children:
                if not child.is_dir() or child.name.startswith("."):
                    continue
                if child.name.lower() in DENY_EXACT_NAMES:
                    continue
                cand = get_or_create_candidate(child, in_root=True)
                cand.sources.add("root-scan")

        # 2. Ingest zoxide frecency scores.
        for score, raw_path in query_zoxide_scores(zoxide_bin):
            canon_path, matched_proj, in_root = canonicalize_candidate(
                raw_path, canonical_roots, candidates, wiki_projects_by_path, home, wiki_path
            )
            if matched_proj is not None:
                matched_proj.zoxide_score += score
                continue
            if canon_path is not None:
                cand = get_or_create_candidate(canon_path, in_root=in_root)
                cand.zoxide_score += score
                cand.sources.add("zoxide")

        # 3. Ingest Finder FXRecentFolders.
        for rank, raw_path in enumerate(query_finder_recent_folders(finder_recents_file)):
            canon_path, matched_proj, in_root = canonicalize_candidate(
                raw_path, canonical_roots, candidates, wiki_projects_by_path, home, wiki_path
            )
            if matched_proj is not None:
                if matched_proj.finder_rank is None or rank < matched_proj.finder_rank:
                    matched_proj.finder_rank = rank
                continue
            if canon_path is not None:
                cand = get_or_create_candidate(canon_path, in_root=in_root)
                if cand.finder_rank is None or rank < cand.finder_rank:
                    cand.finder_rank = rank
                cand.sources.add("finder")

    # --- Bucket 1: Top N Registered Wiki Projects ---
    valid_wiki_projects = [p for p in registry_projects if p.path.is_dir()]
    # Deterministic selection of most recent N projects:
    # Focused project first, then most recently registered (highest project_id), then birthtime.
    ranked_wiki_projects = sorted(
        valid_wiki_projects,
        key=lambda p: (
            1 if p.is_focused else 0,
            p.project_id,
            round(p.birthtime, 0),
            round(p.zoxide_score, 1),
        ),
        reverse=True,
    )
    selected_wiki_projects = ranked_wiki_projects[: max(0, project_slots)]
    # Preserve ascending registry ID order in the sidebar for selected wiki projects.
    selected_wiki_projects.sort(key=lambda p: (p.project_id, p.name))

    selected_paths: set[Path] = set(manual_paths)
    final_pins: list[tuple[str, Path, dict]] = []

    for proj in selected_wiki_projects:
        resolved = safe_resolve(proj.path)
        selected_paths.add(resolved)
        final_pins.append(
            (
                proj.label,
                proj.path,
                {
                    "bucket": "project",
                    "project_id": proj.project_id,
                    "is_focused": proj.is_focused,
                    "birthtime": proj.birthtime,
                    "zoxide_score": round(proj.zoxide_score, 1),
                },
            )
        )

    if not enable_dynamic:
        return final_pins, owned_labels

    # --- Bucket 2: Recently Created Directories (within lookback window) ---
    cutoff_ts = now_ts - (created_days * 86400.0)
    created_candidates = [
        cand
        for resolved, cand in candidates.items()
        if resolved not in selected_paths
        and cand.in_canonical_root
        and cand.birthtime >= cutoff_ts
    ]
    created_candidates.sort(
        key=lambda c: (-round(c.birthtime, 0), str(c.path))
    )
    selected_created = created_candidates[: max(0, created_slots)]

    dynamic_raw: list[tuple[str, Path, dict]] = []
    for cand in selected_created:
        selected_paths.add(safe_resolve(cand.path))
        dynamic_raw.append(
            (
                "🆕",
                cand.path,
                {
                    "bucket": "created",
                    "birthtime": round(cand.birthtime, 0),
                    "age_days": round(max(0.0, (now_ts - cand.birthtime) / 86400.0), 1),
                    "chatgpt_match": cand.chatgpt_match,
                },
            )
        )

    # --- Bucket 3: Frequently Visited Directories (zoxide + Finder + ChatGPT) ---
    frequent_candidates = [
        cand
        for resolved, cand in candidates.items()
        if resolved not in selected_paths
        and (cand.zoxide_score > 0 or cand.finder_rank is not None)
    ]
    frequent_candidates.sort(
        key=lambda c: (-c.frequent_score, -round(c.zoxide_score, 1), str(c.path))
    )
    selected_frequent = frequent_candidates[: max(0, frequent_slots)]

    for cand in selected_frequent:
        selected_paths.add(safe_resolve(cand.path))
        dynamic_raw.append(
            (
                "⚡",
                cand.path,
                {
                    "bucket": "frequent",
                    "score": cand.frequent_score,
                    "zoxide_score": round(cand.zoxide_score, 1),
                    "finder_rank": cand.finder_rank,
                    "chatgpt_match": cand.chatgpt_match,
                },
            )
        )

    for label, path, meta in format_disambiguated_labels(dynamic_raw):
        owned_labels.add(label)
        final_pins.append((label, path, meta))

    return final_pins, owned_labels


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compute deterministic Finder sidebar pins from res projects, zoxide, Finder recents, and recent directory creations."
    )
    parser.add_argument(
        "--wiki-path",
        default=os.environ.get("WIKI_PATH", str(DEFAULT_WIKI_PATH)),
        help="Path to the wiki root.",
    )
    parser.add_argument(
        "--registry",
        default=os.environ.get("RES_FINDER_REGISTRY", ""),
        help="Path to .project_registry (defaults to <wiki>/99_meta/.project_registry).",
    )
    parser.add_argument(
        "--pin-state",
        default=os.environ.get("FINDER_PIN_STATE", ""),
        help="Path to .finder_project_pins state file.",
    )
    parser.add_argument(
        "--project-slots",
        type=int,
        default=int(os.environ.get("RES_FINDER_PROJECT_SLOTS", DEFAULT_PROJECT_SLOTS)),
        help="Number of recent registered wiki projects to pin (default: 3).",
    )
    parser.add_argument(
        "--created-slots",
        type=int,
        default=int(os.environ.get("RES_FINDER_CREATED_SLOTS", DEFAULT_CREATED_SLOTS)),
        help="Number of recently created workspace directories to pin (default: 3).",
    )
    parser.add_argument(
        "--created-days",
        type=float,
        default=float(os.environ.get("RES_FINDER_CREATED_DAYS", DEFAULT_CREATED_DAYS)),
        help="Lookback window in days for recently created directories (default: 14).",
    )
    parser.add_argument(
        "--frequent-slots",
        type=int,
        default=int(os.environ.get("RES_FINDER_FREQUENT_SLOTS", DEFAULT_FREQUENT_SLOTS)),
        help="Number of frequent zoxide/Finder directories to pin (default: 6).",
    )
    parser.add_argument(
        "--roots",
        default=os.environ.get("RES_FINDER_ROOTS", ""),
        help="Colon-separated workspace roots to scan for dynamic pins.",
    )
    parser.add_argument(
        "--chatgpt-routes",
        default=os.environ.get("RES_FINDER_CHATGPT_ROUTES", ""),
        help="Path to chat-shortcut-routes.json.",
    )
    parser.add_argument(
        "--zoxide-bin",
        default=os.environ.get("RES_FINDER_ZOXIDE_BIN", ""),
        help="Path to zoxide binary (or 'none' to disable).",
    )
    parser.add_argument(
        "--finder-recents-file",
        default=os.environ.get("RES_FINDER_RECENTS_FILE", ""),
        help="Optional newline-separated file of Finder recent folder paths.",
    )
    parser.add_argument(
        "--sidebar-list-file",
        default=os.environ.get("RES_FINDER_SIDEBAR_LIST_FILE", ""),
        help="Optional file containing `mysides list` output.",
    )
    parser.add_argument(
        "--now",
        type=float,
        default=float(os.environ.get("RES_FINDER_NOW", "0") or 0.0),
        help="Override current epoch timestamp for deterministic testing.",
    )
    parser.add_argument(
        "--dynamic",
        choices=("auto", "on", "off"),
        default=os.environ.get("RES_FINDER_DYNAMIC", "auto"),
        help="Whether to include dynamic zoxide/Finder/created pins (default: auto).",
    )
    parser.add_argument(
        "--format",
        choices=("tsv", "json", "pretty", "owned-labels"),
        default="tsv",
        help="Output format (default: tsv of LABEL<TAB>PATH).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    wiki_path = Path(args.wiki_path)
    registry_path = (
        Path(args.registry)
        if args.registry
        else wiki_path / "99_meta" / ".project_registry"
    )
    pin_state_path = (
        Path(args.pin_state)
        if args.pin_state
        else wiki_path / "99_meta" / ".finder_project_pins"
    )
    active_inbox_path = wiki_path / "99_meta" / "Active_Inbox"

    now_ts = args.now if args.now > 0 else __import__("time").time()

    if args.roots:
        canonical_roots = [Path(p) for p in args.roots.split(":") if p.strip()]
    else:
        canonical_roots = discover_default_roots(Path.home())

    if args.dynamic == "on":
        enable_dynamic = True
    elif args.dynamic == "off":
        enable_dynamic = False
    else:
        # In auto mode, enable dynamic workspace discovery when running against the
        # canonical wiki or when explicit roots/recents/zoxide overrides are provided.
        enable_dynamic = bool(
            args.roots
            or args.finder_recents_file
            or args.zoxide_bin
            or safe_resolve(wiki_path) == safe_resolve(DEFAULT_WIKI_PATH)
        )

    routes_paths: list[Path] = []
    if args.chatgpt_routes:
        routes_paths.append(Path(args.chatgpt_routes))
    else:
        routes_paths.append(
            wiki_path / "99_meta/conversations/pinned/chat-shortcut-routes.json"
        )
        routes_paths.append(
            Path.home() / "wiki/99_meta/conversations/pinned/chat-shortcut-routes.json"
        )

    sidebar_lines: list[str] = []
    if args.sidebar_list_file and Path(args.sidebar_list_file).is_file():
        sidebar_lines = (
            Path(args.sidebar_list_file).read_text(encoding="utf-8").splitlines()
        )

    zoxide_bin = resolve_zoxide_binary(args.zoxide_bin or None)
    recents_file = Path(args.finder_recents_file) if args.finder_recents_file else None

    try:
        pins, owned_labels = rank_pins(
            wiki_path=wiki_path,
            registry_path=registry_path,
            pin_state_path=pin_state_path,
            active_inbox_path=active_inbox_path,
            sidebar_lines=sidebar_lines,
            canonical_roots=canonical_roots,
            chatgpt_routes_paths=routes_paths,
            zoxide_bin=zoxide_bin,
            finder_recents_file=recents_file,
            project_slots=args.project_slots,
            created_slots=args.created_slots,
            created_days=args.created_days,
            frequent_slots=args.frequent_slots,
            now_ts=now_ts,
            enable_dynamic=enable_dynamic,
        )
    except RuntimeError as exc:
        print(f"   Error: {exc}", file=sys.stderr)
        return 1

    if args.format == "owned-labels":
        for label in sorted(owned_labels):
            print(label)
        return 0

    if args.format == "json":
        payload = [
            {"label": label, "path": str(path), **meta}
            for label, path, meta in pins
        ]
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    if args.format == "pretty":
        for label, path, meta in pins:
            bucket = meta.get("bucket", "")
            details = []
            if bucket == "project":
                if meta.get("is_focused"):
                    details.append("focused")
                if meta.get("zoxide_score"):
                    details.append(f"zoxide={meta['zoxide_score']}")
            elif bucket == "created":
                details.append(f"age={meta.get('age_days')}d")
                if meta.get("chatgpt_match"):
                    details.append("chatgpt")
            elif bucket == "frequent":
                details.append(f"score={meta.get('score')}")
                if meta.get("zoxide_score"):
                    details.append(f"zoxide={meta['zoxide_score']}")
                if meta.get("finder_rank") is not None:
                    details.append(f"finder=#{meta['finder_rank'] + 1}")
                if meta.get("chatgpt_match"):
                    details.append("chatgpt")
            suffix = f" ({', '.join(details)})" if details else ""
            print(f"{label:<34} -> {path}{suffix}")
        return 0

    for label, path, _meta in pins:
        print(f"{label}\t{path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
