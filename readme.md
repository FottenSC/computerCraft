# ccpm for CC:Tweaked

`ccpm` deploys programs and libraries from GitHub to CC:Tweaked computers. A package may follow a branch and update whenever the computer starts, or be pinned to an immutable Git commit or a version tag. Every resolved dependency is recorded at an exact commit, and an update only becomes active after every file has downloaded successfully.

## Install on a computer

Requires CC:Tweaked 1.88 or newer. The default `block-checker` program requires a turtle; run the default bootstrap there. Other programs can be installed on regular computers.

Enable the CC:Tweaked HTTP API and allow these hosts if your server uses an HTTP allow-list:

- `api.github.com`
- `raw.githubusercontent.com`

Then run:

```text
wget run https://raw.githubusercontent.com/FottenSC/computerCraft/main/bootstrap.lua
```

The bootstrap installs `block-checker`, tracks `main`, enables CraftOS startup and the package at startup, and reboots. To select another package or branch:

```text
wget run https://raw.githubusercontent.com/FottenSC/computerCraft/main/bootstrap.lua my-program stable
```

The computer retains its last working install if GitHub is unavailable or a new deployment cannot be downloaded.

To stop a running program and return to the shell, hold **Ctrl+T**. To prevent it launching again at the next boot, run `ccpm set startup off`.

## Day-to-day commands

```text
# Get help, including all options for a command.
ccpm help
ccpm help install
ccpm available --help

# Follow main. This package is checked at each reboot.
ccpm install block-checker --repo FottenSC/computerCraft --branch main --startup

# Pin to the repository-wide v1.0.0 release tag.
ccpm pin block-checker --version 1.0.0

# Pin to one exact 40-character commit.
ccpm pin block-checker --commit 0123456789abcdef0123456789abcdef01234567

# Resume following a branch.
ccpm track block-checker main

# Update now, inspect installs, or run a package manually.
ccpm update
ccpm list
ccpm run block-checker

# Control boot behavior. These persist in /.settings.
ccpm set
ccpm set auto-update on
ccpm set startup block-checker
ccpm set startup off

# Discover packages in a repository.
ccpm available --repo FottenSC/computerCraft --branch main

# Update the manager itself, or remove an installed package.
ccpm self-update
ccpm remove block-checker
```

Help and package lists pause when they fill the screen; press a key to continue. `ccpm list` shows each explicitly installed package, its repository, tracking or pinned source, and startup selection. Commit IDs are abbreviated for display. Its dependencies are managed automatically and are not listed separately.

`ccpm set` displays the startup program, automatic update setting, CraftOS startup setting, and default repository. If CraftOS startup is disabled, enable it with `set shell.allow_startup true`. Removing the startup package also disables its launch; cached files remain on disk.

The same boot settings can be managed with CraftOS's built-in `set` program:

```text
set ccpm.auto_update false
set ccpm.startup_package block-checker
```

`ccpm.auto_update` only moves branch-tracked packages. Version- and commit-pinned packages remain fixed until explicitly pinned, tracked, or reinstalled.

## Package manifest

Packages live in `ccpm-package.json` at the repository root. A program declares an entrypoint and may depend on libraries:

```json
{
  "schema": 1,
  "packages": {
    "my-program": {
      "version": "1.0.0",
      "kind": "program",
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

## Deploying commits and releases

A push to `main` is a deployment for computers tracking `main`: at their next restart they resolve the branch, download the manifest and files by the resulting immutable SHA, and atomically switch the lockfile. No server or generated registry must be hosted.

Before pushing, run the same checks as CI:

```text
python tools/ccpm_ci.py validate
python -m unittest discover -s tests -v
python tools/ccpm_ci.py build dist
```

The CI workflow validates the manifest, checks all package files, rejects dependency cycles and unsafe paths, parses every Lua file with Lua 5.2, runs repository-tool and runtime regression tests, builds checksums, and uploads an artifact including declared hidden source files. Runtime tests cover failed downloads, persistence failures, interrupted activations, dependency resolution, and program launch behavior. They run with mocks and again with pinned upstream CraftOS `cc.require`, `os.run`, rendering, and paging implementations. Terminal tests exercise 39x13 and 51x19 displays, paging cancellation, and command error reporting; platform I/O remains simulated.

To run the runtime checks locally with Lua 5.2 and `lua-cjson` installed (POSIX shell):

```sh
lua5.2 tests/ccpm_runtime_test.lua
api_dir="$(mktemp -d)"
python tools/fetch_ccpm_test_apis.py "$api_dir"
CCPM_UPSTREAM_DIR="$api_dir" lua5.2 tests/ccpm_runtime_test.lua
```

The artifact includes all manifest source files at their repository paths. Releases also include `ccpm.tar.gz`, containing the complete distribution; extract it before verifying `checksums.sha256`.

For an immutable release, update every package version in `ccpm-package.json`, commit, and tag that commit. The release workflow requires every package version to match the tag and publishes the bootstrap, manager, startup file, manifest, index, and SHA-256 checksum list:

```text
git tag v1.1.0
git push origin main v1.1.0
```

Tags are repository-wide releases. This keeps dependency resolution deterministic: `--version 1.1.0` always means the exact `v1.1.0` commit for the repository.

## Failure and rollback behavior

- Downloads go into a staging directory and receive a completion marker before activation.
- Lua files and program entrypoints are checked for syntax errors before activation.
- Repairs to an incomplete cache retain the previous directory and a recovery journal until the replacement is active. Interrupted repairs roll back when the next command loads state.
- The state file is replaced only after the full dependency graph is installed.
- Settings persistence failures are reported and restore the previous in-memory setting. A library cannot be selected as the startup program.
- A startup update failure prints an error and runs the previous locked version.
- Removing a root retains the content-addressed cache, making recovery possible without deleting unrelated packages.
- The GitHub API is only needed to resolve moving branches and tags. Package contents are always fetched by exact SHA over HTTPS.
- Named updates also preserve pinned packages. Commit selectors must be full 40-character hexadecimal SHAs.
- Downloads and installed payloads use binary mode so arbitrary file bytes are preserved on older supported CC:Tweaked versions.
- Overlapping state-changing commands are rejected with a retry message. The lock is released before running a package, on command errors, and on reboot.
- Bootstrap and self-update stage both runtime files, keep backups, and use a temporary `/startup/00-ccpm-recovery.lua` hook to restore an interrupted activation at boot. An existing `/startup` file or an unrelated file at the recovery hook path prevents runtime installation without replacing it.

The implementation targets CC:Tweaked 1.88 or newer because isolated library environments use `cc.require`.
