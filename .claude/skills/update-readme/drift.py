"""README drift: `drift.py [report]` lists what went stale, `check` validates, `stamp [--pending FILE ...]` records (SKILL.md)."""

from __future__ import annotations

import json
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
MAP = Path(__file__).with_name("map.json")
READMES = {"en": ROOT / "README.md", "ru": ROOT / "README.ru.md"}
IMAGES = ROOT / "docs" / "images" / "readme"
LOCAL = ROOT / ".local" / "readme"
SHOWN = LOCAL / "shown.json"  # what the last report listed, for `stamp`
REPORT = LOCAL / "report.md"
MAX_BYTES = 300 * 1024
PNG = b"\x89PNG\r\n\x1a\n"


def git(*args: str) -> str:
    done = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if done.returncode != 0:  # an empty answer would read as "nothing changed"
        sys.exit(f"git {' '.join(args)} failed: {done.stderr.strip()}")
    return done.stdout


def lines(*args: str) -> set[str]:
    return {line for line in git(*args).split("\n") if line}


def under(path: str, prefixes: list[str]) -> bool:
    return any(path == p or path.startswith(p.rstrip("/") + "/") for p in prefixes)


def expand(raw: dict[str, Any], paths: list[str]) -> list[str]:
    return [p.format(**raw["vars"]) for p in paths]


def entries(raw: dict[str, Any], key: str) -> list[dict[str, Any]]:
    """The `sections` or `pictures` of the map with `{var}` filled in; a picture also gets the `frame` paths."""
    extra = expand(raw, raw["frame"]) if key == "pictures" else []
    return [{**e, "paths": expand(raw, e["paths"]) + extra} for e in raw[key]]


def digest(path: str) -> str:
    return git("hash-object", path).strip() if (ROOT / path).is_file() else "deleted"


def relevant(raw: dict[str, Any], path: str) -> bool:
    return under(path, expand(raw, raw["watch"])) and not under(path, expand(raw, raw["ignore"]))


def known(ref: str) -> bool:
    done = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", ref + "^{commit}"], capture_output=True)
    return done.returncode == 0


def changed(raw: dict[str, Any], stamped: bool) -> list[str]:
    """Watched paths whose content differs from what the README was last checked against.

    That is the stamped commit for a clean file and its `seen` digest for one uncommitted at the stamp,
    so a file back at that content is not reported, and one reverted from it is."""
    names = lines("diff", "--name-only", "--no-renames", raw["synced"]) if stamped else lines("ls-files")
    names |= lines("ls-files", "--others", "--exclude-standard") | set(raw["seen"])
    return sorted(p for p in names if relevant(raw, p) and digest(p) != raw["seen"].get(p))


def report(raw: dict[str, Any]) -> str:
    stamped = known(raw["synced"])
    paths = changed(raw, stamped)
    LOCAL.mkdir(parents=True, exist_ok=True)
    head = git("rev-parse", "--short", "HEAD").strip()
    claimed = [p for e in (*entries(raw, "sections"), *entries(raw, "pictures")) for p in e["paths"]]
    unmapped = [p for p in paths if not under(p, claimed) and (ROOT / p).exists()]  # a deleted file needs no entry
    shown = {"head": head, "synced": raw["synced"], "unmapped": unmapped, "paths": {p: digest(p) for p in paths}}
    SHOWN.write_text(json.dumps(shown))
    out: list[str] = []
    if stamped:
        log = [line for line in git("log", "--oneline", f"{raw['synced']}..HEAD").split("\n") if line]
        out.append(f"COMMITS since {raw['synced']}: {len(log)}")
        out += [f"  {line}" for line in log]
    else:
        out.append(f"stamp unknown: full audit (synced={raw['synced']!r})")
    sections, pictures = entries(raw, "sections"), entries(raw, "pictures")
    out.append("SECTIONS")
    for e in sections:
        hits = [p for p in paths if under(p, e["paths"])]
        if hits:
            out.append(f"  {e['heading']} / {e['heading_ru']} <- {', '.join(hits)}")
    out.append("PICTURES")
    for e in pictures:
        hits = [p for p in paths if under(p, e["paths"])]
        why = (["pending"] if e["file"] in raw["pending"] else []) + hits
        if why:
            out.append(f"  {e['file']} ({e['kind']}, scene {e['scene']}) <- {', '.join(why)}")
    out.append("UNMAPPED")
    out += [f"  {p}" for p in unmapped]
    text = "\n".join(out) + "\n"
    REPORT.write_text(text)
    return text


