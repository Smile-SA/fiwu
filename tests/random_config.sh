#!/bin/bash

# Generate a randomized test configuration
cat <<EOF
{
    "default": "block",
    "ping":    { "global": "$(shuf -e allowed blocked -n 1)" },
    "dig":     { "global": "$(shuf -e allowed blocked -n 1)" },
    "curl":    { "global": "$(shuf -e allowed blocked -n 1)" },
    "openssl": { "global": "$(shuf -e allowed blocked -n 1)" },
    "nc":      { "global": "$(shuf -e allowed blocked -n 1)" },
    "nmap":    { "global": "$(shuf -e allowed blocked -n 1)" },
    "nping":   { "global": "$(shuf -e allowed blocked -n 1)" },
    "smtp":    { "global": "$(shuf -e allowed blocked -n 1)" },
    "imap":    { "global": "$(shuf -e allowed blocked -n 1)" },
    "ftp":     { "global": "$(shuf -e allowed blocked -n 1)" },
    "mqtt":    { "global": "$(shuf -e allowed blocked -n 1)" },
    "mysql":   { "global": "$(shuf -e allowed blocked -n 1)" },
    "redis":   { "global": "$(shuf -e allowed blocked -n 1)" },
    "snmp":    { "global": "$(shuf -e allowed blocked -n 1)" },
    "vpn":     { "global": "$(shuf -e allowed blocked -n 1)" }
}
EOF