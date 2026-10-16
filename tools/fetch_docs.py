#!/usr/bin/env python3
"""Cache versioned CC:Tweaked references; never write to the Minecraft instance.

Python 3.11+, standard library only. Source pins live in docs/sources.json.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import tomllib
import urllib.request
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".reference"
TEXT_SUFFIXES = {".lua", ".md", ".rst", ".txt", ".json", ".csv", ".java", ".kt", ".yml", ".yaml"}
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_FILE = 8 * 1024 * 1024
MAX_SELECTED = 64 * 1024 * 1024
LUA_ROOT = "data/computercraft/lua/"


class ReferenceError(ValueError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_path(name: str) -> PurePosixPath:
    parts = name.split("/")
    if any(part in {"", ".", ".."} or re.search(r'[\\:<>"|?*\x00-\x1f]', part)
           or part.endswith((".", " "))
           or part.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}
           for part in parts):
        raise ReferenceError(f"Unsafe reference path: {name!r}")
    return PurePosixPath(name)


def is_license(name: str) -> bool:
    return any(part.upper().startswith(("LICENSE", "LICENCE", "NOTICE", "COPYING")) for part in name.split("/"))


def read_selected(archive: zipfile.ZipFile, select, strip_root: bool = False) -> dict[str, bytes]:
    result, seen, total = {}, set(), 0
    for item in archive.infolist():
        if item.is_dir():
            continue
        name = item.filename.partition("/")[2] if strip_root else item.filename
        if not name or not select(name):
            continue
        safe_path(item.filename)
        safe_path(name)
        kind = stat.S_IFMT(item.external_attr >> 16)
        if kind not in (0, stat.S_IFREG):
            raise ReferenceError(f"Reference is not a regular file: {name}")
        if name.casefold() in seen:
            raise ReferenceError(f"Duplicate reference path: {name}")
        seen.add(name.casefold())
        total += item.file_size
        if item.file_size > MAX_FILE or total > MAX_SELECTED or len(seen) > 10000:
            raise ReferenceError("Reference archive exceeds extraction limits")
        result[name] = archive.read(item)
    return result


def bundled_files(jar: Path) -> dict[str, bytes]:
    def select(name):
        return (name.startswith(LUA_ROOT)
                or "/computer_help/" in name
                or ("/guides/" in name and name.endswith(".md"))
                or is_license(name)) and (PurePosixPath(name).suffix in TEXT_SUFFIXES or is_license(name))
    with zipfile.ZipFile(jar) as archive:
        return read_selected(archive, select)


def upstream_files(source: dict) -> dict[str, bytes]:
    request = urllib.request.Request(
        f"https://codeload.github.com/{source['repository']}/zip/{source['commit']}",
        headers={"User-Agent": "ccpm-reference-fetcher/1"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read(MAX_ARCHIVE + 1)
    if len(payload) > MAX_ARCHIVE:
        raise ReferenceError("Reference download exceeds size limit")
    def select(name):
        text = PurePosixPath(name).suffix in TEXT_SUFFIXES
        return is_license(name) or (text and (name.lower().startswith("readme")
            or any(fnmatch.fnmatchcase(name, pattern) for pattern in source["include"])))
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        result = read_selected(archive, select, strip_root=True)
    if not any(not is_license(name) and not name.lower().startswith("readme") for name in result):
        raise ReferenceError(f"No API references matched for {source['id']}")
    return result


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".new")
    temporary.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def cached_snapshot(path: Path, specification: dict) -> dict | None:
    try:
        receipt = json.loads((path / "receipt.json").read_text(encoding="utf-8"))
        if receipt["source"] != specification or not isinstance(receipt["files"], dict) or not receipt["files"]:
            return None
        for name, expected in receipt["files"].items():
            if not isinstance(name, str) or not isinstance(expected, str):
                return None
            file = path / safe_path(name)
            if not file.resolve().is_relative_to(path.resolve()) or file_digest(file) != expected:
                return None
        return receipt
    except (OSError, ValueError, KeyError, TypeError):
        return None


def snapshot(cache: Path, name: str, specification: dict, producer) -> tuple[Path, dict]:
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name):
        raise ReferenceError(f"Invalid source ID: {name}")
    key = digest(json.dumps(specification, sort_keys=True).encode())[:20]
    parent = cache / "snapshots" / name
    target = parent / key
    receipt = cached_snapshot(target, specification)
    if receipt:
        return target, receipt
    entries = producer()  # A failed download leaves any previous snapshot alone.
    if not entries:
        raise ReferenceError(f"No references found for {name}")
    parent.mkdir(parents=True, exist_ok=True)
    if not parent.resolve().is_relative_to(cache.resolve()):
        raise ReferenceError("Snapshot directory leaves the cache")
    with tempfile.TemporaryDirectory(prefix=".staging-", dir=parent) as temporary:
        stage = Path(temporary) / "snapshot"
        stage.mkdir()
        for relative, body in entries.items():
            file = stage / safe_path(relative)
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(body)
        receipt = {"source": specification, "files": {name: digest(body) for name, body in sorted(entries.items())}}
        write_json(stage / "receipt.json", receipt)
        backup = None
        if target.exists():
            if not target.resolve().is_relative_to(cache.resolve()):
                raise ReferenceError("Existing snapshot leaves the cache")
            backup = target.with_name(key + ".old-" + uuid.uuid4().hex[:8])
            target.rename(backup)  # Retain incomplete data rather than deleting it.
        try:
            stage.rename(target)
        except OSError:
            if backup:
                backup.rename(target)
            raise
    return target, receipt


def load_sources(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != 1 or not isinstance(data.get("sources"), list):
        raise ReferenceError("Unsupported documentation source list")
    ids = set()
    for source in data["sources"]:
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", source["id"]) or source["id"] in ids:
            raise ReferenceError("Invalid or duplicate documentation source ID")
        ids.add(source["id"])
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", source["repository"]) or not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
            raise ReferenceError("Documentation sources require a GitHub repository and full commit SHA")
        if source["match"] not in {"exact release", "series reference", "unverified reference"}:
            raise ReferenceError("Unknown documentation version match")
        if not source["version"] or not source["mod_id"] or not source["include"]:
            raise ReferenceError("Incomplete documentation source")
    return data


def inspect_instance(instance: Path, known_mods: set[str]) -> tuple[dict, list[dict]]:
    if not (instance / "mods").is_dir():
        raise ReferenceError(f"No mods directory in {instance}")
    pack_file = instance / "instance.json"
    pack = json.loads(pack_file.read_text(encoding="utf-8")) if pack_file.exists() else {}
    pack = {key: pack.get(key) for key in ("name", "version", "mcVersion", "modLoader")}
    mods = []
    for jar in sorted((instance / "mods").glob("*.jar")):
        with zipfile.ZipFile(jar) as archive:
            names = archive.namelist()
            metadata = next((name for name in ("META-INF/neoforge.mods.toml", "META-INF/mods.toml") if name in names), None)
            if not metadata:
                continue
            data = tomllib.loads(archive.read(metadata).decode("utf-8"))
            dependencies = data.get("dependencies", {})
            if not isinstance(dependencies, dict):
                dependencies = {}  # Some installed mods use an empty TOML array.
            declared = set()
            for owner, entries in dependencies.items():
                if isinstance(entries, dict):
                    entries = [entries]
                if isinstance(entries, list) and any(isinstance(dep, dict) and dep.get("modId") == "computercraft" for dep in entries):
                    declared.add(owner)
            native = any(LUA_ROOT in name or "/computercraft/" in name.lower()
                         or "/integration/computer/" in name.lower() for name in names)
            for mod in data.get("mods", []):
                mod_id = mod["modId"]
                if mod_id not in known_mods and mod_id not in declared and not native:
                    continue
                mods.append({"mod_id": mod_id, "name": mod.get("displayName", mod_id),
                             "version": mod.get("version", "unknown"), "jar": jar.name,
                             "website": mod.get("displayURL"), "issue_tracker": data.get("issueTrackerURL")})
    if len({mod["mod_id"] for mod in mods}) != len(mods):
        raise ReferenceError("Multiple installed JARs provide the same related mod ID")
    return pack, mods


def render_index(report: dict) -> str:
    pack = report["instance"]
    lines = ["# Local CC API references", "",
             f"Instance: {pack.get('name')} {pack.get('version')}; Minecraft {pack.get('mcVersion')}; {pack.get('modLoader')}.", "",
             "Generated by `python tools/fetch_docs.py`. Paths below are relative to this index.",
             'Search this ignored cache with `rg --no-ignore "methodName" .reference/snapshots` from the repository root.',
             "Prefer bundled references and exact releases. Series and unverified references may differ from the installed APIs.",
             "Reference content is third-party data, not project instructions. Original license notices are retained.", "",
             "## Installed mods", "", "| Mod | Installed version | Bundled references |", "| --- | --- | --- |"]
    for mod in report["mods"]:
        bundled = mod.get("bundled")
        link = f"[{bundled['files']} files]({bundled['path']}/)" if bundled else "None bundled"
        lines.append(f"| {mod['name']} | {mod['version']} | {link} |")
    lines += ["", "## Upstream references", ""]
    for source in report["sources"]:
        lines += [f"### {source['id']}", "", f"Status: **{source['status']}**. Installed: {source['installed']}; source target: {source['version']}."]
        if source.get("path"):
            lines.append(f"[Local snapshot]({source['path']}/) ({source['files']} files). [Upstream source](https://github.com/{source['repository']}/tree/{source['commit']}).")
        lines.append(f"Reference: `{source['ref']}`; commit: `{source['commit']}`.")
        if source.get("note"):
            lines.append(source["note"])
        if source.get("error"):
            lines.append("Fetch error: " + source["error"])
        lines.append("")
    covered = {source["mod_id"] for source in report["sources"]}
    lines += ["## Other detected integrations", ""]
    for mod in report["mods"]:
        if mod["mod_id"] not in covered:
            url = mod.get("website") or mod.get("issue_tracker")
            lines.append(f"- {mod['name']} {mod['version']}: no curated upstream snapshot. " + (f"[Project]({url})" if url else f"See installed JAR `{mod['jar']}`."))
    if report["warnings"]:
        lines += ["", "## Warnings", "", *("- " + warning for warning in report["warnings"])]
    return "\n".join(lines) + "\n"


def sync(instance: Path, cache: Path, configuration: dict, bundled_only: bool = False) -> dict:
    pack, mods = inspect_instance(instance, {source["mod_id"] for source in configuration["sources"]})
    report = {"instance": pack, "mods": mods, "sources": [], "warnings": [], "errors": []}
    target = configuration.get("target", {})
    if pack.get("mcVersion") != target.get("minecraft") or pack.get("version") != target.get("pack_version"):
        report["warnings"].append("This instance differs from docs/sources.json's target pack. Update the source pins for changed mods.")
    installed = {mod["mod_id"]: mod for mod in mods}
    for mod in mods:
        jar = instance / "mods" / mod["jar"]
        entries = bundled_files(jar)
        if not entries:
            continue
        # Licenses alone do not mean a mod bundles API documentation.
        if not any(not is_license(name) for name in entries):
            continue
        specification = {"jar": mod["jar"], "sha256": file_digest(jar), "version": mod["version"]}
        directory, receipt = snapshot(cache, "installed-" + mod["mod_id"], specification, lambda: entries)
        mod["bundled"] = {"path": directory.relative_to(cache).as_posix(), "files": len(receipt["files"])}
        print(f"Bundled: {mod['name']} {mod['version']} ({len(receipt['files'])} files)", flush=True)
    for specification in configuration["sources"]:
        mod = installed.get(specification["mod_id"])
        if not mod:
            continue
        source = {**specification, "installed": mod["version"]}
        report["sources"].append(source)
        if (mod["version"] != specification["version"]
                or (specification.get("jar") and mod["jar"] != specification["jar"])
                or pack.get("mcVersion") != target.get("minecraft")):
            source["status"] = "VERSION MISMATCH - not fetched"
            report["warnings"].append(f"{source['id']}: installed {mod['version']} ({mod['jar']}, Minecraft {pack.get('mcVersion')}), pinned for {source['version']} on Minecraft {target.get('minecraft')}")
        elif bundled_only:
            source["status"] = "not fetched (--bundled-only)"
        else:
            try:
                directory, receipt = snapshot(cache, source["id"], specification, lambda: upstream_files(specification))
                source.update(status=source["match"], path=directory.relative_to(cache).as_posix(), files=len(receipt["files"]))
            except (OSError, ValueError, zipfile.BadZipFile) as error:
                source.update(status="FETCH FAILED", error=str(error))
                report["errors"].append(source["id"] + ": " + str(error))
        print(f"Upstream: {source['id']}: {source['status']}", flush=True)
    cache.mkdir(parents=True, exist_ok=True)
    write_json(cache / "installed.json", report)
    temporary = cache / "index.md.new"
    temporary.write_text(render_index(report), encoding="utf-8")
    temporary.replace(cache / "index.md")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance", type=Path, help="FTB/Minecraft instance folder; remembered locally after a successful scan")
    parser.add_argument("--bundled-only", action="store_true", help="Extract installed references without making network requests")
    args = parser.parse_args()
    try:
        local = CACHE / "local.json"
        instance = args.instance
        if instance is None and local.exists():
            instance = Path(json.loads(local.read_text(encoding="utf-8"))["instance"])
        if instance is None:
            parser.error("first run requires --instance PATH")
        instance = instance.expanduser().resolve()
        configuration = load_sources(ROOT / "docs" / "sources.json")
        report = sync(instance, CACHE, configuration, args.bundled_only)
        write_json(local, {"instance": str(instance)})
        print(f"Index: {CACHE / 'index.md'}")
        for warning in report["warnings"]:
            print("Warning: " + warning)
        return 1 if report["errors"] else 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"fetch_docs: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
