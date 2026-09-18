#!/bin/bash
# ==============================================================================
# Fiwu CLI Test Suite
# Validates the behavior of the Fiwu CLI commands, including daemon
# status, configuration reading, and GUI backend toggles.
# ==============================================================================

set -e
# --- Helper Functions ---
# Print a success message with a checkmark.
ok() {
    echo -e "  \033[0;32m✓\033[0m  $1"
}

# Print a failure message and exit immediately.
fail() {
    echo -e "  \033[0;31m✗\033[0m  $1"
    exit 1
}

# Summarize the status of the Fiwu service from systemctl output.
summarize_status() {
    echo "$1" | grep -E "^\s*(Active|Loaded):" | sed 's/^\s*/     /'
}

# Detect the active configuration file path used by Fiwu.
get_config_path() {
    if [ -f "/etc/fiwu/config.json" ]; then
        echo "/etc/fiwu/config.json"
    else
        echo ""
    fi
}

# --- Test Execution ---
# 1. Check Base Usage
echo -e "\n$ fiwu"
OUTPUT=$(fiwu 2>&1); CODE=$?
if [ $CODE -eq 0 ] && echo "$OUTPUT" | grep -q "usage: fiwu"; then
    ok "$OUTPUT"
else
    fail "$OUTPUT"
fi

# 2. Check Daemon Status
echo -e "\n$ fiwu -s"
OUTPUT=$(fiwu -s 2>&1); CODE=$?
if [ $CODE -eq 0 ]; then
    ok "$(summarize_status "$OUTPUT")"
else
    fail "$OUTPUT"
fi

# 3. Check Configuration Reader
echo -e "\n$ fiwu -r"
OUTPUT=$(fiwu -r 2>&1); CODE=$?
if [ $CODE -eq 0 ] && echo "$OUTPUT" | grep -q "Configuration:" && ! echo "$OUTPUT" | grep -q "Config not found"; then
    ok "$OUTPUT"
else
    fail "$OUTPUT"
fi

# 4. Test GUI Toggle Setting
CONFIG_FILE=$(get_config_path)
for MODE in tkinter zenity; do
    echo -e "\n$ fiwu -g $MODE"
    OUTPUT=$(fiwu -g "$MODE" 2>&1); CODE=$?
    
    # Verify command succeeded, config file exists, and gui setting was updated.
    if [ $CODE -eq 0 ] && [ -n "$CONFIG_FILE" ] && grep -q "\"gui\": \"$MODE\"" "$CONFIG_FILE"; then
        ok "GUI set to $MODE successfully"
    else
        fail "Failed to update GUI setting to $MODE (Output: $OUTPUT)"
    fi
done

echo -e "\n\033[0;32mAll CLI tests passed.\033[0m"