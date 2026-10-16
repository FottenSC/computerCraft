# Contributing

This is a personal project. Bug reports and pull requests are welcome. Include `ccpm version`, `ccpm doctor`,
the command you ran, the expected result, and the actual result. State whether
this happened in Minecraft or an emulator, plus the CC:Tweaked and modpack versions.
Avoid including private repository credentials, unrelated settings, or world saves.

For changes, read [development](docs/development.md) and [testing](docs/testing.md).
Keep package downloads pinned to exact commits, preserve existing startup files,
and keep help readable on a 39x13 turtle screen. Add regression coverage for
behavioral fixes and failure/recovery paths. Follow `AGENTS.md` when using local
API references. Do not commit `.reference/`, `.settings`, or instance paths.

Run the documented checks before submitting a pull request. Describe the user
problem, resulting behavior, and validation.
