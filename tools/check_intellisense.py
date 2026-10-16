"""Exercise AP completion, hover, signatures and diagnostics using a real LuaLS.

Runs in a temporary workspace; neither VS Code nor any Minecraft save is changed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]


class Client:
    def __init__(self, server: Path, directory: Path, settings: dict):
        self.settings = settings
        self.messages = queue.Queue()
        self.next_id = 0
        self.notifications = []
        self.errors = (directory / "server-stderr.log").open("wb")
        self.process = subprocess.Popen(
            [str(server), f"--logpath={directory / 'logs'}", f"--metapath={directory / 'meta'}"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
            cwd=server.parent,
        )
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        try:
            while True:
                length = None
                while True:
                    line = self.process.stdout.readline()
                    if not line:
                        self.messages.put(RuntimeError("LuaLS closed stdout"))
                        return
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":", 1)[1])
                    if line in (b"\r\n", b"\n") and length is not None:
                        break
                self.messages.put(json.loads(self.process.stdout.read(length)))
        except Exception as error:
            self.messages.put(error)

    def send(self, method: str, params=None, request_id=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if request_id is not None:
            message["id"] = request_id
        self.write(message)

    def write(self, message):
        body = json.dumps(message).encode()
        self.process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        self.process.stdin.flush()

    def request(self, method: str, params=None, timeout=30):
        self.next_id += 1
        request_id = self.next_id
        self.send(method, params, request_id)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            if "method" in message:
                if "id" in message:
                    result = None
                    if message["method"] == "workspace/configuration":
                        result = [self.settings if item.get("section") == "Lua" else None
                                  for item in message.get("params", {}).get("items", [])]
                    self.write({"jsonrpc": "2.0", "id": message["id"], "result": result})
                else:
                    self.notifications.append(message)
            elif message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result")
        raise TimeoutError(method)

    def close(self):
        try:
            self.request("shutdown", timeout=5)
            self.send("exit")
            self.process.wait(timeout=5)
        except (OSError, RuntimeError, TimeoutError, queue.Empty, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait(timeout=5)
        self.errors.close()

    def diagnostics(self, document, after=0, version=None):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            matches = [message["params"]["diagnostics"] for message in self.notifications[after:]
                       if message.get("method") == "textDocument/publishDiagnostics"
                       and unquote(message.get("params", {}).get("uri", "")).lower() == unquote(document["uri"]).lower()
                       and (version is None or message["params"].get("version") in (None, version))]
            if matches:
                return matches[-1]
            # A request acts as a barrier and consumes the asynchronous push
            # notifications supported by LuaLS, without asking for pull diagnostics.
            self.request("textDocument/hover", {"textDocument": document, "position": {"line": 0, "character": 0}})
            time.sleep(0.1)
        raise TimeoutError("LuaLS did not publish diagnostics")


def at(source: str, marker: str, after: bool = True) -> dict:
    offset = source.index(marker) + (len(marker) if after else 0)
    before = source[:offset]
    return {"line": before.count("\n"), "character": len(before.rsplit("\n", 1)[-1])}


def check(server: Path, core: Path):
    config = json.loads((ROOT / ".vscode/settings.json").read_text())
    libraries = [str(core) if "${addons}" in path else path.replace("${workspaceFolder}", str(ROOT))
                 for path in config["Lua.workspace.library"]]
    assert all(Path(path).is_dir() for path in libraries), "A configured library does not exist"
    settings = {key.removeprefix("Lua."): value for key, value in config.items() if key.startswith("Lua.")}
    settings.update({"workspace.library": libraries, "workspace.checkThirdParty": False,
                     "diagnostics.libraryFiles": "Enable"})
    source = '''local bridge = assert(peripheral.find("me_bridge"))
local scanner = assert(peripheral.find("geo_scanner"))
local rs = assert(peripheral.find("rs_bridge"))
local players = assert(peripheral.find("player_detector"))
local chat = assert(peripheral.find("chat_box"))
local items = bridge.getItems()
local blocks = scanner.scan(8)
local job = bridge.craftItem({name="minecraft:iron_ingot", count=2})
bridge.exportItem({name="minecraft:stone", count=16}, "up")
rs.getItems()
players.getOnlinePlayers()
chat.sendMessage("hello")
if items then print(items[1].name) end
if blocks then print(blocks[1].name) end
if job then print(job.getId()) end
turtle.inspectDown()
local monitor = assert(peripheral.find("monitor"))
monitor.write("hello")
local wrapped = assert(peripheral.wrap("back")) --[[@as AP.MEBridge]]
wrapped.getItems()
print(peripheral.getName(bridge), peripheral.getType(bridge), peripheral.hasType(bridge, "me_bridge"))
local _, another = peripheral.find("me_bridge")
if another then another.getItems() end
peripheral.find("me_bridge", function(_, candidate) return candidate.isConnected() end)
local environment = assert(peripheral.find("environment_detector"))
environment.getBiome()
local inventory = assert(peripheral.find("inventory_manager"))
inventory.getItems()
local energy = assert(peripheral.find("energy_detector"))
energy.getTransferRate()
local reader = assert(peripheral.find("block_reader"))
reader.getBlockName()
local storage = assert(peripheral.find("nbt_storage"))
storage.read()
local compass = assert(peripheral.find("compass"))
compass.getFacing()
local chunky = assert(peripheral.find("chunky"))
chunky.getConfiguration()
local colony = assert(peripheral.find("colony_integrator"))
colony.getColonyID()
'''
    with tempfile.TemporaryDirectory(prefix="ccpm-intellisense-") as temporary:
        directory = Path(temporary)
        file = directory / "example.lua"
        file.write_text(source)
        client = Client(server, directory, settings)
        try:
            client.request("initialize", {
                "processId": None, "rootUri": directory.as_uri(),
                "workspaceFolders": [{"uri": directory.as_uri(), "name": "IntelliSense smoke"}],
                "capabilities": {"workspace": {"configuration": True},
                                 "textDocument": {"completion": {"completionItem": {"snippetSupport": True}},
                                                  "hover": {"contentFormat": ["markdown", "plaintext"]},
                                                  "publishDiagnostics": {"relatedInformation": True, "versionSupport": True},
                                                  "signatureHelp": {"signatureInformation": {"parameterInformation": {"labelOffsetSupport": True}}}}},
            })
            client.send("initialized", {})
            client.send("workspace/didChangeConfiguration", {"settings": {"Lua": settings}})
            client.send("textDocument/didOpen", {"textDocument": {
                "uri": file.as_uri(), "languageId": "lua", "version": 1, "text": source}})
            document = {"uri": file.as_uri()}
            cases = [("bridge.", "getItems"), ("scanner.", "scan"), ("rs.", "getItems"),
                     ("players.", "getPlayerPos"), ("chat.", "sendMessage"),
                     ("items[1].", "count"), ("blocks[1].", "tags"), ("job.", "getId"),
                     ("turtle.", "inspectDown"), ("monitor.", "write"), ("wrapped.", "getItems"),
                     ("another.", "getItems"), ("candidate.", "getItems"),
                     ("environment.", "getBiome"), ("inventory.", "getItems"),
                     ("energy.", "getTransferRate"), ("reader.", "getBlockName"),
                     ("storage.", "writeTable"), ("compass.", "getFacing"),
                     ("chunky.", "getConfiguration"), ("colony.", "getColonyID"),
                     ("bridge.exportItem({", "fingerprint")]
            for marker, expected in cases:
                deadline = time.monotonic() + 20
                while True:
                    result = client.request("textDocument/completion", {"textDocument": document,
                        "position": at(source, marker), "context": {"triggerKind": 1}})
                    items = result.get("items", []) if isinstance(result, dict) else result or []
                    labels = {item["label"].split("(")[0].rstrip("?") for item in items}
                    if expected in labels:
                        break
                    if time.monotonic() >= deadline:
                        raise AssertionError(f"{marker}: missing {expected}; got {sorted(labels)[:40]}")
                    time.sleep(0.2)
                forbidden = {"bridge.": {"listItems", "scan", "sendMessage"},
                             "scanner.": {"getItems", "craftItem"}, "chunky.": {"getColonyID"}}
                assert not labels.intersection(forbidden.get(marker, set())), f"Unrelated methods leaked into {marker}"
                print(f"Completion {marker} -> {expected}: OK", flush=True)
            hover = client.request("textDocument/hover", {"textDocument": document,
                "position": at(source, "bridge.getItems", after=False) | {"character": len("local items = bridge.") + 2}})
            assert hover and "StoredResource" in json.dumps(hover), f"Missing hover types: {hover}"
            signature = client.request("textDocument/signatureHelp", {"textDocument": document,
                "position": at(source, 'bridge.exportItem({name="minecraft:stone", count=16}, '),
                "context": {"triggerKind": 1, "isRetrigger": False}})
            assert signature and "filter" in json.dumps(signature) and "target" in json.dumps(signature), signature
            # Check a bad radius is diagnosed instead of merely completing names.
            invalid = source.replace("scanner.scan(8)", 'scanner.scan("invalid radius")')
            after = len(client.notifications)
            client.send("textDocument/didChange", {"textDocument": {"uri": file.as_uri(), "version": 2},
                                                  "contentChanges": [{"text": invalid}]})
            diagnostics = client.diagnostics(document, after, version=2)
            assert any(item.get("code") == "param-type-mismatch" for item in diagnostics), diagnostics
            after = len(client.notifications)
            client.send("textDocument/didChange", {"textDocument": {"uri": file.as_uri(), "version": 3},
                                                  "contentChanges": [{"text": source}]})
            diagnostics = client.diagnostics(document, after, version=3)
            errors = [item for item in diagnostics if item.get("severity", 3) <= 2]
            assert not errors, f"Valid example has diagnostics: {errors}"
            print("Hover, signature help, valid example and invalid-argument diagnostics: OK", flush=True)
        finally:
            client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path, help="lua-language-server executable")
    parser.add_argument("--cc-library", required=True, type=Path, help="Installed CC:Tweaked addon library folder")
    arguments = parser.parse_args()
    check(arguments.server.resolve(), arguments.cc_library.resolve())
