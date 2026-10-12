#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:-}"
case "$INPUT" in
  22.04|ubuntu22.04|jammy)
    DISTRO=jammy
    ;;
  24.04|ubuntu24.04|noble)
    DISTRO=noble
    ;;
  26.04|ubuntu26.04|oracular|resolute)
    # accept both oracular/resolute aliases
    DISTRO=oracular
    ;;
  *)
    echo "Usage: $0 <22.04|24.04|26.04|jammy|noble|oracular|resolute>" >&2
    exit 2
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends devscripts dput gnupg ca-certificates

BASE_VER="$(dpkg-parsechangelog -S Version)"
REMOTE_VER="$(apt-cache madison fiwu 2>/dev/null | awk '{print $3}' | head -n 1 || true)"

NEXT_VER="$(python3 - "$BASE_VER" "$REMOTE_VER" <<'PY'
import re, sys
base = sys.argv[1].strip()
remote = (sys.argv[2] or '').strip()
source = remote if remote else base
nums = [int(n) for n in re.findall(r"\d+", source)]
if len(nums) >= 4:
    a, b, c, d = nums[:4]
    if d >= 9:
        next_ver = f"{a}.{b}.{c + 1}"
    else:
        next_ver = f"{a}.{b}.{c}.{d + 1}"
elif len(nums) >= 3:
    a, b, c = nums[:3]
    if c >= 9:
        next_ver = f"{a}.{b + 1}.0"
    else:
        next_ver = f"{a}.{b}.{c + 1}"
else:
    next_ver = base
print(next_ver)
PY
)"

echo "Remote version: ${REMOTE_VER:-${BASE_VER}}"
echo "Next version: ${NEXT_VER}"

# Keep the changelog in the source tree for the selected Ubuntu release.
dch --newversion "${NEXT_VER}" --distribution "$DISTRO" --urgency high "Automated PPA release bump for Ubuntu ${DISTRO}"

debuild -S -sa

CHANGE_FILE="$(ls -t "$REPO_ROOT"/../fiwu_*_source.changes 2>/dev/null | head -n 1 || true)"
if [ -z "$CHANGE_FILE" ]; then
  echo "No source changelog artifact found after debuild" >&2
  exit 1
fi

dput ppa:rnd-smile/fiwu "$CHANGE_FILE"
