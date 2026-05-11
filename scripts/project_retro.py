#!/usr/bin/env python3
"""Create a project retrospective note from a research project directory."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import shutil
import subprocess
import sys
from pathlib import Path


TEXT_SUFFIXES = {
    ".bib",
    ".csv",
    ".css",
    ".html",
    ".json",
    ".log",
    ".md",
    ".py",
    ".rst",
    ".srt",
    ".tex",
    ".txt",
    ".yaml",
    ".yml",
    ".zsh",
    ".sh",
}


def is_text_file(path: Path) -> bool:
    return path.suffix.lower() in TEXT_SUFFIXES


def read_excerpt(path: Path, max_chars: int) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""

    text = text.strip()
    if len(text) <= max_chars:
        return text

    half = max_chars // 2
    return (
        text[:half].rstrip()
        + "\n\n[... middle truncated for prompt budget ...]\n\n"
        + text[-half:].lstrip()
    )


def collect_project_context(project_path: Path, max_files: int, excerpt_chars: int) -> str:
    rows: list[str] = []
    excerpts: list[str] = []
    seen = 0

    for path in sorted(project_path.rglob("*")):
        if any(part.startswith(".") for part in path.relative_to(project_path).parts):
            continue
        if path.is_dir():
            continue

        rel = path.relative_to(project_path)
        target = ""
        if path.is_symlink():
            try:
                target = f" -> {os.readlink(path)}"
            except OSError:
                target = " -> [unreadable symlink]"

        try:
            size = path.lstat().st_size
        except OSError:
            size = 0

        rows.append(f"- `{rel}` ({size} bytes){target}")

        if seen < max_files and path.is_file() and is_text_file(path):
            excerpt = read_excerpt(path, excerpt_chars)
            if excerpt:
                excerpts.append(f"### {rel}\n\n```text\n{excerpt}\n```")
                seen += 1

    manifest = "\n".join(rows) if rows else "- [no files found]"
    excerpt_block = "\n\n".join(excerpts) if excerpts else "[no text excerpts collected]"
    return f"## Project File Manifest\n\n{manifest}\n\n## Text Excerpts\n\n{excerpt_block}\n"


def build_retro_prompt(project_id: str, project_name: str, project_path: Path, context: str) -> str:
    return f"""You are writing a final retrospective note for a completed research project.

Project id: {project_id}
Project name: {project_name}
Project path: {project_path}

Use the manifest and excerpts below to infer which files were most useful, which
were only background/context, which were not useful for the final output, and
which appear unused or low value. Be practical and candid. Do not overclaim use
of a file when the evidence only shows that it existed in the project folder.

Write Markdown with these sections:

# Project Retrospective: {project_name}

## Summary
A short paragraph describing what the project appears to have produced.

## Most Helpful Files
Bullets with file paths and why they mattered.

## Helpful Context, But Not Final Deliverables
Bullets with file paths and how they contributed background.

## Not Very Useful For The Final Output
Bullets with file paths and why they were not central.

## Mostly Unused Or Low Value
Bullets with file paths and why they appear unused, redundant, or low value.

## Final Takeaway
One concise paragraph naming the real pillars of the project.

{context}
"""


def build_ledger_prompt(project_id: str, project_name: str, project_path: Path, context: str) -> str:
    return f"""You are drafting a source ledger for an active research project.

Project id: {project_id}
Project name: {project_name}
Project path: {project_path}

The goal is not to declare the project finished. The output should be useful as
a compact machine-readable control file for future LLM runs. The human is not
expected to read long prose.

Use the manifest and excerpts below to infer each file's likely role. Be
conservative: when there is not enough evidence, mark `needs_review: true`.
Do not overclaim that a file was used. Prefer "candidate", "context", or
"unknown" when usage is unclear.

Write compact Markdown with exactly these sections:

# Source Ledger Draft: {project_name}

```yaml
status: draft
project_id: "{project_id}"
project_name: "{project_name}"
project_path: "{project_path}"
review_mode: llm_first
human_review_expected: false
schema: source-ledger/v1
```

## Attention Queue
List only items requiring action or uncertainty. Keep each bullet one line:
- `path` — reason; suggested_action

## Ledger YAML
Return a single fenced `yaml` block containing a list named `sources`.
Each source object must be concise:

```yaml
sources:
  - path: "relative/path"
    target: "symlink target or empty"
    link_status: "local|symlink_ok|symlink_missing|unknown"
    role: "core|supporting|context|candidate|discarded|unused|unknown"
    weight: 0
    used_for: "short phrase or empty"
    needs_review: true
    action: "keep|copy_canonical|repair_link|unlink|archive|ignore|review"
```

