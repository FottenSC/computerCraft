import copy
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fetch_docs", ROOT / "tools" / "fetch_docs.py")
docs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(docs)


def archive_bytes(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, body in entries:
            archive.writestr(name, body)
    return buffer.getvalue()


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.instance = self.root / "instance"
        (self.instance / "mods").mkdir(parents=True)
        (self.instance / "instance.json").write_text(json.dumps({
            "name": "Test pack", "version": "1", "mcVersion": "1.21.1", "modLoader": "neoforge"
        }))
        self.jar = self.instance / "mods" / "cc-test.jar"
        with zipfile.ZipFile(self.jar, "w") as archive:
            archive.writestr("META-INF/neoforge.mods.toml", '''
[[mods]]
modId = "computercraft"
version = "1.0.0"
displayName = "Test CC"
''')
            archive.writestr(docs.LUA_ROOT + "rom/apis/example.lua", "return true")
            archive.writestr(docs.LUA_ROOT + "rom/help/example.txt", "Bundled help")
            archive.writestr("assets/test/textures/large.png", b"not documentation")
            archive.writestr("LICENSE", "Original license")
        self.source = {
            "id": "cc-test", "mod_id": "computercraft", "version": "1.0.0",
            "repository": "owner/repo", "ref": "v1.0.0", "commit": "a" * 40,
            "match": "exact release", "include": ["doc/**"],
        }
        self.configuration = {"schema": 1, "target": {"minecraft": "1.21.1", "pack_version": "1"}, "sources": [self.source]}
        self.cache = self.root / "cache"

    def test_bundled_references_preserve_licenses_and_skip_assets(self):
        files = docs.bundled_files(self.jar)
        self.assertEqual(len(files), 3)
        self.assertEqual(files["LICENSE"], b"Original license")
        self.assertNotIn("assets/test/textures/large.png", files)

    def test_unsafe_archive_paths_and_links_are_rejected(self):
        link = zipfile.ZipInfo("root/doc/link.lua")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for name in ("root/../outside.lua", "root/doc/C:\\outside.lua", "root/doc/CON.txt", link):
            with self.subTest(path=str(name)):
                with zipfile.ZipFile(io.BytesIO(archive_bytes([(name, b"content")]))) as archive:
                    with self.assertRaises(docs.ReferenceError):
                        docs.read_selected(archive, lambda _: True, strip_root=True)
        self.assertFalse((self.root / "outside.lua").exists())

    def test_case_collisions_and_large_files_are_rejected(self):
        payload = archive_bytes([("root/doc/Test.md", b"a"), ("root/doc/test.md", b"b")])
        with zipfile.ZipFile(io.BytesIO(payload)) as archive, self.assertRaises(docs.ReferenceError):
            docs.read_selected(archive, lambda _: True, strip_root=True)
        with zipfile.ZipFile(self.jar) as archive, mock.patch.object(docs, "MAX_FILE", 2):
            with self.assertRaises(docs.ReferenceError):
                docs.read_selected(archive, lambda _: True)

    def test_upstream_filters_to_api_text_and_preserves_license(self):
        payload = archive_bytes([
            ("repo-commit/doc/api.md", b"API details"),
            ("repo-commit/doc/logo.png", b"image"),
            ("repo-commit/README.md", b"Overview"),
            ("repo-commit/LICENSE", b"License"),
            ("repo-commit/unrelated.java", b"implementation"),
        ])
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = payload
        with mock.patch.object(docs.urllib.request, "urlopen", return_value=response) as request:
            files = docs.upstream_files(self.source)
        self.assertEqual(set(files), {"doc/api.md", "README.md", "LICENSE"})
        self.assertIn("/" + "a" * 40, request.call_args.args[0].full_url)

    def test_completed_snapshot_is_reused_and_corruption_is_repaired(self):
        producer = mock.Mock(return_value={"doc/api.md": b"API"})
        path, receipt = docs.snapshot(self.cache, "test", self.source, producer)
        docs.snapshot(self.cache, "test", self.source, producer)
        self.assertEqual(producer.call_count, 1)
        self.assertEqual(receipt["files"]["doc/api.md"], docs.digest(b"API"))
        (path / "doc/api.md").write_bytes(b"corrupt")
        docs.snapshot(self.cache, "test", self.source, producer)
        self.assertEqual(producer.call_count, 2)
        self.assertEqual((path / "doc/api.md").read_bytes(), b"API")
        backups = list(path.parent.glob("*.old-*"))
        self.assertEqual((backups[0] / "doc/api.md").read_bytes(), b"corrupt")

    def test_failed_refresh_preserves_previous_snapshot(self):
        path, _ = docs.snapshot(self.cache, "test", self.source, lambda: {"doc/api.md": b"API"})
        (path / "doc/api.md").write_bytes(b"previous content")
        with self.assertRaises(OSError):
            docs.snapshot(self.cache, "test", self.source, mock.Mock(side_effect=OSError("offline")))
        self.assertEqual((path / "doc/api.md").read_bytes(), b"previous content")

    def test_malformed_receipt_is_rebuilt(self):
        producer = mock.Mock(return_value={"doc/api.md": b"API"})
        path, _ = docs.snapshot(self.cache, "test", self.source, producer)
        (path / "receipt.json").write_text(json.dumps({"source": self.source, "files": "corrupt"}))
        docs.snapshot(self.cache, "test", self.source, producer)
        self.assertEqual(producer.call_count, 2)
        self.assertIsNotNone(docs.cached_snapshot(path, self.source))

    def test_changed_mod_game_or_build_skips_incompatible_upstream(self):
        for change in ("mod", "game", "build"):
            with self.subTest(change=change):
                configuration = copy.deepcopy(self.configuration)
                if change == "mod":
                    configuration["sources"][0]["version"] = "2.0.0"
                elif change == "game":
                    configuration["target"]["minecraft"] = "1.20.1"
                else:
                    configuration["sources"][0]["jar"] = "different-build.jar"
                with mock.patch.object(docs, "upstream_files") as fetch:
                    report = docs.sync(self.instance, self.cache, configuration)
                fetch.assert_not_called()
                self.assertTrue(report["sources"][0]["status"].startswith("VERSION MISMATCH"))
                self.assertIn("bundled", report["mods"][0])

    def test_refresh_is_offline_when_all_snapshots_are_complete(self):
        with mock.patch.object(docs, "upstream_files", return_value={"doc/api.md": b"API"}) as fetch:
            first = docs.sync(self.instance, self.cache, self.configuration)
            second = docs.sync(self.instance, self.cache, self.configuration)
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(first, second)
        self.assertIn("exact release", (self.cache / "index.md").read_text())

    def test_network_failure_keeps_bundled_references_and_reports_gap(self):
        original = self.jar.read_bytes()
        with mock.patch.object(docs, "upstream_files", side_effect=OSError("offline")):
            report = docs.sync(self.instance, self.cache, self.configuration)
        self.assertEqual(report["sources"][0]["status"], "FETCH FAILED")
        self.assertEqual(len(report["errors"]), 1)
        self.assertIn("bundled", report["mods"][0])
        self.assertIn("offline", (self.cache / "index.md").read_text())
        self.assertEqual(self.jar.read_bytes(), original)

    def test_empty_dependency_arrays_do_not_break_discovery(self):
        with zipfile.ZipFile(self.instance / "mods" / "other.jar", "w") as archive:
            archive.writestr("META-INF/neoforge.mods.toml", 'dependencies = []\n[[mods]]\nmodId = "other"\nversion = "1"')
        _, mods = docs.inspect_instance(self.instance, {"computercraft"})
        self.assertEqual([mod["mod_id"] for mod in mods], ["computercraft"])

    def test_nonstandard_dependency_maps_do_not_break_discovery(self):
        with zipfile.ZipFile(self.instance / "mods" / "other.jar", "w") as archive:
            archive.writestr("META-INF/neoforge.mods.toml", '[[mods]]\nmodId = "other"\nversion = "1"\n[dependencies.other]\nforge = "*"')
        _, mods = docs.inspect_instance(self.instance, {"computercraft"})
        self.assertEqual([mod["mod_id"] for mod in mods], ["computercraft"])

    def test_source_list_has_full_commit_pins_and_coverage_labels(self):
        configuration = docs.load_sources(ROOT / "docs" / "sources.json")
        self.assertGreaterEqual(len(configuration["sources"]), 4)
        for source in configuration["sources"]:
            self.assertRegex(source["commit"], r"^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
