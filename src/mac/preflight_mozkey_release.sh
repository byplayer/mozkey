#!/bin/sh
# Mozkey OSS installable preflight. Selected only by explicit release build flag.
# No removal of app, bundles, dictionaries, input sources or preferences.
set -eu
PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

_mozkey_target='@@@MOZKEY_INSTALL_VERSION@@@'
_mozkey_pkg_id='org.mozc.pkg.JapaneseInput'
_mozkey_bundle_id='org.mozc.inputmethod.Japanese'
_mozkey_app='/Library/Input Methods/Mozc.app'
_mozkey_uninstaller='/Applications/Mozc/UninstallMozc.app'

_mozkey_fail() {
  echo "Mozkey preinstall: BLOCKED: $*" >&2
  exit 1
}

_mozkey_valid_pkg_version() {
  printf '%s\n' "$1" | /usr/bin/awk -F. '
    NF != 3 { exit 1 }
    {
      for (i = 1; i <= 3; i++) {
        if ($i !~ /^[0-9]+$/ || length($i) > 3) exit 1
        if (length($i) > 1 && substr($i, 1, 1) == "0") exit 1
      }
      if (($1 + 0) < 100 || ($1 + 0) > 199 || ($2 + 0) > 99 || ($3 + 0) > 99) exit 1
    }'
}

_mozkey_not_newer() {
  /usr/bin/awk -v installed="$1" -v target="$2" 'BEGIN {
    if (split(installed, a, /[.]/) != 3 || split(target, b, /[.]/) != 3) exit 1
    for (i = 1; i <= 3; i++) {
      if (a[i] + 0 > b[i] + 0) exit 1
      if (a[i] + 0 < b[i] + 0) exit 0
    }
    exit 0
  }'
}

_mozkey_read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

# Distribution declares rootVolumeOnly; ensure package scripts cannot target a
# different volume while inspecting/modifying the running system's input method.
[ "${3:-}" = / ] || _mozkey_fail 'installation target must be the running system root'
_mozkey_valid_pkg_version "$_mozkey_target" || _mozkey_fail 'invalid embedded target version'

# Reject unexpected filesystem objects and symlink redirection, before even a
# read of the installed app's plist as the root-running installer.
for _mozkey_parent in '/Library' '/Library/Input Methods' '/Library/LaunchAgents' '/Applications' '/Applications/Mozc'; do
  if [ -L "$_mozkey_parent" ]; then
    _mozkey_fail "unexpected symlink: $_mozkey_parent"
  fi
  if [ -e "$_mozkey_parent" ] && [ ! -d "$_mozkey_parent" ]; then
    _mozkey_fail "unexpected non-directory: $_mozkey_parent"
  fi
done
for _mozkey_path in "$_mozkey_app" "$_mozkey_uninstaller"; do
  if [ -L "$_mozkey_path" ]; then
    _mozkey_fail "unexpected app symlink: $_mozkey_path"
  fi
  if [ -e "$_mozkey_path" ] && [ ! -d "$_mozkey_path" ]; then
    _mozkey_fail "unexpected app path type: $_mozkey_path"
  fi
done

