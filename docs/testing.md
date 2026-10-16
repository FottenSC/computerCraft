# Testing and releases

## Automated checks

Python 3.11+, Lua 5.2 and lua-cjson are required for repository tests:

```text
python -m unittest discover -s tests -v
python tools/ccpm_ci.py validate
python tools/ccpm_ci.py build dist
```

On Linux, parse project Lua only and run both runtime passes:

```sh
git ls-files -z -- '*.lua' | xargs -0 -r -n1 luac5.2 -p
lua5.2 tests/ccpm_runtime_test.lua
python tools/fetch_ccpm_test_apis.py .reference/test-apis
CCPM_UPSTREAM_DIR="$PWD/.reference/test-apis" lua5.2 tests/ccpm_runtime_test.lua
```

The mocks exercise interrupted state/cache/runtime activation, write failures,
dependencies, selectors, startup, hardware gates, rollback and pruning. The
pinned upstream pass uses actual `cc.require`, `os.run`, rendering and paging
implementations at 39x13 and 51x19 screen sizes.

CI also downloads **CraftOS-PC 2.8.3** from its official release, checks its fixed
SHA-256, and runs:

```sh
python tools/run_craftos_smoke.py --craftos /path/to/craftos
```

This creates a disposable emulator save and a local fixture HTTP server. It uses
real HTTP transport, JSON, filesystem, settings, shell, module loading and the
CraftOS boot pipeline. It checks manager-only install, preservation of an existing
startup, the computer/turtle installation gate, update, reboot, offline fallback,
rollback, pruning, interrupted runtime recovery, self-update and uninstall. The
only URL redirection maps GitHub endpoints to the local server; no public repo
contents, user saves or Minecraft instances are modified. Reports and emulator
logs go to `.reference/craftos-smoke/` locally and CI artifacts remotely.

CraftOS-PC is an emulator, and these tests do not simulate turtle digging or prove
NeoForge integration. The runtime reports a CC:Tweaked 1.112.0 feature baseline.
The Minecraft target is CC:Tweaked 1.119.0 in FTB Skies 2: Aero 1.13.0. Versions
older than the tested emulator baseline remain unverified, including the former
1.88 minimum claim.

## Minecraft acceptance before stable publication

Use a disposable test world or backed-up computer and a safe turtle test area.
Have a tester follow only the README on a fresh computer and fresh turtle.
Record the candidate commit and results on the draft release:

- [ ] Install the manager on both devices. No package launches or reboot occurs.
- [ ] Repeat with a recognizable existing `/startup.lua` and another startup
      directory script. Both remain byte-for-byte intact and run as expected.
- [ ] Browse packages on 39x13 and 51x19 screens; cancel paging with Ctrl+T.
- [ ] Reject block-checker installation on the computer with a useful message.
- [ ] Configure a turtle's protected blocks, manually run block-checker, confirm
      protected blocks remain and an unprotected block below is dug. Stop Ctrl+T.
- [ ] Select startup, reboot, confirm it launches; disable it and reboot again.
- [ ] Install/update at exact candidate commits, verify dependencies and settings.
- [ ] Disconnect HTTP, reboot, and confirm the cached program still runs.
- [ ] Roll back offline, reboot, and confirm the pinned previous version runs.
- [ ] Preview/prune the cache; confirm active and previous installs still run.
- [ ] Self-update using an explicit candidate commit. Confirm existing startup
      scripts survive. Verify previous runtime backups and `doctor` output.
- [ ] Remove the package, then uninstall ccpm; confirm unrelated startup and
      settings survive. Reinstall successfully using the retained cache.

An existing startup program that never returns runs before ccpm. Test this case
and confirm `doctor` explains the ordering; ccpm deliberately preserves that app.

## Prepare and publish a release

Keep `local VERSION` in `ccpm.lua` and all package versions in
`ccpm-package.json` equal to the planned tag, without its `v` prefix. Update the
changelog and candidate installation instructions. `release-check` validates
manager/package version agreement:

```text
python tools/ccpm_ci.py release-check v1.0.0
```

Use a prerelease version such as `1.0.0-rc.1` for public acceptance builds and
update all versions to match before creating its tag. Never move a published tag.

Tagging a version triggers the same complete CI checks as a main-branch push,
including the real emulator smoke test. Only after those checks pass does the
release workflow download the tested artifact, verify its checksums, archive the
complete distribution and create a **draft**, with prerelease status for `-rc`
tags. It does not publish or make a release latest automatically.

Finish the Minecraft checklist on that exact commit. Publish acceptance builds
as prereleases. Once the checklist passes on the final stable commit, publish
the stable draft and mark it latest in GitHub. Then replace the README's candidate
notice with the stable quickstart. Default clients resolve GitHub's latest
published stable release; unpublished drafts, prereleases and arbitrary pushes
to main do not advance that channel. Users who explicitly track main still
receive branch changes at their next update or boot.

The archive contains all runtime and declared package source files,
an index, and `checksums.sha256`. Extract it and run `sha256sum --check
checksums.sha256` to verify downloads. Checksums provide integrity for the
distribution; runtime GitHub downloads use HTTPS and immutable commit paths.
