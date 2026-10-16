import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "ccpm_ci.py"
SPEC = importlib.util.spec_from_file_location("ccpm_ci", MODULE_PATH)
ccpm_ci = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(ccpm_ci)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = ccpm_ci.load_manifest()

    def test_repository_manifest_is_valid(self):
        ccpm_ci.validate_manifest(self.manifest)

    def test_path_traversal_is_rejected(self):
        with self.assertRaises(ccpm_ci.ValidationError):
            ccpm_ci.safe_relative_path("../startup.lua", "source")

    def test_unnormalized_paths_are_rejected_before_pathlib_normalization(self):
        for path in ("./main.lua", "a/./main.lua", ".", "a/.", "a/", "a//b", "/a", "a/../b"):
            with self.subTest(path=path), self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.safe_relative_path(path, "target")

    def test_commit_dependencies_require_full_hex_shas(self):
        for value in ("main", "abc123", "g" * 40, "", 123, None):
            with self.subTest(value=value), self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.validate_dependency("helper", set(), {"commit": value})
        ccpm_ci.validate_dependency("helper", set(), {"commit": "ABCDEF0123" * 4})

    def test_reserved_metadata_directories_are_rejected(self):
        for target in (".complete/file.lua", ".package.json/file.lua"):
            manifest = copy.deepcopy(self.manifest)
            manifest["packages"]["ccpm-log"]["files"][0]["target"] = target
            with self.subTest(target=target), self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.validate_manifest(manifest)

    def test_symlink_files_and_directories_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repo"
            repository.mkdir()
            (repository / "real").mkdir()
            (repository / "real" / "main.lua").write_text("return true")
            try:
                (repository / "linked.lua").symlink_to("real/main.lua")
                (repository / "linked-dir").symlink_to("real", target_is_directory=True)
            except OSError as error:
                self.skipTest(f"Symlinks unavailable: {error}")
            for source in ("linked.lua", "linked-dir/main.lua"):
                manifest = {"schema": 1, "packages": {"foo": {
                    "version": "1.0.0", "kind": "program", "entrypoint": "main.lua",
                    "files": [{"source": source, "target": "main.lua"}],
                }}}
                with self.subTest(source=source), self.assertRaises(ccpm_ci.ValidationError):
                    ccpm_ci.validate_manifest(manifest, repository)

    def test_build_checks_runtime_sources_for_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            root.mkdir()
            (root / "actual.lua").write_text("return true")
            try:
                (root / "bootstrap.lua").symlink_to("actual.lua")
            except OSError as error:
                self.skipTest(f"Symlinks unavailable: {error}")
            with mock.patch.object(ccpm_ci, "ROOT", root), self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.build(self.manifest, Path(temporary) / "dist")
            self.assertFalse((Path(temporary) / "dist").exists())

    def test_schema_boolean_and_invalid_repo_dependencies_are_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["schema"] = True
        with self.assertRaises(ccpm_ci.ValidationError):
            ccpm_ci.validate_manifest(manifest)
        for repo in (False, 12, "owner/..", "../repo", "owner/a/b"):
            with self.subTest(repo=repo), self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.validate_dependency("helper", set(), {"repo": repo, "branch": "main"})
        ccpm_ci.validate_dependency("helper", set(), {"repo": "owner/.github", "branch": "main"})

    def test_hidden_sources_are_built_and_checksummed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            root.mkdir()
            for name in ("bootstrap.lua", "ccpm.lua", "startup.lua", "ccpm-package.json"):
                (root / name).write_text("example")
            (root / ".assets").mkdir()
            (root / ".assets" / "config.txt").write_bytes(b"configuration")
            manifest = {"schema": 1, "packages": {"foo": {
                "kind": "library", "version": "1.0.0",
                "files": [{"source": ".assets/config.txt", "target": "config.txt"}],
            }}}
            ccpm_ci.validate_manifest(manifest, root)
            output = Path(temporary) / "dist"
            with mock.patch.object(ccpm_ci, "ROOT", root):
                ccpm_ci.build(manifest, output)
            self.assertEqual((output / ".assets/config.txt").read_bytes(), b"configuration")
            self.assertIn("  .assets/config.txt", (output / "checksums.sha256").read_text())

    def test_conflicting_file_and_directory_targets_are_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["packages"]["ccpm-log"]["files"].append(
            {"source": "libs/ccpm/log.lua", "target": "ccpm/log.lua/more.lua"}
        )
        with self.assertRaises(ccpm_ci.ValidationError):
            ccpm_ci.validate_manifest(manifest)

    def test_missing_local_dependency_is_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["packages"]["block-checker"]["dependencies"]["missing"] = "*"
        with self.assertRaises(ccpm_ci.ValidationError):
            ccpm_ci.validate_manifest(manifest)

    def test_local_cycle_is_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["packages"]["ccpm-log"]["dependencies"]["block-checker"] = "*"
        with self.assertRaises(ccpm_ci.ValidationError):
            ccpm_ci.validate_manifest(manifest)

    def test_build_is_reproducible(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            ccpm_ci.build(self.manifest, Path(first))
            ccpm_ci.build(self.manifest, Path(second))
            first_files = {
                path.relative_to(first): path.read_bytes()
                for path in Path(first).rglob("*")
                if path.is_file()
            }
            second_files = {
                path.relative_to(second): path.read_bytes()
                for path in Path(second).rglob("*")
                if path.is_file()
            }
            self.assertEqual(first_files, second_files)

    def test_every_distributed_checksum_has_matching_file_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            ccpm_ci.build(self.manifest, output)
            for line in (output / "checksums.sha256").read_text().splitlines():
                expected, relative = line.split("  ", 1)
                with self.subTest(path=relative):
                    self.assertEqual(hashlib.sha256((output / relative).read_bytes()).hexdigest(), expected)
            for package in self.manifest["packages"].values():
                for file in package["files"]:
                    self.assertTrue((output / file["source"]).is_file())

    def test_build_rejects_file_in_nested_output_parent_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "libs").write_text("unrelated content")
            with self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.build(self.manifest, output)
            self.assertEqual((output / "libs").read_text(), "unrelated content")
            self.assertEqual(list(output.iterdir()), [output / "libs"])

    def test_build_rejects_sources_under_generated_artifact_paths(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["packages"]["ccpm-log"]["files"][0]["source"] = "index.json/helper.lua"
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.build(manifest, output)
            self.assertEqual(list(output.iterdir()), [])

    def test_release_tag_must_match_all_packages(self):
        ccpm_ci.release_check(self.manifest, "v1.0.0")
        with self.assertRaises(ccpm_ci.ValidationError):
            ccpm_ci.release_check(self.manifest, "v2.0.0")

    def test_build_rejects_directories_containing_inputs_without_deleting_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repo"
            inputs = {"bootstrap.lua", "ccpm.lua", "startup.lua", "ccpm-package.json"}
            inputs.update(
                file["source"]
                for package in self.manifest["packages"].values()
                for file in package["files"]
            )
            for relative in inputs:
                path = repository / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("original content", encoding="utf-8")
            with mock.patch.object(ccpm_ci, "ROOT", repository):
                for output in (repository, repository.parent, repository / "projects",
                               repository / "libs", repository / "dist" / ".."):
                    with self.subTest(output=output):
                        with self.assertRaises(ccpm_ci.ValidationError):
                            ccpm_ci.build(self.manifest, output)
                        for relative in inputs:
                            self.assertEqual((repository / relative).read_text(), "original content")

    def test_rebuild_preserves_unrelated_output_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            unrelated = output / "notes" / "keep.txt"
            unrelated.parent.mkdir()
            unrelated.write_text("keep me", encoding="utf-8")
            ccpm_ci.build(self.manifest, output)
            (output / "ccpm.lua").write_text("stale", encoding="utf-8")
            ccpm_ci.build(self.manifest, output)
            self.assertEqual(unrelated.read_text(), "keep me")
            self.assertEqual((output / "ccpm.lua").read_bytes(), (ccpm_ci.ROOT / "ccpm.lua").read_bytes())

    def test_build_rejects_directory_at_artifact_path_without_modifying_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "index.json").mkdir()
            with self.assertRaises(ccpm_ci.ValidationError):
                ccpm_ci.build(self.manifest, output)
            self.assertEqual(list(output.iterdir()), [output / "index.json"])


if __name__ == "__main__":
    unittest.main()
