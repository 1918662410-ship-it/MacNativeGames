#!/usr/bin/env python3
"""Build a merged RomFS overlay for a LayeredFS-style TOTK mod.

The native runtime (runtime/romfs.c) serves files listed in
$TOTK_ROMFS_PATCHES/manifest.tsv in place of the base RomFS. The stock app ships
two integrity-checked patches (quick-menu capture, game-over retry); this tool
copies those first, then adds/replaces files from a mod, and writes a new
manifest with the original and mod SHA-256 values the runtime verifies.

Supported: mods that REPLACE existing RomFS files (the usual LayeredFS layout
<mod>/romfs/<path>). Files that do not exist in the base RomFS are reported and
skipped; code/ExeFS patches are not supported. At most 254 overlays are allowed
by runtime/romfs.c (NOVL is 255; one slot is reserved for the output-resolution overlay),
including the two built-in patches.

Usage:
  python3 scripts/make_mod_overlay.py --mod ~/mods/MyMod --out ~/mods/MyMod-overlay
  open --env TOTK_ROMFS_PATCHES="$HOME/mods/MyMod-overlay" ~/TOTK.app
  # or: launchctl setenv TOTK_ROMFS_PATCHES "$HOME/mods/MyMod-overlay"; open ~/TOTK.app

Requires the build work directory (index.json + romfs.bin), normally
~/totk_build/totk/extracted/v0/romfs; pass --romfs if it lives elsewhere.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

MAX_OVERLAYS = 254  # NOVL is 255; the output-resolution overlay uses one more slot.
CHUNK = 8 << 20


def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def sha_range(image: Path, offset: int, size: int) -> str:
    h = hashlib.sha256()
    with image.open("rb") as f:
        f.seek(offset)
        left = size
        while left:
            block = f.read(min(CHUNK, left))
            if not block:
                raise SystemExit(f"short read in {image} at {offset}+{size}")
            h.update(block)
            left -= len(block)
    return h.hexdigest()


def norm_rel(path: Path) -> str:
    s = path.as_posix()
    return s[1:] if s.startswith("/") else s


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mod", type=Path, required=True, help="mod root containing romfs/, or the romfs/ directory itself")
    ap.add_argument("--out", type=Path, required=True, help="output overlay directory (must not exist or be empty)")
    ap.add_argument("--romfs", type=Path, default=Path.home() / "totk_build/totk/extracted/v0/romfs")
    ap.add_argument("--patches", type=Path, default=Path.home() / "TOTK.app/Contents/Resources/totk/extracted/v0/romfs-patches")
    args = ap.parse_args()

    index_path, image_path = args.romfs / "index.json", args.romfs / "romfs.bin"
    for p in (index_path, image_path, args.mod, args.patches):
        if not p.exists():
            raise SystemExit(f"missing: {p}")
    index = json.loads(index_path.read_text())
    if index.get("status") != "pass":
        raise SystemExit("RomFS index is not marked pass")
    by_path = {f["path"]: f for f in index["files"]}
    lower = {p.lower(): p for p in by_path}

    root = args.mod / "romfs" if (args.mod / "romfs").is_dir() else args.mod
    mod_files: list[Path] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name == ".DS_Store":
                continue
            mod_files.append(Path(dirpath) / name)
    if not mod_files:
        raise SystemExit(f"no files under {root}")

    out = args.out
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"{out} is not empty; remove it first")
    if out.exists():
        out.rmdir()
    out.mkdir(parents=True)

    entries: dict[str, tuple[int, str, str]] = {}  # path -> (size, mod sha, original sha)

    def add_file(rel: str, src: Path, original: str) -> None:
        data = src.read_bytes()
        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
        entries[rel] = (len(data), hashlib.sha256(data).hexdigest(), original)

    # Keep the app's built-in patches (same RomFS paths, trusted manifest lines).
    manifest = args.patches / "manifest.tsv"
    if manifest.is_file():
        for line in manifest.read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            name, size, sha, orig = line.split("\t")
            src = args.patches / name
            if not src.is_file():
                raise SystemExit(f"built-in patch file missing: {src}")
            add_file(name, src, orig)
            if int(size) != entries[name][0]:
                raise SystemExit(f"built-in patch size mismatch: {name}")

    skipped_new, skipped_case = [], []
    for src in sorted(mod_files):
        rel = norm_rel(src.relative_to(root))
        if ".." in rel.split("/"):
            raise SystemExit(f"refusing path with ..: {rel}")
        if rel not in by_path:
            fixed = lower.get(rel.lower())
            if fixed is None:
                skipped_new.append(rel)
                continue
            skipped_case.append((rel, fixed))
            rel = fixed
        f = by_path[rel]
        original = sha_range(image_path, f["offset"], f["size"])
        add_file(rel, src, original)

    if len(entries) > MAX_OVERLAYS:
        raise SystemExit(f"{len(entries)} overlaid files > NOVL ({MAX_OVERLAYS}); the runtime cannot load this many")
    with (out / "manifest.tsv").open("w") as m:
        m.write("# path\tsize\tsha256\toriginal_sha256 (generated by scripts/make_mod_overlay.py)\n")
        for rel in sorted(entries):
            size, sha, original = entries[rel]
            m.write(f"{rel}\t{size}\t{sha}\t{original}\n")

    print(f"wrote {out} ({len(entries)} overlay files; {len(skipped_new)} new files skipped)")
    for rel, fixed in skipped_case:
        print(f"  case corrected: {rel} -> {fixed}")
    for rel in skipped_new:
        print(f"  not in base RomFS, skipped: {rel}")
    print(f'launch: launchctl setenv TOTK_ROMFS_PATCHES "{out}"; open ~/TOTK.app')
    return 0


if __name__ == "__main__":
    sys.exit(main())