# A receipt is package metadata, NOT proof that its bundle was actually updated.
# This is important for the historical skipped-component incident, when the
# receipt had advanced to 100.7.7 but the app was still Mozc 3.33.6153.
_mozkey_receipt=''
if _mozkey_receipt_info=$(/usr/sbin/pkgutil --pkg-info "$_mozkey_pkg_id" 2>/dev/null); then
  _mozkey_receipt=$(printf '%s\n' "$_mozkey_receipt_info" | /usr/bin/awk '
    /^version: / { n++; v=$2 }
    END { if (n == 1) print v }
  ')
  [ -n "$_mozkey_receipt" ] || _mozkey_fail 'unparseable existing package receipt'
else
  _mozkey_known_receipts=$(/usr/sbin/pkgutil --pkgs 2>/dev/null) || _mozkey_fail 'cannot enumerate package receipts'
  if printf '%s\n' "$_mozkey_known_receipts" | /usr/bin/grep -Fqx "$_mozkey_pkg_id"; then
    _mozkey_fail 'package receipt exists but cannot be read'
  fi
fi

if [ -n "$_mozkey_receipt" ]; then
  _mozkey_valid_pkg_version "$_mozkey_receipt" || _mozkey_fail "unknown receipt version: $_mozkey_receipt"
  _mozkey_not_newer "$_mozkey_receipt" "$_mozkey_target" || \
    _mozkey_fail "downgrade refused (receipt $_mozkey_receipt > package $_mozkey_target)"
fi

if [ ! -d "$_mozkey_app" ]; then
  # The official Mozkey uninstaller removes application files but historically
  # leaves the package receipt.  A valid receipt alone must not make a fresh
  # installation impossible.  Fail closed if any installed payload remains.
  [ ! -e "$_mozkey_uninstaller" ] || _mozkey_fail 'uninstaller exists without the main app'
  [ ! -e '/Applications/Mozc' ] || _mozkey_fail 'applications directory remains without the main app'
  for _mozkey_agent in \
    '/Library/LaunchAgents/org.mozc.inputmethod.Japanese.Converter.plist' \
    '/Library/LaunchAgents/org.mozc.inputmethod.Japanese.Renderer.plist'; do
    if [ -e "$_mozkey_agent" ] || [ -L "$_mozkey_agent" ]; then
      _mozkey_fail "launch agent remains without the main app: $_mozkey_agent"
    fi
  done
  if [ -n "$_mozkey_receipt" ]; then
    # Only recover the exact root-volume receipt for our own package.  The
    # version/downgrade policy above still applies.  Do not call --forget:
    # Installer will update the receipt after successful installation.
    printf '%s\n' "$_mozkey_receipt_info" | /usr/bin/awk '
      /^package-id: / { ids++; if ($2 != "org.mozc.pkg.JapaneseInput" || NF != 2) bad=1 }
      /^volume: / { volumes++; if ($2 != "/" || NF != 2) bad=1 }
      /^location: / { locations++; if ($2 != "/" || NF != 2) bad=1 }
      END { if (ids != 1 || volumes != 1 || locations != 1 || bad) exit 1 }
    ' || _mozkey_fail 'unexpected orphan receipt identity, volume or location'
    echo "Mozkey preinstall: ALLOW installation over verified orphan receipt $_mozkey_receipt -> $_mozkey_target"
  else
    echo "Mozkey preinstall: ALLOW clean installation of $_mozkey_target"
  fi
  exit 0
fi

_mozkey_plist="$_mozkey_app/Contents/Info.plist"
[ -f "$_mozkey_plist" ] && [ ! -L "$_mozkey_plist" ] || _mozkey_fail 'main bundle Info.plist missing or a symlink'
_mozkey_current_id=$(_mozkey_read_plist "$_mozkey_plist" CFBundleIdentifier) || _mozkey_fail 'cannot read bundle ID'
[ "$_mozkey_current_id" = "$_mozkey_bundle_id" ] || _mozkey_fail "unexpected bundle identifier: $_mozkey_current_id"
_mozkey_current_executable=$(_mozkey_read_plist "$_mozkey_plist" CFBundleExecutable) || _mozkey_fail 'cannot read bundle executable'
[ "$_mozkey_current_executable" = 'Mozc' ] || _mozkey_fail 'unexpected bundle executable name'
_mozkey_current_short=$(_mozkey_read_plist "$_mozkey_plist" CFBundleShortVersionString) || _mozkey_fail 'cannot read current short version'
_mozkey_current_build=$(_mozkey_read_plist "$_mozkey_plist" CFBundleVersion) || _mozkey_fail 'cannot read current build version'

if [ -d "$_mozkey_uninstaller" ]; then
  _mozkey_uninstaller_plist="$_mozkey_uninstaller/Contents/Info.plist"
  [ -f "$_mozkey_uninstaller_plist" ] && [ ! -L "$_mozkey_uninstaller_plist" ] || \
    _mozkey_fail 'uninstaller Info.plist missing or a symlink'
  _mozkey_uninstaller_id=$(_mozkey_read_plist "$_mozkey_uninstaller_plist" CFBundleIdentifier) || \
    _mozkey_fail 'cannot read uninstaller bundle ID'
  [ "$_mozkey_uninstaller_id" = 'org.mozc.inputmethod.Japanese.UninstallMozc' ] || \
    _mozkey_fail 'unexpected uninstaller bundle ID'
  _mozkey_uninstaller_executable=$(_mozkey_read_plist "$_mozkey_uninstaller_plist" CFBundleExecutable) || \
    _mozkey_fail 'cannot read uninstaller executable'
  [ "$_mozkey_uninstaller_executable" = 'UninstallMozc' ] || _mozkey_fail 'unexpected uninstaller executable name'
fi

# The original Mozc -> Mozkey numbering transition has a known, audited
# predecessor. Do not accept arbitrary 3.x builds as if they were older.
if [ "$_mozkey_current_short" = '3.33.6153' ] && \
   { [ "$_mozkey_current_build" = '3.33.6153.101' ] || \
     [ "$_mozkey_current_build" = '3.33.6153' ]; }; then
  [ -n "$_mozkey_receipt" ] || _mozkey_fail 'legacy app without a recognized package receipt'
  echo "Mozkey preinstall: ALLOW audited legacy Mozc 3.33.6153 migration to $_mozkey_target"
  exit 0
fi

_mozkey_valid_pkg_version "$_mozkey_current_build" || \
  _mozkey_fail "unsupported existing app version: $_mozkey_current_build"
_mozkey_derived_short=$(printf '%s\n' "$_mozkey_current_build" | /usr/bin/awk -F. '{ printf "%d.%d.%d", ($1 - 100), $2, $3 }')
[ "$_mozkey_current_short" = "$_mozkey_derived_short" ] || \
  _mozkey_fail 'installed application short/build versions disagree'
[ -n "$_mozkey_receipt" ] && [ "$_mozkey_receipt" != 0 ] || \
  _mozkey_fail 'Mozkey app exists without a current-format package receipt'
_mozkey_not_newer "$_mozkey_current_build" "$_mozkey_target" || \
  _mozkey_fail "downgrade refused (app $_mozkey_current_build > package $_mozkey_target)"


echo "Mozkey preinstall: ALLOW same-path version $_mozkey_current_build -> $_mozkey_target"
exit 0
