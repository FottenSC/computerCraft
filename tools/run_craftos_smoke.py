"""Run real CraftOS-PC I/O/boot smoke tests in a disposable computer.

Only GitHub's endpoint is redirected to a local fixture HTTP server. The
emulator supplies fs, settings, JSON, shell, require, events and boot execution.
No Minecraft instance or existing emulator save is used.
"""
from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading
from html import escape
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
FIRST, SECOND = "a" * 40, "b" * 40


class Fixtures:
    commit = FIRST
    offline = False

    def payload(self, path: str) -> bytes:
        if path == "/api/releases/latest":
            return json.dumps({"tag_name": "v1.0.0", "draft": False, "prerelease": False}).encode()
        if path.startswith("/api/commits/"):
            sha = FIRST if "refs/tags/" in unquote(path) else self.commit
            return json.dumps({"sha": sha, "author": None}).encode()
        sha, relative = path.removeprefix("/raw/").split("/", 1)
        if sha not in (FIRST, SECOND):
            raise ValueError("Unknown fixture commit")
        if relative == "ccpm-package.json":
            manifest = json.loads((ROOT / relative).read_text())
            manifest["packages"].update({
                "smoke": {"version": "1.0.0", "kind": "program", "entrypoint": "main.lua",
                          "files": [{"source": "smoke.lua", "target": "main.lua"}],
                          "dependencies": {"smoke-lib": "*"}},
                "smoke-lib": {"version": "1.0.0", "kind": "library",
                              "files": [{"source": "smoke-lib.lua", "target": "smoke-lib.lua"}]},
            })
            return json.dumps(manifest).encode()
        if relative == "smoke-lib.lua":
            return b'return {write=function(path, value) local h=assert(fs.open(path,"w")); h.write(value); h.close() end}'
        if relative == "smoke.lua":
            return ('require("smoke-lib").write("/last-run", "' + sha + '")').encode()
        if relative not in {"ccpm.lua", "startup.lua", "projects/blockChecker/main.lua", "libs/ccpm/log.lua"}:
            raise ValueError("Unknown fixture source")
        return (ROOT / relative).read_bytes()


def run(craftos: Path, output: Path) -> None:
    fixtures = Fixtures()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                body = b'{"message":"offline fixture"}' if fixtures.offline else fixtures.payload(self.path)
                self.send_response(503 if fixtures.offline else 200)
            except (ValueError, OSError):
                body = b'{"message":"missing fixture"}'
                self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    output.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="ccpm-craftos-") as temporary:
            data = Path(temporary)
            computer = data / "computer" / "0"
            computer.mkdir(parents=True)
            (data / "config").mkdir()
            (data / "config" / "global.json").write_text(json.dumps({
                "checkUpdates": False, "http_blacklist": [], "http_whitelist": ["127.0.0.1"],
                "showMountPrompt": False, "standardsMode": True, "keepOpenOnShutdown": False,
            }))
            (computer / "startup.lua").write_text(
                'local h=assert(fs.open("/user-startup-ran","w")); h.write("preserved"); h.close()\n')
            for phase in ("install", "update", "offline", "recover", "uninstall"):
                fixtures.commit = FIRST if phase == "install" else SECOND
                fixtures.offline = phase == "offline"
                (computer / "smoke-config.json").write_text(json.dumps({
                    "phase": phase, "endpoint": f"http://127.0.0.1:{server.server_port}",
                    "first": FIRST, "second": SECOND,
                }))
                command = [str(craftos), "--headless", "--directory", str(data),
                           "--mount-ro", f"/repo={ROOT}", "--script", str(ROOT / "tests/craftos_smoke.lua")]
                log = output / f"{phase}.log"
                try:
                    with log.open("wb") as handle:
                        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT, timeout=45)
                except subprocess.TimeoutExpired:
                    shutil.make_archive(str(output / f"{phase}-failed-save"), "zip", data)
                    raise RuntimeError(f"CraftOS smoke timed out in {phase}; see {log}") from None
                report_path = computer / "smoke-result.json"
                report = json.loads(report_path.read_text()) if report_path.exists() else {}
                (output / f"{phase}.json").write_text(json.dumps(report, indent=2) + "\n")
                capture = computer / "terminal-capture.json"
                if capture.exists():
                    screen = json.loads(capture.read_text())
                    text = "\n".join(f'<text x="20" y="{32 + y * 20}">{escape(line.rstrip())}</text>'
                                     for y, line in enumerate(screen["lines"]) if line.strip())
                    (output / "fresh-manager.svg").write_text(
                        '<svg xmlns="http://www.w3.org/2000/svg" width="652" height="420" viewBox="0 0 652 420">'
                        '<rect width="652" height="420" rx="8" fill="#111111"/>'
                        '<g fill="#eeeeee" font-family="Consolas,monospace" font-size="18" xml:space="preserve">'
                        + text + '</g></svg>\n')
                if result.returncode or report.get("phase") != phase or not report.get("ok"):
                    shutil.make_archive(str(output / f"{phase}-failed-save"), "zip", data)
                    raise RuntimeError(f"CraftOS smoke failed in {phase}: {report}; see {log}")
                print(f"CraftOS smoke: {phase} OK ({report.get('platform')})", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--craftos", type=Path, required=True, help="CraftOS-PC executable / AppRun")
    parser.add_argument("--output", type=Path, default=ROOT / ".reference/craftos-smoke")
    options = parser.parse_args()
    run(options.craftos.resolve(), options.output.resolve())
