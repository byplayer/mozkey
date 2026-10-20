# Mozkey macOS installer: isolated regression tests

The OSS macOS package has two installation gates. A normal guarded build is
**not installable**; an explicitly opted-in build uses the release preinstall
script. The underlying installation paths and package IDs intentionally retain
the original Mozc identifiers for compatibility.

## Regression test

From the repository root, run:

```sh
python3 src/mac/preflight_mozkey_release_test.py
```

Expected: `MOZKEY_PREFLIGHT_FIXTURES=27/27` and exit status 0.

The test reads `src/version.bzl` and
`src/mac/preflight_mozkey_release.sh`. Each case makes its **own temporary**
filesystem tree and runs **a transformed copy** of the preinstall script with
fake `pkgutil` and `PlistBuddy` executables. It does not require root or Bazel.
It never runs the unmodified preinstall on the host. The test aborts if
expected hard-coded paths or tool replacements cannot be recognized.

The 27 cases cover clean install, valid orphan receipts, version/downgrade
refusal (including version `0`), wrong receipt identity/volume/location,
residual app directories and LaunchAgents, symlinks, unreadable receipts,
installed-app consistency and non-root installation targets.

To save machine-readable results without modifying the repository:

```sh
python3 src/mac/preflight_mozkey_release_test.py \
  --report /tmp/mozkey_preinstall_fixture_results.json
```

**Coverage boundary:** these are synthetic preinstall decision tests, not a
replacement for macOS `pkgbuild`/`productbuild`, codesign verification, UI/TIS
checks or an actual PackageKit reinstall. They do not test the separate
postinstall legacy renderer cleanup.

## Release build safety

The Bazel rule in `src/mac/BUILD.bazel` chooses
`src/mac/preflight_mozkey_stage1.sh` for ordinary OSS builds. This blocks
installation. Only an explicit `--config=oss_macos` plus
`--define=MOZKEY_INSTALLABLE=1` selects
`src/mac/preflight_mozkey_release.sh`. Always inspect the **packaged**
preinstall script and package receipt version before distributing a new PKG.

The original compatibility IDs remain:

- App: `/Library/Input Methods/Mozc.app`
- App bundle ID: `org.mozc.inputmethod.Japanese`
- Package receipt: `org.mozc.pkg.JapaneseInput`
- Uninstaller: `/Applications/Mozc/UninstallMozc.app`

macOS 0.7.7 (internal installer version `100.7.7`) was verified on a physical
Mac in October 2026: the installer accepted a known valid orphan receipt,
rewrote the receipt and restored input and Zenz functionality. Following a
fresh GUI installation, the user's input-source menu required logout/login
before `Hiragana (Mozkey)` appeared. That is a separate known UX issue, not
a test fixture expectation.
