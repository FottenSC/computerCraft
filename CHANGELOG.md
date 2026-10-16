# Changelog

## 1.0.0 — launch candidate, not yet published

- Manager-only bootstrap; package installation, startup selection and reboot are
  explicit choices. Turtle requirements are validated from package manifests.
- Preserve user startup files with `/startup/10-ccpm.lua`; migrate only the old
  ccpm wrapper and retain the previous runtime for recovery.
- Default to published stable releases, with explicit branch, tag and commit
  selectors for bootstrap, package installation and self-update.
- Add `version`, `info`, offline `doctor`, package `rollback`, cache `prune`,
  and manager `uninstall` commands.
- Preserve the active and previous package dependency graphs during pruning.
- Reject invalid block-checker settings before digging; avoid digging air.
- Add a real CraftOS-PC HTTP/filesystem/settings/boot smoke test to CI and gate
  draft release creation on the complete test suite. Publishing remains manual.
- Add a personal-project notice, contribution and bug-report guidance, and a user quickstart.

The Minecraft/turtle acceptance checklist in `docs/testing.md` must pass before
publishing the first stable release. Previous development builds followed `main`
and installed block-checker at boot by default.
