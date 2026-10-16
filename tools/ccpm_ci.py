#!/usr/bin/env python3
"""Validate and build a ccpm repository without third-party dependencies."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import stat
import sys
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "ccpm-package.json"
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*/(?!\.\.?$)[A-Za-z0-9_.-]+$")


class ValidationError(ValueError):
    pass


def load_manifest(path: Path = MANIFEST) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"Cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError("Manifest root must be an object")
    return value


def safe_relative_path(value: object, field: str) -> PurePosixPath:
    if not isinstance(value, str) or not value:
        raise ValidationError(f"{field} must be a non-empty string")
    parts = value.split("/")
    if "\\" in value or any(part in {"", ".", ".."} for part in parts):
        raise ValidationError(f"{field} must be a normalized POSIX path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise ValidationError(f"{field} escapes its package: {value!r}")
    if any(not re.fullmatch(r"[A-Za-z0-9_.-]+", part) for part in path.parts):
        raise ValidationError(f"{field} contains unsupported characters: {value!r}")
    return path


def validate_source(root: Path, relative: PurePosixPath) -> Path:
    """Require real files: Git's raw endpoint does not dereference symlinks."""
    current = root
    for part in relative.parts:
        current = current / part
        try:
            info = current.lstat()
        except OSError as error:
            raise ValidationError(f"Cannot read package source {current}: {error}") from error
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
            raise ValidationError(f"Package source must not traverse a link: {current}")
    if not current.is_file() or not current.resolve().is_relative_to(root.resolve()):
        raise ValidationError(f"Package source must be a regular file inside the repository: {current}")
    return current


def validate_dependency(name: str, package_names: set[str], specification: object) -> None:
    if specification == "*":
        if name not in package_names:
            raise ValidationError(f"Local dependency {name!r} is not in this manifest")
        return
    if isinstance(specification, str):
        if not VERSION.fullmatch(specification.removeprefix("v")):
            raise ValidationError(f"Dependency {name!r} has invalid version {specification!r}")
        return
    if not isinstance(specification, dict):
        raise ValidationError(f"Dependency {name!r} must be '*', a version, or an object")
    if "repo" in specification and (not isinstance(specification["repo"], str) or not REPOSITORY.fullmatch(specification["repo"])):
        raise ValidationError(f"Dependency {name!r} has invalid repo")
    selectors = [key for key in ("branch", "version", "commit") if key in specification]
    if len(selectors) != 1:
        raise ValidationError(f"Dependency {name!r} must have exactly one selector")
    if not isinstance(specification[selectors[0]], str) or not specification[selectors[0]]:
        raise ValidationError(f"Dependency {name!r} selector must be a non-empty string")
    if "commit" in specification and not re.fullmatch(r"[0-9a-fA-F]{40}", specification["commit"]):
        raise ValidationError(f"Dependency {name!r} commit must be an exact 40-character hexadecimal SHA")
    if "version" in specification and not VERSION.fullmatch(specification["version"].removeprefix("v")):
        raise ValidationError(f"Dependency {name!r} has invalid version")


def find_local_cycles(packages: dict) -> None:
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visiting:
            raise ValidationError(f"Local dependency cycle involving {name!r}")
        if name in visited:
            return
        visiting.add(name)
        for dependency, specification in packages[name].get("dependencies", {}).items():
            if specification == "*":
                visit(dependency)
        visiting.remove(name)
        visited.add(name)

    for package_name in packages:
        visit(package_name)


