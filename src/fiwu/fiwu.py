import os
import re
import sys
import json
import signal
import atexit
import threading
import subprocess
from pathlib import Path
from netfilterqueue import NetfilterQueue

from fiwu.logger_config import logger
from fiwu.state_store import StateStore
from fiwu.packet_processor import PacketProcessor

SYSTEM_CONFIG = Path("/etc/fiwu/config.json")
DEV_CONFIG = Path(__file__).parent / "config.json"

def resolve_config_path() -> str:
    """Resolve configuration path, preferring system config over dev config."""
    if SYSTEM_CONFIG.exists():
        return str(SYSTEM_CONFIG)
    return str(DEV_CONFIG)

CONFIG_PATH = resolve_config_path()

def setup_firewall() -> None:
    """Setup iptables rules to queue traffic to NFQUEUE 1."""
    teardown_firewall()
    subprocess.run(["iptables", "-A", "OUTPUT", "-p", "tcp", "-j", "NFQUEUE", "--queue-num", "1", "--queue-bypass"], check=True)
    subprocess.run(["iptables", "-A", "OUTPUT", "-p", "udp", "-j", "NFQUEUE", "--queue-num", "1", "--queue-bypass"], check=True)
    subprocess.run(["iptables", "-A", "OUTPUT", "-p", "icmp", "-j", "NFQUEUE", "--queue-num", "1", "--queue-bypass"], check=True)


def teardown_firewall() -> None:
    """Remove iptables rules added by setup_firewall."""
    try:
        subprocess.run(["iptables", "-D", "OUTPUT", "-p", "tcp", "-j", "NFQUEUE", "--queue-num", "1", "--queue-bypass"], stderr=subprocess.DEVNULL)
        subprocess.run(["iptables", "-D", "OUTPUT", "-p", "udp", "-j", "NFQUEUE", "--queue-num", "1", "--queue-bypass"], stderr=subprocess.DEVNULL)
        subprocess.run(["iptables", "-D", "OUTPUT", "-p", "icmp", "-j", "NFQUEUE", "--queue-num", "1", "--queue-bypass"], stderr=subprocess.DEVNULL)
        subprocess.run(["iptables", "-D", "OUTPUT", "-p", "udp", "--dport", "67", "-j", "ACCEPT"], stderr=subprocess.DEVNULL)
        subprocess.run(["iptables", "-D", "OUTPUT", "!", "-o", "lo", "-j", "NFQUEUE", "--queue-num", "1", "--queue-bypass"], stderr=subprocess.DEVNULL)
    except Exception as e:
        logger.debug(f"Teardown cleanup exception: {e}")


def refresh_port_map_worker(state_store: StateStore) -> None:
    """Worker thread to update port-to-process mapping every 0.5s."""
    while True:
        try:
            out = subprocess.run(["ss", "-tupna"], capture_output=True, text=True).stdout
            new_map = {}
            for line in out.splitlines():
                if "users:" not in line:
                    continue
                cols = line.split()
                local = cols[4].rsplit(":", 1)[-1]

                # Regex to extract process name and PID from ss output format: users:(("name",pid=PID)
                match = re.search(r'users:\(\("([^"]+)",pid=(\d+)', line)
                if match and local.isdigit():
                    proc_name = match.group(1)
                    proc_pid = int(match.group(2))

                    if proc_pid == os.getpid():
                        new_map[int(local)] = "fiwu"
                    else:
                        new_map[int(local)] = proc_name
            state_store.update_port_map(new_map)
            
        except Exception as e:
            logger.debug(f"Port map refresh error: {e}")
        threading.Event().wait(0.5)


def clean_dead_processes_worker(state_store: StateStore) -> None:
    """Worker thread to clean up dead processes every 2.0s."""
    while True:
        try:
            state_store.clean_dead_processes()
        except Exception as e:
            logger.debug(f"Process cleanup thread error: {e}")
        threading.Event().wait(2.0)


def handle_sigterm(signum, frame) -> None:
    """Signal handler to tear down firewall and exit."""
    try:
        teardown_firewall()
    except Exception as e:
        logger.error(f"Error during teardown: {e}")
    finally:
        sys.exit(0)

def main() -> None:
    """Main entry point: configure GUI mode, setup firewall, and run NFQueue."""
    dev_mode = any(arg in sys.argv for arg in ["--dev", "-dev"])
    force_zenity = any(arg in sys.argv for arg in ["--zenity", "-zenity"])
    force_tk = any(arg in sys.argv for arg in ["--tk", "-tk"])

    # Config Guardrail: Check file status and mode if not explicitly overridden by CLI flags
    if not force_zenity and not force_tk:
        config_file = Path(CONFIG_PATH)
        if not config_file.exists():
            sys.exit(0)

        try:
            with open(config_file, "r") as f:
                config = json.load(f)
            mode = config.get("gui", "off")
        except Exception:
            mode = "off"

        if mode == "off":
            sys.exit(0)
        elif mode == "zenity":
            force_zenity = True
        elif mode in ["tkinter", "tk"]:
            force_tk = True
        elif mode == "dev":
            dev_mode = True

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)

    state_store = StateStore(CONFIG_PATH)
    packet_processor = PacketProcessor(
        state_store=state_store,
        dev_mode=dev_mode,
        force_zenity=force_zenity,
        force_tk=force_tk
    )

    # Start background threads
    threading.Thread(target=refresh_port_map_worker, args=(state_store,), daemon=True).start()
    threading.Thread(target=clean_dead_processes_worker, args=(state_store,), daemon=True).start()

    # Firewall setup and automatic exit teardown
    atexit.register(teardown_firewall)
    setup_firewall()

    try:
        nfqueue = NetfilterQueue()
        nfqueue.bind(1, packet_processor.process_packet)
        logger.info("Fiwu running (Service Ready)...")
        nfqueue.run()
    except KeyboardInterrupt:
        logger.info("Program stopped")
    finally:
        teardown_firewall()

if __name__ == "__main__":
    main()