def png_size(path: Path) -> tuple[int, int] | None:
    data = path.read_bytes()[:24]
    if not data.startswith(PNG) or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def readme_problems(name: str, path: Path, raw: dict[str, Any]) -> tuple[list[str], list[str]]:
    """Broken links, `<img>` without src/alt/width, missing mapped headings; and the picture sources."""
    problems: list[str] = []
    prose = re.sub(r"```.*?```", "", path.read_text(), flags=re.S)  # a fenced example may hold anything
    targets = re.findall(r"\]\(([^)\s]+)", prose)
    tags = re.findall(r"<img\b[^>]*>", prose)
    srcs = [m.group(1) for tag in tags if (m := re.search(r'\bsrc="([^"]*)"', tag))]
    for tag in tags:
        for attr in ("src", "alt", "width"):
            if not re.search(rf'\b{attr}="[^"]+"', tag):
                problems.append(f"{name}: <img> without {attr}: {tag[:80]}")
    for target in [*targets, *srcs]:
        if re.match(r"(https?:|mailto:|#)", target):
            continue
        if not (ROOT / target.split("#")[0].split("?")[0]).exists():
            problems.append(f"{name}: broken link: {target}")
    headings = set(re.findall(r"^#{1,6}\s+(.+?)\s*$", prose, flags=re.M))
    key = "heading" if name == "README.md" else "heading_ru"
    for e in raw["sections"]:
        if e[key] not in headings:
            problems.append(f"{name}: no heading «{e[key]}»")
    return problems, srcs


def site_size_problems(name: str, size: tuple[int, int]) -> list[str]:
    """The site's `<img>` and `og:image` sizes for a picture named `name` in any folder."""
    problems: list[str] = []
    named = rf'(?:^|/){re.escape(name)}$'
    for page in sorted((ROOT / "docs").rglob("*.html")):
        text, where = page.read_text(), page.relative_to(ROOT)
        for tag in re.findall(r"<img\b[^>]*>", text):
            src = re.search(r'\bsrc="([^"]*)"', tag)
            if src and re.search(named, src.group(1)):
                got = tuple(int(m.group(1)) if (m := re.search(rf'\b{a}="(\d+)"', tag)) else 0 for a in ("width", "height"))
                if got != size:
                    problems.append(f"{where}: <img> of {name} is {got[0]}x{got[1]}, not {size[0]}x{size[1]}")
        og = re.search(r'property="og:image" content="([^"]*)"', text)
        if og and re.search(named, og.group(1)):
            got = tuple(int(m.group(1)) if (m := re.search(rf'property="og:image:{a}" content="(\d+)"', text)) else 0 for a in ("width", "height"))
            if got != size:
                problems.append(f"{where}: og:image of {name} is {got[0]}x{got[1]}, not {size[0]}x{size[1]}")
    return problems


