# Developing ccpm

For autocomplete, hover documentation and parameter hints in VS Code, see
[IntelliSense setup and Advanced Peripherals coverage](intellisense.md).

## Local API references

Requires Python 3.11 or newer. To collect documentation for an installed modpack,
run this from the repository folder on your development computer:

```powershell
python tools/fetch_docs.py --instance "C:\path\to\your\minecraft-instance"
```

The fetcher reads the instance's mod metadata, extracts bundled Lua APIs, help,
and English Patchouli pages about computer integration, and downloads selected
official documentation and API source from GitHub or GitLab at the commits
in [`sources.json`](sources.json). It never modifies the instance. The initial source list
targets FTB Skies 2: Aero 1.13.0, Minecraft 1.21.1, and NeoForge 21.1.250.

Open `.reference/index.md` for installed versions, reference paths, and coverage.
Bundled files match the installed JAR; upstream snapshots are labelled **exact
release**, **series reference**, or **unverified reference**. Detected integrations
without a curated source are listed as gaps. Original license notices are retained.

The instance path is remembered in the ignored `.reference/local.json`. After a
modpack update, refresh with:

```text
python tools/fetch_docs.py
```

Completed snapshots are checked and reused. Changed mod versions are flagged and
their old upstream pins are skipped; update [`sources.json`](sources.json) with matching
release commits before relying on those references. Failed downloads are reported
and return a nonzero exit status without replacing completed snapshots. To extract
only installed references without downloading anything:

```text
python tools/fetch_docs.py --bundled-only
```

The source list and fetcher are tracked in Git. Downloaded references, per-file
checksums, the installed-mod report, and the instance path stay in `.reference/`,
which is ignored. `AGENTS.md` points coding work to this cache.

Search the cache explicitly, including ignored files:

```text
rg --no-ignore "getEnergy" .reference/snapshots
```

## Package manifest

Packages live in `ccpm-package.json` at the repository root. A program declares an entrypoint and may depend on libraries:

```json
{
  "schema": 1,
  "packages": {
    "my-program": {
      "version": "1.0.0",
      "kind": "program",
      "requires": { "turtle": true },
      "entrypoint": "main.lua",
      "files": [
        { "source": "projects/my-program/main.lua", "target": "main.lua" }
      ],
      "dependencies": {
        "my-library": "*"
      }
    },
    "my-library": {
      "version": "1.0.0",
      "kind": "library",
      "files": [
        { "source": "libs/my-library/init.lua", "target": "my_library/init.lua" }
      ],
      "dependencies": {}
    }
  }
}
```

The program can then use normal CC:Tweaked module loading:

```lua
local library = require("my_library")
```

Dependency selectors support:

- `"*"`: the named package from the same repository and commit.
- `"1.2.3"`: the named package from the same repository's `v1.2.3` tag.
- `{ "repo": "owner/repo", "version": "1.2.3" }`: a version in another repository.
- `{ "repo": "owner/repo", "commit": "..." }`: an exact external commit.
- `{ "repo": "owner/repo", "branch": "main" }`: a branch resolved and locked during installation.

Package files are isolated under `/.ccpm/store`. `ccpm run` creates a dedicated CC:Tweaked `require` environment containing the root program and all of its resolved libraries, so library files do not need to be copied into global paths.

A dependency graph must have unique module providers. Installing two commits of the same package, or packages with overlapping module paths (including `helper.lua` versus `helper/init.lua`), is rejected before activation. Give shared modules distinct names or use the same locked dependency throughout the graph. Programs retain access to CraftOS's `shell` and `multishell` APIs. `shell.getRunningProgram()` identifies the installed entrypoint, and `arg` and varargs preserve the arguments passed to `ccpm run`.

Manifest sources must be regular files inside the repository; symbolic links and directory junctions are rejected because GitHub's raw endpoint serves link contents rather than the linked file. Version selectors must match the package's declared version. Unknown, duplicate, and incomplete command options fail before installation.


See [testing and releases](testing.md) for validation and release preparation.

The optional `requires` object currently supports only a boolean `turtle` field.
The manager validates requirements before activation and launching. Omit it for
programs that work on ordinary computers.
