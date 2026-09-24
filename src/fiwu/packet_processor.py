import threading
import subprocess
from scapy.all import IP, TCP, UDP, ICMP

from fiwu.logger_config import logger
from fiwu.state_store import StateStore
from fiwu.gui.dialogs import ask_user_gui

# Internal processes that get ignored
INTERNAL_PROCESSES = {"systemd-run", "fiwu"}

def kill_active_connections(service_name: str, dst_ip: str | None = None) -> None:
    """Immediately close active connections for a specific service.
    
    If dst_ip is provided, only closes connections to that specific IP.
    Otherwise, closes all connections for the process.
    """
    try:
        # Query current active sockets
        result = subprocess.run(["ss", "-tupn"], capture_output=True, text=True)
        
        for line in result.stdout.splitlines():
            # Filter lines belonging to the target service
            if f'("{service_name}"' not in line:
                continue
                
            cols = line.split()
            local_addr = cols[4]
            peer_addr = cols[5]

            # If specific destination IP is required, filter by it
            if dst_ip:
                peer_ip = peer_addr.rsplit(":", 1)[0]
                if peer_ip != dst_ip:
                    continue

            # Kill the socket immediately
            subprocess.run(
                ["ss", "-K", f"src {local_addr}", f"dst {peer_addr}"], 
                stderr=subprocess.DEVNULL
            )
        logger.info(f"Connections for {service_name} {'to ' + dst_ip if dst_ip else ''} cut immediately.")
    except Exception as e:
        logger.debug(f"Error cutting active connections for {service_name}: {e}")


