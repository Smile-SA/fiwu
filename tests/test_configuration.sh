#!/bin/bash

# ── Setup Colors & Counters ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

OK=0; FAIL=0; SKIP=0
declare -A L_OK L_FAIL

# ── Helper Functions ───────────────────────────────────────────────────────────
log() { echo -e "\n${CYAN}${BOLD}── $1${NC} ${DIM}$2${NC}"; }
ok()  { ((OK++)); }
fail(){ ((FAIL++)); }
skip(){ ((SKIP++)); }

# ── Environment Setup ─────────────────────────────────────────────────────────
CONFIG_FILE="/etc/fiwu/config.json"
TEST_CONFIG_FILE="$(dirname "$0")/test_config.json"

# Replace the core configuration file with the test configuration
log "Setup" "Replacing $CONFIG_FILE with $TEST_CONFIG_FILE"
cp "$TEST_CONFIG_FILE" "$CONFIG_FILE"

# Display the updated configuration file
#log "Setup" "Displaying updated configuration file"
#cat "$CONFIG_FILE"

# ── Call test_protocols.sh ────────────────────────────────────────────────────
log "Calling test_protocols.sh"
bash "$(dirname "$0")/test_protocols.sh"