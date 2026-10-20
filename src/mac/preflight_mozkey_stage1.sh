#!/bin/sh
# Mozkey.app rename stage 1: build and inspect ONLY.
# Block ALL installation until the old Mozc.app migration and IME registration
# behavior are implemented and verified on macOS.
echo "Mozkey.app stage-1 PKG is NOT INSTALLABLE: migration gate." >&2
exit 1
