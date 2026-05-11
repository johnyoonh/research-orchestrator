#!/usr/bin/env python3
import re
import shutil
import time
import hashlib
from pathlib import Path

# Configuration
WATCH_DIR = Path.home() / "Downloads"
INBOX_DIR = Path.home() / "repos" / "research-orchestrator" / "inbox"
ACTIVE_DOWNLOAD_EXTS = {'.crdownload', '.download', '.part'}
VALID_EXTS = {'.epub', '.pdf', '.mobi', '.azw3'}


def is_target_book(file_path: Path) -> bool:
    if file_path.suffix.lower() not in VALID_EXTS:
        return False

    # Anna's Archive signature OR Libgen signature
    is_anna = ' -- ' in file_path.name and (
        'Anna’s Archive' in file_path.name
        or 'Anna\'s Archive' in file_path.name
        or re.search(r'[a-f0-9]{32}', file_path.name)
    )
    is_libgen = (
        '{' in file_path.name
        and '}' in file_path.name
        and re.search(r'libgen\.[a-z]+', file_path.name, re.IGNORECASE)
    )
    return bool(is_anna or is_libgen)


def clean_filename(filename: str) -> str:
    original_ext = Path(filename).suffix
    
    # 1. Anna's Archive (Double Dash format)
    # e.g., Title -- Author -- Publisher -- ... -- md5 -- Anna's Archive.epub
    if ' -- ' in filename:
        parts = filename.split(' -- ')
        if len(parts) >= 2:
            title = parts[0].strip()
            author = parts[1].strip()
            return f"{title} -- {author}{original_ext}"
            
    # 2. Libgen Native (Brackets format)
    # e.g., Title{Author}(Year...) libgen.li.epub
    match_libgen = re.match(r'^(.*?)\{(.*?)\}', filename)
    if match_libgen:
        title = match_libgen.group(1).strip()
        author = match_libgen.group(2).strip()
        return f"{title} -- {author}{original_ext}"
        
    return filename


def is_active_download(file_path: Path) -> bool:
    if file_path.suffix.lower() in ACTIVE_DOWNLOAD_EXTS:
        return True
    return any(file_path.with_suffix(file_path.suffix + suffix).exists() for suffix in ACTIVE_DOWNLOAD_EXTS)


def file_hash(file_path: Path) -> str:
    digest = hashlib.sha256()
    with file_path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def same_file_content(left: Path, right: Path) -> bool:
    left_stat = left.stat()
    right_stat = right.stat()
    if left_stat.st_size != right_stat.st_size:
        return False
    return file_hash(left) == file_hash(right)


def matching_inbox_file(dest_folder: Path, source_path: Path) -> Path | None:
    if not dest_folder.exists():
        return None
    source_stat = source_path.stat()
    source_digest: str | None = None
    source_suffix = source_path.suffix.lower()
    for candidate in dest_folder.iterdir():
        if not candidate.is_file():
            continue
        if candidate.suffix.lower() != source_suffix:
            continue
        if candidate.stat().st_size != source_stat.st_size:
            continue
        if source_digest is None:
            source_digest = file_hash(source_path)
        if file_hash(candidate) == source_digest:
            return candidate
    return None


def unique_destination(dest_folder: Path, clean_name: str, source_path: Path) -> tuple[Path | None, Path | None]:
    duplicate_path = matching_inbox_file(dest_folder, source_path)
    if duplicate_path:
        return None, duplicate_path

    dest_path = dest_folder / clean_name
    if not dest_path.exists():
        return dest_path, None

    if same_file_content(source_path, dest_path):
        return None, dest_path

    stem = dest_path.stem
    suffix = dest_path.suffix
    counter = 1
    while True:
        candidate = dest_folder / f"{stem}_{counter}{suffix}"
        if not candidate.exists():
            return candidate, None
        if same_file_content(source_path, candidate):
            return None, candidate
        counter += 1


def prune_empty_parents(start: Path) -> None:
    current = start
    while current != WATCH_DIR and WATCH_DIR in current.parents:
        try:
            current.rmdir()
        except OSError:
            return
        current = current.parent


def process_books():
    # Give the browser a second to release the file handle or rename .crdownload
    time.sleep(2)
    
    for file_path in sorted(WATCH_DIR.rglob("*"), key=lambda p: (len(p.relative_to(WATCH_DIR).parts), str(p))):
        if not file_path.is_file():
            continue
            
        # Ignore active downloads
        if is_active_download(file_path):
            continue
            
        if not is_target_book(file_path):
            continue

        try:
            source_parent = file_path.parent

            # Let the file settle (ensure it's not currently being written to)
            size1 = file_path.stat().st_size
            time.sleep(0.5)
            size2 = file_path.stat().st_size
            if size1 != size2 or size1 == 0:
                continue

            clean_name = clean_filename(file_path.name)
            ext = file_path.suffix.lower()
            
            # Determine destination folder based on extension (remove dot)
            dest_folder = INBOX_DIR / ext[1:]
            dest_folder.mkdir(parents=True, exist_ok=True)
            
            dest_path, duplicate_path = unique_destination(dest_folder, clean_name, file_path)
            if duplicate_path:
                file_path.unlink()
                print(f"Removed duplicate: {file_path} already exists as {duplicate_path}")
                prune_empty_parents(source_parent)
                continue
                
            shutil.move(str(file_path), str(dest_path))
            print(f"Moved: {file_path} -> {dest_path}")
            prune_empty_parents(source_parent)
            
        except Exception as e:
            print(f"Error processing {file_path}: {e}")

if __name__ == "__main__":
    process_books()
