#!/usr/bin/env python3
"""Inspect a built SmartLayout.app / .dmg without macOS tools.

    python3 tools/bundle.py dist/SmartLayout-1.0.dmg     # extract + report
    python3 tools/bundle.py path/to/SmartLayout.app      # report only

Extraction needs `7z` (p7zip). Everything else is pure Python, so the
same checks run in Linux CI and in Claude Code cloud sessions.
"""
from __future__ import annotations

import plistlib
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"

CPU_TYPES = {0x0100000C: "arm64", 0x01000007: "x86_64"}
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
CS_MAGIC_CODEDIRECTORY = 0xFADE0C02
CS_ADHOC = 0x2
CS_RUNTIME = 0x10000


@dataclass
class Slice:
    arch: str
    signed: bool = False
    adhoc: bool = False
    hardened_runtime: bool = False
    team_id: str = ""
    identifier: str = ""
    min_os: str = ""


@dataclass
class Binary:
    path: Path
    slices: list[Slice] = field(default_factory=list)

    @property
    def archs(self) -> list[str]:
        return [s.arch for s in self.slices]


def _parse_signature(sig: bytes, sl: Slice) -> None:
    _, _, count = struct.unpack(">III", sig[:12])
    for j in range(count):
        _, off = struct.unpack(">II", sig[12 + 8 * j : 20 + 8 * j])
        magic = struct.unpack(">I", sig[off : off + 4])[0]
        if magic != CS_MAGIC_CODEDIRECTORY:
            continue
        version, flags = struct.unpack(">II", sig[off + 8 : off + 16])
        ident_off = struct.unpack(">I", sig[off + 20 : off + 24])[0]
        sl.identifier = sig[off + ident_off : sig.index(b"\0", off + ident_off)].decode()
        sl.adhoc = bool(flags & CS_ADHOC)
        sl.hardened_runtime = bool(flags & CS_RUNTIME)
        if version >= 0x20200:
            team_off = struct.unpack(">I", sig[off + 48 : off + 52])[0]
            if team_off:
                sl.team_id = sig[off + team_off : sig.index(b"\0", off + team_off)].decode()
        sl.signed = True
        return


def _parse_thin(data: bytes) -> Slice:
    magic, cpu, _, _, ncmds = struct.unpack("<IiiII", data[:20])
    if magic != 0xFEEDFACF:
        raise ValueError("not a 64-bit Mach-O")
    sl = Slice(arch=CPU_TYPES.get(cpu & 0xFFFFFFFF, hex(cpu)))
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[off : off + 8])
        if cmd == LC_CODE_SIGNATURE:
            doff, dsize = struct.unpack("<II", data[off + 8 : off + 16])
            _parse_signature(data[doff : doff + dsize], sl)
        elif cmd == LC_BUILD_VERSION:
            minos = struct.unpack("<I", data[off + 12 : off + 16])[0]
            sl.min_os = f"{minos >> 16}.{(minos >> 8) & 0xFF}"
        off += size
    return sl


def parse_macho(path: Path) -> Binary:
    data = path.read_bytes()
    b = Binary(path)
    if data[:4] == b"\xca\xfe\xba\xbe":  # universal (big-endian header)
        n = struct.unpack(">I", data[4:8])[0]
        for i in range(n):
            _, _, off, size, _ = struct.unpack(">IIIII", data[8 + 20 * i : 28 + 20 * i])
            b.slices.append(_parse_thin(data[off : off + size]))
    else:
        b.slices.append(_parse_thin(data))
    return b


def utf8_strings(data: bytes, min_len: int = 6) -> list[str]:
    """Printable UTF-8 runs (Swift string literals >15 bytes live in __cstring)."""
    pat = re.compile(
        rb"(?:[\x20-\x7e\t\n]|[\xc2-\xdf][\x80-\xbf]|[\xe0-\xef][\x80-\xbf]{2}|[\xf0-\xf4][\x80-\xbf]{3}){%d,}"
        % min_len
    )
    return [m.group().decode("utf-8", "replace") for m in pat.finditer(data)]


def extract_dmg(dmg: Path, dest: Path | None = None) -> Path:
    """Extract a .dmg with 7z and return the path to SmartLayout.app."""
    dest = dest or BUILD / dmg.stem
    app = dest / "SmartLayout.app"
    if app.exists() and app.stat().st_mtime >= dmg.stat().st_mtime:
        return app
    if not shutil.which("7z"):
        raise RuntimeError("нужен 7z: apt-get install -y p7zip-full (или brew install p7zip)")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    subprocess.run(["7z", "x", "-y", f"-o{dest}", str(dmg)], check=True, capture_output=True)
    # 7z writes macOS xattrs as "file:com.apple.provenance" side files; drop them.
    for junk in dest.rglob("*:com.apple.*"):
        junk.unlink()
    if not app.exists():
        found = list(dest.rglob("*.app"))
        if not found:
            raise RuntimeError(f"в {dmg} не найден .app")
        app = found[0]
    return app


def resolve_app(path: Path) -> Path:
    return extract_dmg(path) if path.suffix == ".dmg" else path


def report(app: Path) -> str:
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    exe = contents / "MacOS" / info["CFBundleExecutable"]
    b = parse_macho(exe)
    lines = [
        f"Bundle:   {info.get('CFBundleIdentifier')} {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})",
        f"Min OS:   {info.get('LSMinimumSystemVersion')}",
        f"Archs:    {', '.join(b.archs)}",
    ]
    for s in b.slices:
        kind = "ad-hoc" if s.adhoc else (f"Team {s.team_id}" if s.team_id else "unsigned")
        lines.append(
            f"  {s.arch}: signed={s.signed} ({kind}) hardened_runtime={s.hardened_runtime} minos={s.min_os}"
        )
    lines.append(f"Resources: {', '.join(sorted(p.name for p in (contents / 'Resources').iterdir()))}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if not argv:
        argv = [str(p) for p in sorted((ROOT / "dist").glob("*.dmg"))[-1:]]
    if not argv:
        print(__doc__)
        return 2
    print(report(resolve_app(Path(argv[0]))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
