#!/bin/bash
# ==============================================================================
# Fiwu GNOME Extension Installation Test Suite
# Verifies that the Fiwu GNOME Shell extension is correctly installed,
# configured with the correct UUID, and associated with proper permissions.
# ==============================================================================

SUCCESS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

ok() {
    echo -e "  ${GREEN}✓${NC}  $1"
    SUCCESS=$((SUCCESS + 1))
}

fail() {
    echo -e "  ${RED}✗${NC}  $1"
    FAIL=$((FAIL + 1))
}

# Define extension identifiers and paths.
UUID="fiwu-toggle@rnd.smile.fr"
SYS_EXT_DIR="/usr/share/gnome-shell/extensions/$UUID"
SUDOERS_FILE="/etc/sudoers.d/fiwu-toggle"

echo -e "\n${CYAN}── Checking Fiwu GNOME Extension Installation${NC}\n"

# 1. Verify Extension Directory Existence
if [ -d "$SYS_EXT_DIR" ]; then
    ok "Extension installed in system directory: $SYS_EXT_DIR"
else
    fail "Extension system directory missing: $SYS_EXT_DIR"
fi

# 2. Verify Required Extension Files
for file in metadata.json extension.js; do
    if [ -f "$SYS_EXT_DIR/$file" ]; then
        ok "Found required extension file: $SYS_EXT_DIR/$file"
    else
        fail "Missing required extension file: $SYS_EXT_DIR/$file"
    fi
done

# 3. Validate Metadata UUID Consistency
if [ -f "$SYS_EXT_DIR/metadata.json" ]; then
    echo -e "${CYAN}Checking metadata.json...${NC}"
    # Extract UUID from JSON and compare with expected value.
    OUTPUT=$(python3 -c "import json; print(json.load(open('$SYS_EXT_DIR/metadata.json')).get('uuid', ''))" 2>&1)
    if [ "$OUTPUT" = "$UUID" ]; then
        ok "UUID matches: $OUTPUT"
    else
        fail "UUID mismatch in $SYS_EXT_DIR/metadata.json (Found: '$OUTPUT', Expected: '$UUID')"
    fi
else
    fail "Missing: $SYS_EXT_DIR/metadata.json"
fi

# 4. Verify Sudoers Drop-in Permissions
if [ -f "$SUDOERS_FILE" ]; then
    echo -e "${CYAN}Checking sudoers file permissions...${NC}"
    OUTPUT=$(stat -c "%a" "$SUDOERS_FILE" 2>&1)
    # Standard sudoers files require 0440 permissions for security.
    if [ "$OUTPUT" = "440" ] || [ "$OUTPUT" = "0440" ]; then
        ok "Sudoers drop-in file permissions correct (0440)"
    else
        fail "Incorrect permissions for $SUDOERS_FILE (Expected: 0440, Found: $OUTPUT)"
    fi
else
    fail "Missing: $SUDOERS_FILE"
fi

# --- Summary ---
echo -e "\n${CYAN}────────────────────────────────${NC}"
echo -e "${GREEN}Passed: $SUCCESS${NC}   ${RED}Failed: $FAIL${NC}"
echo -e "${CYAN}────────────────────────────────${NC}\n"

exit $FAIL