def check(raw: dict[str, Any]) -> list[str]:
    """Both READMEs resolve and show the same pictures, the pictures folder matches the map, every mapped path exists."""
    problems: list[str] = []
    used: dict[str, set[str]] = {}
    for lang, path in READMES.items():
        found, srcs = readme_problems(path.name, path, raw)
        problems += found
        used[lang] = {s.rsplit("/", 1)[-1] for s in srcs if s.startswith("docs/images/readme/")}
    for name in sorted(used["en"] ^ used["ru"]):
        problems.append(f"{name} is in one README but not the other")

    pictures = {e["file"]: e for e in raw["pictures"]}
    sizes: dict[str, dict[tuple[int, int], list[str]]] = {}
    for file in sorted(f for f in IMAGES.glob("*") if not f.name.startswith(".")):
        size = png_size(file) if file.suffix == ".png" else None
        if size is None:
            problems.append(f"{file.name} is not a PNG")
        if file.stat().st_size > MAX_BYTES:
            problems.append(f"{file.name} is {file.stat().st_size} bytes, over {MAX_BYTES}")
        if file.name not in used["en"]:
            problems.append(f"{file.name} is not used by README.md")
        if file.name not in pictures:
            problems.append(f"{file.name} has no `pictures` entry in map.json")
        else:
            if size:
                sizes.setdefault(pictures[file.name]["kind"], {}).setdefault(size, []).append(file.name)
    for kind, by_size in sizes.items():
        if len(by_size) > 1:
            problems.append(f"pictures of kind {kind} differ in size: {by_size}")
    for name in sorted(set(pictures) - set(raw["pending"])):
        if not (IMAGES / name).exists():
            problems.append(f"{name} is in map.json, not pending, and missing")
    for name in sorted(used["en"] - set(pictures)):
        problems.append(f"README.md shows {name}, which map.json does not list")
    for copy, name in raw["copies"].items():
        source = IMAGES / name
        if name not in pictures:
            problems.append(f"`copies` names {name}, which `pictures` does not list")
        if not source.is_file():
            continue  # a listed picture that is missing is reported above, a pending one is allowed
        if not (ROOT / copy).is_file() or (ROOT / copy).read_bytes() != source.read_bytes():
            problems.append(f"{copy} is not a copy of {name}")
        if size := png_size(source):
            problems += site_size_problems(Path(copy).name, size)

    mapped = [*raw["watch"], *raw["ignore"], *raw["frame"]]
    mapped += [p for key in ("sections", "pictures") for e in raw[key] for p in e["paths"]]
    for path in sorted(set(expand(raw, mapped))):
        if not (ROOT / path).exists():
            problems.append(f"map.json names {path}, which does not exist")
    for e in (*entries(raw, "sections"), *entries(raw, "pictures")):
        for path in e["paths"]:
            if not under(path, expand(raw, raw["watch"])):
                problems.append(f"map.json maps {path}, which no `watch` entry covers")
    return problems


def stamp(raw: dict[str, Any], pending: list[str]) -> None:
    """Record the commit the last report covered, the pictures still stale, and the uncommitted files it listed."""
    if not SHOWN.exists():
        sys.exit("run `drift.py` first: stamp records what the last report covered")
    shown = json.loads(SHOWN.read_text())
    if shown.get("synced") != raw["synced"]:
        sys.exit("the last report was made against another stamp: run `drift.py` again")
    if shown.get("unmapped"):
        sys.exit(f"the last report had UNMAPPED paths; map them first: {', '.join(shown['unmapped'])}")
    unknown = sorted(set(pending) - {e["file"] for e in raw["pictures"]})
    if unknown:
        sys.exit(f"--pending names pictures map.json does not list: {', '.join(unknown)}")
    dirty = lines("diff", "--name-only", "--no-renames", "HEAD") | lines("ls-files", "--others", "--exclude-standard")
    raw["synced"] = shown["head"]  # a commit made after the report is listed next time
    raw["pending"] = pending
    covered = {**raw["seen"], **shown["paths"]}  # only what a report listed, unchanged since
    raw["seen"] = {p: digest(p) for p in sorted(dirty) if relevant(raw, p) and digest(p) == covered.get(p)}
    text = MAP.read_text()
    for key in ("synced", "seen", "pending"):
        text = re.sub(rf'^  "{key}": .*$', lambda _, k=key: f'  "{k}": {json.dumps(raw[k])},', text, flags=re.M)
    MAP.write_text(text)
    SHOWN.unlink()  # one report, one stamp
    print(f"stamped {raw['synced']}; pending: {pending or 'none'}; {len(raw['seen'])} uncommitted files seen")


def main() -> int:
    raw = json.loads(MAP.read_text())
    cmd = sys.argv[1] if len(sys.argv) > 1 else "report"
    if cmd == "report":
        print(report(raw), end="")
        print(f"(written to {REPORT.relative_to(ROOT)})")
    elif cmd == "check":
        problems = check(raw)
        print("\n".join(problems) if problems else "OK")
        return 1 if problems else 0
    elif cmd == "stamp":
        rest = sys.argv[2:]
        if rest and rest[0] != "--pending":
            print(__doc__, file=sys.stderr)
            return 2
        stamp(raw, rest[1:])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