Rules:
- Include every meaningful file, but keep each field short.
- Do not add prose notes per source.
- Put explanation only in `Attention Queue`, and only for files needing action.
- Prefer `needs_review: false` when the role is obvious from the project files.
- Prefer `action: keep` for stable local files and `action: copy_canonical` for important symlinked submission artifacts.

{context}
"""


def available_report_path(reports_dir: Path, stem: str) -> Path:
    path = reports_dir / f"{stem}.md"
    if not path.exists():
        return path

    index = 2
    while True:
        candidate = reports_dir / f"{stem}_{index}.md"
        if not candidate.exists():
            return candidate
        index += 1


def run_llm(prompt: str, model: str | None) -> str:
    model = model or os.environ.get("RES_RETRO_LLM_MODEL") or os.environ.get("OPENAI_EVERYDAY_MODEL")
    custom_cmd = os.environ.get("RES_RETRO_LLM_CMD")
    if custom_cmd:
        result = subprocess.run(
            custom_cmd,
            input=prompt,
            text=True,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"{custom_cmd} failed")
        return result.stdout.strip()

    llm = shutil.which("llm")
    if llm:
        cmd = [llm, "prompt", "--no-stream"]
        if model:
            cmd.extend(["-m", model])
        result = subprocess.run(
            cmd,
            input=prompt,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "llm prompt failed")
        return result.stdout.strip()

    gemini = shutil.which("gemini")
    if gemini:
        cmd = [gemini, "-p", prompt]
        result = subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "gemini failed")
        return result.stdout.strip()

    raise RuntimeError(
        "No supported LLM CLI found. Install/configure `llm`, `gemini`, or set RES_RETRO_LLM_CMD."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a project retrospective note.")
    parser.add_argument("--kind", choices=["retro", "ledger"], default="retro")
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--project-name", required=True)
    parser.add_argument("--project-path", required=True)
    parser.add_argument("--model")
    parser.add_argument("--no-llm", action="store_true")
    parser.add_argument("--max-files", type=int, default=40)
    parser.add_argument("--excerpt-chars", type=int, default=3000)
    args = parser.parse_args()

    project_path = Path(args.project_path).expanduser().resolve()
    if not project_path.is_dir():
        print(f"Project path not found: {project_path}", file=sys.stderr)
        return 1

    report_label = "source ledger" if args.kind == "ledger" else "project retro"
    print(f"🔎 Building {report_label} context for {args.project_name}...")
    print(f"📁 Project: {project_path}")

    today = dt.date.today().isoformat()
    reports_dir = project_path / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    report_name = "Source_Ledger" if args.kind == "ledger" else "Project_Retro"
    note_path = available_report_path(reports_dir, f"{today}_{report_name}")
    prompt_path = note_path.with_name(f"{note_path.stem}_Prompt.md")

    context = collect_project_context(project_path, args.max_files, args.excerpt_chars)
    print(f"🧾 Writing prompt context: {prompt_path}")
    if args.kind == "ledger":
        prompt = build_ledger_prompt(args.project_id, args.project_name, project_path, context)
    else:
        prompt = build_retro_prompt(args.project_id, args.project_name, project_path, context)
    prompt_path.write_text(prompt, encoding="utf-8")

    if args.no_llm:
        title = "Source Ledger Draft" if args.kind == "ledger" else "Project Retrospective"
        print("⏩ Skipping LLM generation (--no-llm).")
        note_path.write_text(
            f"# {title}: {args.project_name}\n\n"
            f"LLM generation was skipped. Use this prompt to generate the note:\n\n"
            f"- `{prompt_path}`\n",
            encoding="utf-8",
        )
    else:
        selected_model = args.model or os.environ.get("RES_RETRO_LLM_MODEL") or os.environ.get("OPENAI_EVERYDAY_MODEL")
        if selected_model:
            print(f"🤖 Calling LLM model: {selected_model}")
        else:
            print("🤖 Calling LLM with provider default model...")
        try:
            note = run_llm(prompt, args.model)
        except RuntimeError as exc:
            note_path.write_text(
                f"# {'Source Ledger Draft' if args.kind == 'ledger' else 'Project Retrospective'}: {args.project_name}\n\n"
                f"LLM generation failed:\n\n```text\n{exc}\n```\n\n"
                f"Prompt saved at `{prompt_path}`.\n",
                encoding="utf-8",
            )
            print(f"⚠️  LLM generation failed; prompt saved: {prompt_path}", file=sys.stderr)
            print(f"📝 Retro placeholder: {note_path}")
            return 2
        print(f"✍️  Writing generated note: {note_path}")
        note_path.write_text(note.rstrip() + "\n", encoding="utf-8")

    label = "Source ledger" if args.kind == "ledger" else "Retro note"
    print(f"📝 {label}: {note_path}")
    print(f"🧾 Prompt: {prompt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