class PacketProcessor:
    """Handles incoming network packets from NetfilterQueue.
    
    Evaluates rules against configuration and manages user prompts for new services.
    """
    def __init__(
        self, 
        state_store: StateStore, 
        dev_mode: bool = False, 
        force_zenity: bool = False, 
        force_tk: bool = False
    ):
        self.state_store = state_store
        self.dev_mode = dev_mode
        self.force_zenity = force_zenity
        self.force_tk = force_tk

    def handle_new_service_async(
        self, 
        service_name: str, 
        dst_ip: str, 
        port: int | None
    ) -> None:
        """Async handler for displaying UI prompts for new services.
        
        Coordinates with the state store to manage locking and rule updates.
        """
        prompt_key = f"{service_name}:{dst_ip}"

        try:
            # Check if a global rule already exists to avoid redundant popups
            current_cfg = self.state_store.get_config()
            if (
                service_name in current_cfg 
                and isinstance(current_cfg[service_name], dict) 
                and current_cfg[service_name].get(":all")
            ):
                logger.debug(f"[QUEUE SKIP] Global rule already exists for {service_name}. Silent pass.")
                return

            # Acquire UI lock to ensure only one popup is displayed at a time
            with self.state_store.ui_lock:
                # Double-check config in case it changed while waiting for lock
                current_cfg = self.state_store.get_config()
                if (
                    service_name in current_cfg 
                    and isinstance(current_cfg[service_name], dict) 
                    and current_cfg[service_name].get(":all")
                ):
                    return

                logger.info(f"\n[?] POPUP IN PROGRESS : {service_name} -> {dst_ip}")
                
                # Launch GUI dialog
                return_code = ask_user_gui(
                    service_name, dst_ip, port,
                    force_zenity=self.force_zenity,
                    force_tk=self.force_tk,
                    gui_engine_pref=current_cfg.get("gui", "tkinter").lower()
                )

                # Handle One-Time (Memory) Rules
                if return_code in [2, 3]:
                    is_allow = (return_code == 2)
                    self.state_store.add_transient_rule(service_name, dst_ip, allow=is_allow)
                    status_word = "allowed" if is_allow else "blocked"
                    logger.info(f"[{'+' if is_allow else '-'}] {service_name} -> {dst_ip} temporarily {status_word}")
                    
                    if not is_allow:
                        kill_active_connections(service_name, dst_ip)

                # Handle Permanent (Config JSON) Rules
                else:
                    status_str = "allowed" if return_code in [0, 4] else "blocked"
                    apply_to_all = return_code in [4, 5]

                    current_config = self.state_store.get_config().copy()
                    
                    if apply_to_all:
                        # Initialize structure if needed
                        if service_name not in current_config or isinstance(current_config[service_name], str):
                            current_config[service_name] = {}                   
                        current_config[service_name]["global"] = status_str
                        current_config[service_name][":all"] = True
                    else:
                        # Handle legacy string-based rules
                        if service_name not in current_config:
                            current_config[service_name] = {}
                        elif isinstance(current_config[service_name], str):
                            prev_global = current_config[service_name]
                            current_config[service_name] = {"global": prev_global}

                        current_config[service_name][dst_ip] = status_str

                    # Kill connections if blocking
                    if status_str == "blocked":
                        kill_active_connections(service_name, None if apply_to_all else dst_ip)

                    # Persist changes
                    if self.state_store.save_config(current_config):
                        all_ips_label = "all_ips=True" if apply_to_all else "all_ips=False"
                        logger.info(f"[{'+' if status_str == 'allowed' else '-'}] {service_name} recorded ('{status_str}', {all_ips_label}) in config.json")

        except Exception as e:
            logger.error(f"Error handling new service async for {service_name}: {e}", exc_info=True)
        finally:
            self.state_store.release_prompt(prompt_key)

    def process_packet(self, packet: object) -> None:
        """Main entry point for processing network packets.
        
        Extracts details, checks rules (temporary then permanent), 
        and decides whether to accept or drop the packet.
        """
        current_config = self.state_store.get_config()

        # Parse Scapy packet layers
        scapy_packet = IP(packet.get_payload())
        if not scapy_packet.haslayer(IP):
            packet.accept()
            return

        dst_ip = scapy_packet[IP].dst
        protocol = "OTHER"
        port, local_port = None, None

        # Extract protocol details
        if scapy_packet.haslayer(TCP):
            protocol, port, local_port = "TCP", scapy_packet[TCP].dport, scapy_packet[TCP].sport
        elif scapy_packet.haslayer(UDP):
            protocol, port, local_port = "UDP", scapy_packet[UDP].dport, scapy_packet[UDP].sport
        elif scapy_packet.haslayer(ICMP):
            protocol = "ICMP"

        # Identify the process/service by local port
        service_name = "Unknown"
        if protocol in ["TCP", "UDP"]:
            service_name = self.state_store.get_service_for_port(local_port)
        elif protocol == "ICMP" and scapy_packet[ICMP].type == 8:
            service_name = "ping"

        # Allow traffic for internal system processes
        if service_name in INTERNAL_PROCESSES:
            packet.accept()
            return

        action = None

        # --- Rule Matching ---

        # 1. Temporary session rules (Live Memory)
        action = self.state_store.check_transient_rule(service_name, dst_ip)

        # 2. Permanent rules (Config JSON)
        if action is None and service_name in current_config:
            service_rule = current_config[service_name]

            if isinstance(service_rule, str):
                action = "DROP" if service_rule == "blocked" else "ACCEPT"
            elif isinstance(service_rule, dict):
                # Global policy takes precedence over individual IP entries
                if "global" in service_rule:
                    action = "DROP" if service_rule["global"] == "blocked" else "ACCEPT"
                elif dst_ip in service_rule:
                    action = "DROP" if service_rule[dst_ip] == "blocked" else "ACCEPT"

        # --- New Service Handling ---
        
        prompt_key = f"{service_name}:{dst_ip}"
        if action is None and service_name != "Unknown":
            if self.dev_mode:
                # In dev mode, bypass UI and strictly follow default policy
                default_policy = current_config.get("default", "allow").lower()
                action = "ACCEPT" if default_policy == "allow" else "DROP"
            else:
                # Try to claim the prompt key (ensure unique popup)
                if self.state_store.claim_prompt(prompt_key):
                    threading.Thread(
                        target=self.handle_new_service_async, 
                        args=(service_name, dst_ip, port), 
                        daemon=True
                    ).start()

                # Drop packet while waiting for user decision
                action = "DROP"
                logger.info(f"[!] WAITING : Packet for {service_name} -> {dst_ip} ignored pending your decision.")

        # --- Final Fallback ---
        
        if action is None:
            if self.dev_mode:
                default_policy = current_config.get("default", "allow").lower()
                action = "DROP" if default_policy in ["block", "blocked", "drop"] else "ACCEPT"
            else:
                # Default to allowing unknown internal processes, blocking external ones
                action = "ACCEPT" if service_name == "Unknown" else "DROP"

        logger.info(f"{'[OK]' if action == 'ACCEPT' else '[!!!] BLOCKED'} | Process: {service_name} | Dest: {dst_ip}:{port} | Proto: {protocol}")

        # Apply Action
        if action == "DROP":
            packet.drop()
        else:
            packet.accept()