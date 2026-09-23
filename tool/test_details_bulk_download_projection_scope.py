#!/usr/bin/env python3
from pathlib import Path
import re

path = Path("apps/app/lib/home_shell_source_compat.dart")
text = path.read_text()
match = re.search(
    r"Future<Iterable<ChapterDownloadSnapshot>> _inspectChapterDownloads\(.*?\n  \}",
    text,
    re.S,
)
if match is None:
    raise SystemExit("_inspectChapterDownloads not found")
body = match.group(0)
if "hydrateEntry" in body:
    raise SystemExit("details bulk download projection must not hydrate every chapter")
if "_chapterDownloads.inspectMany(entries)" not in body:
    raise SystemExit("details bulk download projection must delegate compact entries to inspectMany")
print("details bulk download projection scope: OK")
