#!/bin/bash
set -e

echo ""

# --- Parse CLI Options ---
CLEAN_BUILD=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --clean-build|-c)
            CLEAN_BUILD=true
            ;;
        --help|-h)
            echo "Usage: $0 [--clean-build]"
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Usage: $0 [--clean-build]"
            exit 1
            ;;
    esac
    shift
done

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root (e.g., sudo ./uninstall.sh)"
  exit 1
fi

# Detect Fedora-based systems
IS_FEDORA=false
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID}" = "fedora" ] || echo "${ID_LIKE}" | grep -q "fedora"; then
    IS_FEDORA=true
  fi
fi

# Simple step runner that prints the step text and exact command output on failure.
run_step() {
    local message="$1"
    shift
    local logfile
    logfile="$(mktemp)"

    echo "${message}"

    if "$@" >"${logfile}" 2>&1; then
        rm -f "${logfile}"
        return 0
    fi

    local status=$?
    cat "${logfile}" >&2
    printf '%s failed\n' "${message}" >&2
    rm -f "${logfile}"
    return "${status}"
}

if [ "${IS_FEDORA}" = true ]; then
  # Fedora-specific uninstallation logic
  run_step "Removing Fiwu package" dnf remove -y fiwu || true

  if [ "$CLEAN_BUILD" = true ]; then
      run_step "Cleaning build tree and artifacts" bash -c "
          rm -rf build/ .pybuild/ src/*.egg-info fedora/fiwu/ fedora/.debhelper/ fedora/*.log fedora/*.debhelper fedora/*.substvars fedora/debhelper-build-stamp
      "
      run_step "Cleaning generated package files" bash -c "
          rm -f ../fiwu_*.rpm ../fiwu_*.changes ../fiwu_*.buildinfo ../fiwu-build-deps_*
          rm -f fiwu_*.rpm fiwu_*.changes fiwu_*.buildinfo fiwu-build-deps_*
      "
  fi
else
  # Ubuntu/Debian-specific uninstallation logic
  run_step "Removing Fiwu package" apt-get remove -y fiwu 2>/dev/null || true

  if [ "$CLEAN_BUILD" = true ]; then
      run_step "Purging residual configuration" apt-get purge -y fiwu 2>/dev/null || true
      run_step "Cleaning build tree and artifacts" bash -c "
          dh clean 2>/dev/null || true
          rm -rf build/ .pybuild/ src/*.egg-info debian/fiwu/ debian/.debhelper/ debian/*.log debian/*.debhelper debian/*.substvars debian/debhelper-build-stamp
      "
      run_step "Cleaning generated package files" bash -c "
          rm -f ../fiwu_*.deb ../fiwu_*.changes ../fiwu_*.buildinfo ../fiwu-build-deps_*
          rm -f fiwu_*.deb fiwu_*.changes fiwu_*.buildinfo fiwu-build-deps_*
          rm -f dist/fiwu_*.deb dist/fiwu_*.changes dist/fiwu_*.buildinfo dist/fiwu-build-deps_*
      "
  fi
fi

echo ""
echo "Fiwu uninstalled."
echo ""