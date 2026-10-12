#!/bin/bash
set -euo pipefail

# Dependencies taken care in install.sh
ART_DIR=${1:-}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Create rpmbuild topdir inside fedora/ to avoid touching /root
RPMTOP="$SCRIPT_DIR/.rpmbuild"
mkdir -p "$RPMTOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# Copy spec into SPECS (use local copy if present)
if [ -f "$SCRIPT_DIR/SPECS/fiwu.spec" ]; then
    cp "$SCRIPT_DIR/SPECS/fiwu.spec" "$RPMTOP/SPECS/fiwu.spec"
elif [ -f "$REPO_ROOT/fiwu.spec" ]; then
    cp "$REPO_ROOT/fiwu.spec" "$RPMTOP/SPECS/fiwu.spec"
else
    echo "Error: fiwu.spec not found in $SCRIPT_DIR/SPECS or $REPO_ROOT" >&2
    exit 1
fi

# Copy sdist from repo root dist/ (created by install.sh step)
SDIST=$(ls -1 "$REPO_ROOT"/dist/*.tar.gz 2>/dev/null | head -n 1 || true)
if [ -z "$SDIST" ]; then
    echo "Error: sdist not found in dist/ (create sdist in repo root before running build)" >&2
    exit 1
fi
cp "$SDIST" "$RPMTOP/SOURCES/"

if [ ! -f "$REPO_ROOT/fiwu.service" ]; then
    echo "Error: $REPO_ROOT/fiwu.service not found" >&2
    exit 1
fi
cp "$REPO_ROOT/fiwu.service" "$RPMTOP/SOURCES/fiwu.service"

if [ ! -f "$REPO_ROOT/debian/fiwu-toggle.sudoers" ]; then
    echo "Error: $REPO_ROOT/debian/fiwu-toggle.sudoers not found" >&2
    exit 1
fi
cp "$REPO_ROOT/debian/fiwu-toggle.sudoers" "$RPMTOP/SOURCES/fiwu-toggle.sudoers"

# Build RPM using local topdir and local spec.
rpmbuild -ba --define "_topdir $RPMTOP" "$RPMTOP/SPECS/fiwu.spec"

# Install all resulting RPMs (main package + any subpackages, e.g. -devel).
shopt -s nullglob
RPM_FILES=("$RPMTOP"/RPMS/*/*.rpm)
shopt -u nullglob

if [ "${#RPM_FILES[@]}" -eq 0 ]; then
    echo "RPM build failed or no RPM produced." >&2
    exit 1
fi

dnf install -y "${RPM_FILES[@]}"

if [ -n "$ART_DIR" ]; then
    mkdir -p "$ART_DIR"
    cp "${RPM_FILES[@]}" "$ART_DIR/"
fi