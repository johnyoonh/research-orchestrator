#!/usr/bin/env python3
import os
import re
import shutil
import time
from pathlib import Path

# Configuration
WATCH_DIR = Path.home() / "Downloads"
INBOX_DIR = Path.home() / "repos" / "research-orchestrator" / "inbox"

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

def process_books():
    # Only look for these extensions
    valid_exts = {'.epub', '.pdf', '.mobi', '.azw3'}
    
    # Give the browser a second to release the file handle or rename .crdownload
    time.sleep(2)
    
    for file_path in WATCH_DIR.iterdir():
        if not file_path.is_file():
            continue
            
        # Ignore active downloads
        if file_path.suffix.lower() in {'.crdownload', '.download', '.part'}:
            continue
            
        ext = file_path.suffix.lower()
        if ext not in valid_exts:
            continue
            
        # Check if the file matches our target patterns
        # Anna's Archive signature OR Libgen signature
        is_anna = ' -- ' in file_path.name and ('Anna’s Archive' in file_path.name or 'Anna\'s Archive' in file_path.name or re.search(r'[a-f0-9]{32}', file_path.name))
        is_libgen = '{' in file_path.name and '}' in file_path.name and re.search(r'libgen\.[a-z]+', file_path.name, re.IGNORECASE)
        
        if not (is_anna or is_libgen):
            continue
            
        try:
            # Let the file settle (ensure it's not currently being written to)
            size1 = file_path.stat().st_size
            time.sleep(0.5)
            size2 = file_path.stat().st_size
            if size1 != size2 or size1 == 0:
                continue

            clean_name = clean_filename(file_path.name)
            
            # Determine destination folder based on extension (remove dot)
            dest_folder = INBOX_DIR / ext[1:]
            dest_folder.mkdir(parents=True, exist_ok=True)
            
            dest_path = dest_folder / clean_name
            
            # Handle duplicate names
            counter = 1
            while dest_path.exists():
                name_without_ext = dest_path.stem
                if f"_{counter - 1}" in name_without_ext:
                    name_without_ext = name_without_ext.replace(f"_{counter - 1}", "")
                dest_path = dest_folder / f"{name_without_ext}_{counter}{dest_path.suffix}"
                counter += 1
                
            shutil.move(str(file_path), str(dest_path))
            print(f"Moved: {file_path.name} -> {dest_path}")
            
        except Exception as e:
            print(f"Error processing {file_path.name}: {e}")

if __name__ == "__main__":
    process_books()
