#!/bin/bash
# ==============================================================================
# Fiwu Installer Script
# Automates the installation of the Fiwu on various Linux distributions.
# ==============================================================================
set -e

echo ""

# --- Parse CLI Options ---
IS_UBUNTU="${IS_UBUNTU:-auto}"
BUILD_LOCAL=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --build-local|--local|-l)
            BUILD_LOCAL=true
            ;;
        --help|-h)
            echo "Usage: $0 [--build-local]"
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Usage: $0 [--build-local]"
            exit 1
            ;;
    esac
    shift
done

# --- CI Fallback ---
if [ "${CI:-}" = "true" ]; then
    BUILD_LOCAL=true
fi

# --- Pre-flight Checks ---
if [ "$EUID" -ne 0 ] && [ -z "$CI" ]; then
  echo "Error: Please run as root (e.g., sudo ./install.sh)"
  exit 1
fi

# Delete legacy binaries
rm -f /usr/local/bin/fiwu /usr/local/bin/fiwu-daemon
rm -rf /opt/fiwu

# --- Detect Distribution ---
if [ "$IS_UBUNTU" = "auto" ]; then
    IS_UBUNTU=false
    if [ -f /etc/os-release ]; then
      . /etc/os-release
      if [ "${ID}" = "ubuntu" ] || echo "${ID_LIKE}" | grep -q "ubuntu"; then
        IS_UBUNTU=true
      fi
    fi
fi

if [ -f /etc/os-release ]; then
        . /etc/os-release
fi

IS_FEDORA=false
if [ -n "${ID}" ] && ( [ "${ID}" = "fedora" ] || echo "${ID_LIKE}" | grep -q "fedora" ); then
    IS_FEDORA=true
fi

# --- Utility: Step Runner ---
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

# --- Main Installation Branch ---
ART_DIR=""
if [ -n "${OS_TAG:-}" ] && [ -d "dist/${OS_TAG}" ]; then
    ART_DIR="dist/${OS_TAG}"
elif [ -d "dist" ]; then
    ART_DIR="dist"
fi

if [ "${IS_FEDORA}" = true ]; then
    # Fedora/RHEL Installation Path
    WHEEL_FILE=""
    [ -n "$ART_DIR" ] && WHEEL_FILE=$(ls -1 "${ART_DIR}"/*.whl 2>/dev/null | head -n 1)

    if [ -z "$WHEEL_FILE" ]; then
        if [ "$BUILD_LOCAL" = true ]; then
            run_step "Installing build dependencies" dnf install -y python3 python3-scapy python3-psutil iptables python3-devel gcc make redhat-rpm-config libnetfilter_queue-devel rpm-build python3-wheel python3-setuptools python3-pip python3-Cython python3-build || true
            run_step "Creating source sdist" python3 -m build --sdist -o dist || true

            if [ -n "$ART_DIR" ]; then
                ART_DIR="$(cd "$ART_DIR" && pwd)"
            fi

            pushd fedora >/dev/null
            bash build.sh "$ART_DIR"
            popd >/dev/null
            
            WHEEL_FILE=$(ls -1 "${ART_DIR}"/*.whl 2>/dev/null | head -n 1)
        else
            echo "Error: No pre-built package found in dist/ and --build-local was not specified during install" >&2
            echo "Fiwu is also available over PPA for LTS distributions:" >&2
            echo "  sudo add-apt-repository ppa:rnd-smile/fiwu && sudo apt-get install fiwu" >&2
            exit 1
        fi
    fi

    if [ -n "$WHEEL_FILE" ]; then
        run_step "Installing runtime dependencies" dnf install -y python3 python3-scapy python3-psutil iptables gcc python3-devel libnetfilter_queue-devel || true
        run_step "Installing NetfilterQueue via PIP" python3 -m pip install --no-deps NetfilterQueue || true
        run_step "Installing pre-built wheel" python3 -m pip install --no-deps --upgrade "$WHEEL_FILE" || true
    fi

    install -d /usr/lib/systemd/system /etc/fiwu /etc/sudoers.d /usr/share/gnome-shell/extensions/fiwu-toggle@rnd.smile.fr
    install -m 644 fiwu.service /usr/lib/systemd/system/fiwu.service
    install -m 664 src/fiwu/config.json /etc/fiwu/config.json
    ln -sf /etc/fiwu/config.json

    [ -d src/fiwu/gui/extension ] && cp -r src/fiwu/gui/extension/. /usr/share/gnome-shell/extensions/fiwu-toggle@rnd.smile.fr/
    [ -f debian/fiwu-toggle.sudoers ] && install -m 0440 debian/fiwu-toggle.sudoers /etc/sudoers.d/fiwu-toggle

    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
else
    # Debian/Ubuntu Installation Path
    if [ "$BUILD_LOCAL" = true ]; then
        # Force cleanup of stale artifacts and substvars to prevent caching upper-bound Python constraints
        rm -rf dist/fiwu_*.deb ../fiwu_*.deb ../fiwu_*.changes ../fiwu_*.buildinfo \
               debian/*.substvars debian/files debian/fiwu/ .pybuild/ src/*.egg-info/

        run_step "Updating package list" apt-get update -qq
        run_step "Installing build dependencies" bash -c "apt-get install -y build-essential devscripts equivs && mk-build-deps -i -r -t \"apt-get -y --no-install-recommends\" debian/control"
        run_step "Building Fiwu" dpkg-buildpackage -us -uc -b
        
        mkdir -p dist
        mv ../fiwu_*.deb dist/ 2>/dev/null || true
    fi

    # Find the newly built or existing package
    DEB_FILE=""
    [ -n "$ART_DIR" ] && DEB_FILE=$(ls -1 "${ART_DIR}"/*.deb 2>/dev/null | grep -v 'build-deps' | head -n 1)

    if [ -n "$DEB_FILE" ] && [ -f "$DEB_FILE" ]; then
        if [ "$BUILD_LOCAL" = true ]; then
            # Network mode: local build requested, refresh indices if needed
            sleep 3
            run_step "Installing Fiwu" apt-get install -y -o Dpkg::Options::="--force-confnew" "./$DEB_FILE"
        else
            # Offline mode: install pre-built .deb directly using dpkg without touching network
            if ! run_step "Installing Fiwu (Offline)" dpkg -i "$DEB_FILE"; then
                run_step "Resolving local dependencies" apt-get install -y -f --no-download -o Dpkg::Options::="--force-confnew"
            fi
        fi
    else
        echo "Error: No pre-built package found in dist/ and --build-local was not specified during install" >&2
        echo "Fiwu is also available over PPA for LTS distributions:" >&2
        echo "  sudo add-apt-repository ppa:rnd-smile/fiwu && sudo apt-get install fiwu" >&2
        exit 1
    fi
fi

# Pre-install script / Systemd refresh
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
    systemctl reset-failed fiwu 2>/dev/null || true
fi

# --- Cleanup ---
if [ "${CI:-}" = "true" ] && [ "${KEEP_BUILD_ARTIFACTS:-0}" = "1" ]; then
    echo "Keeping CI build artifacts for downstream jobs."
else
    run_step "Cleaning build artifacts" bash -c "rm -f ../fiwu_*.deb ../fiwu_*.changes ../fiwu_*.buildinfo ../fiwu-build-deps_* fiwu-build-deps_*"
fi

# Final messages
echo ""
echo "Fiwu has been successfully installed."
echo -e "Please run the service with \e[1mfiwu -e\e[0m or \e[1mfiwu\e[0m to see all options."
echo "Alternatively, you can also logout and log back in to use the Fiwu service extension from the system menu."
echo ""