def validate_manifest(manifest: dict, root: Path = ROOT) -> None:
    if type(manifest.get("schema")) is not int or manifest["schema"] != 1:
        raise ValidationError("schema must be 1")
    packages = manifest.get("packages")
    if not isinstance(packages, dict) or not packages:
        raise ValidationError("packages must be a non-empty object")
    package_names = set(packages)

    for name, package in packages.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", name):
            raise ValidationError(f"Invalid package name {name!r}")
        if not isinstance(package, dict):
            raise ValidationError(f"Package {name!r} must be an object")
        if package.get("kind") not in {"program", "library"}:
            raise ValidationError(f"Package {name!r} kind must be program or library")
        version = package.get("version")
        if not isinstance(version, str) or not VERSION.fullmatch(version):
            raise ValidationError(f"Package {name!r} has invalid semantic version")
        if package.get("kind") == "program":
            entrypoint = safe_relative_path(package.get("entrypoint"), f"{name}.entrypoint")
        else:
            entrypoint = None

        files = package.get("files")
        if not isinstance(files, list) or not files:
            raise ValidationError(f"Package {name!r} files must be a non-empty array")
        targets: set[PurePosixPath] = set()
        for index, file in enumerate(files):
            if not isinstance(file, dict):
                raise ValidationError(f"{name}.files[{index}] must be an object")
            source = safe_relative_path(file.get("source"), f"{name}.files[{index}].source")
            target = safe_relative_path(file.get("target"), f"{name}.files[{index}].target")
            if target.parts[0] in {".complete", ".package.json"}:
                raise ValidationError(f"Package {name!r} uses reserved target {target}")
            if target in targets:
                raise ValidationError(f"Package {name!r} contains duplicate target {target}")
            targets.add(target)
            validate_source(root, source)
        for target in targets:
            if any(parent in targets for parent in target.parents if str(parent) != "."):
                raise ValidationError(f"Package {name!r} has conflicting target paths at {target}")
        if entrypoint is not None and entrypoint not in targets:
            raise ValidationError(f"Package {name!r} entrypoint is not a file target")

        dependencies = package.get("dependencies", {})
        if not isinstance(dependencies, dict):
            raise ValidationError(f"Package {name!r} dependencies must be an object")
        for dependency, specification in dependencies.items():
            if not isinstance(dependency, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", dependency):
                raise ValidationError(f"Package {name!r} has an invalid dependency name")
            validate_dependency(dependency, package_names, specification)

    find_local_cycles(packages)


def release_check(manifest: dict, tag: str) -> None:
    version = tag.removeprefix("v")
    if not VERSION.fullmatch(version):
        raise ValidationError(f"Release tag must look like v1.2.3, got {tag!r}")
    mismatches = [name for name, package in manifest["packages"].items() if package["version"] != version]
    if mismatches:
        raise ValidationError(
            f"Tag {tag} does not match package version for: {', '.join(sorted(mismatches))}"
        )


def build(manifest: dict, output: Path) -> None:
    runtime_files = ("bootstrap.lua", "ccpm.lua", "startup.lua", "ccpm-package.json")
    sources = sorted(
        {
            file["source"]
            for package in manifest["packages"].values()
            for file in package["files"]
        }
    )
    checksum_files = sorted(set(runtime_files) | set(sources))
    output = output.resolve()
    for relative in checksum_files:
        validate_source(ROOT, safe_relative_path(relative, "Build source"))
        source = (ROOT / relative).resolve()
        if source == output or output in source.parents:
            raise ValidationError(f"Build output contains input file: {source}")
    if set(checksum_files) & {"checksums.sha256", "index.json"}:
        raise ValidationError("Package sources collide with generated artifact names")
    artifact_names = (*checksum_files, "checksums.sha256", "index.json")
    artifact_paths = {PurePosixPath(name) for name in artifact_names}
    if any(parent in artifact_paths for path in artifact_paths for parent in path.parents):
        raise ValidationError("Build artifact paths conflict as files and directories")
    if output.exists() and not output.is_dir():
        raise ValidationError(f"Build output is not a directory: {output}")
    for name in artifact_names:
        safe_relative_path(name, "Build source")
        target = output / name
        for parent in target.parents:
            if parent == output:
                break
            if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                raise ValidationError(f"Build target parent must be a directory, not a link or file: {parent}")
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValidationError(f"Build target must be a regular file: {target}")

    lines = []
    for relative in checksum_files:
        digest = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
        lines.append(f"{digest}  {relative}")
    # Replace only generated artifacts; never recursively delete user content.
    output.mkdir(parents=True, exist_ok=True)
    for name in checksum_files:
        (output / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, output / name)
    (output / "checksums.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")

    index = {
        "schema": 1,
        "packages": {
            name: {
                "version": package["version"],
                "kind": package["kind"],
                "description": package.get("description", ""),
            }
            for name, package in sorted(manifest["packages"].items())
        },
    }
    (output / "index.json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "build", "release-check"))
    parser.add_argument("value", nargs="?", help="Output directory or release tag")
    namespace = parser.parse_args()
    try:
        manifest = load_manifest()
        validate_manifest(manifest)
        if namespace.command == "build":
            build(manifest, Path(namespace.value or ROOT / "dist"))
        elif namespace.command == "release-check":
            if not namespace.value:
                raise ValidationError("release-check requires a tag")
            release_check(manifest, namespace.value)
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"ccpm {namespace.command}: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
