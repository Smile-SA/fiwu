import threading
import socket
import time
import json
import os
import re
import subprocess
from pyroute2.netlink import NLM_F_REQUEST
from pyroute2.netlink.diag import DiagSocket
import pyroute2.netlink.diag as diag_module

from fiwu.logger_config import logger

# Dynamically resolve the correct kernel struct based on the installed library version
InetDiagReq = getattr(diag_module, 'inet_diag_req_v2', getattr(diag_module, 'inet_diag_req', None))

_recent_pids = []  # pids that recently owned a socket; checked first

def _tcp_inode(src_ip: str, sport: int, dst_ip: str, dport: int) -> int:
    """Exact IPv4 TCP 4-tuple lookup via pyroute2. Returns inode or 0."""
    try:
        with DiagSocket() as diag:
            msg = InetDiagReq()
            msg['idiag_family'] = socket.AF_INET
            msg['idiag_protocol'] = socket.IPPROTO_TCP
            msg['idiag_states'] = 0xFFF
            msg['idiag_id']['idiag_sport'] = sport
            msg['idiag_id']['idiag_dport'] = dport
            msg['idiag_id']['idiag_src'] = src_ip
            msg['idiag_id']['idiag_dst'] = dst_ip
            
            # Send an exact match request (NLM_F_REQUEST without NLM_F_DUMP)
            replies = diag.nlm_request(msg, 20, NLM_F_REQUEST)
            for reply in replies:
                if reply['header']['type'] == 20:
                    return reply.get('idiag_inode', 0)
    except Exception:
        pass
    return 0


def _pid_owns(pid: int, target: str) -> bool:
    try:
        for fd in os.listdir(f"/proc/{pid}/fd"):
            try:
                if os.readlink(f"/proc/{pid}/fd/{fd}") == target:
                    return True
            except OSError:
                continue
    except OSError:
        pass
    return False


def lookup_tcp_owner(src_ip: str, sport: int, dst_ip: str, dport: int) -> str | None:
    """Resolve the process name owning an IPv4 TCP flow without forking. None if unknown."""
    inode = _tcp_inode(src_ip, sport, dst_ip, dport)
    if not inode:  # not found, or TIME_WAIT (inode 0)
        return None
    target = f"socket:[{inode}]"
    candidates = list(_recent_pids)
    candidates += [int(p) for p in os.listdir("/proc") if p.isdigit() and int(p) not in candidates]
    for pid in candidates:
        if _pid_owns(pid, target):
            if pid in _recent_pids:
                _recent_pids.remove(pid)
            _recent_pids.insert(0, pid)
            del _recent_pids[32:]
            if pid == os.getpid():
                return "fiwu"
            try:
                with open(f"/proc/{pid}/comm") as f:
                    return f.read().strip()
            except OSError:
                return None
    return None

class StateStore:
    """Manages persistent configuration and transient state for the firewall.
    
    Handles port-to-process mapping, rule caching, and UI interaction locks.
    Thread-safe via internal locking mechanisms.
    """

    def __init__(self, config_path: str):
        self.config_path = config_path
        self._data_lock = threading.Lock()
        self._ui_lock = threading.Lock()

        # Encapsulated state
        self.port_map = {}
        self.pending_prompts = set()
        self.one_time_allow = set()
        self.one_time_block = set()
        self.cached_config = {}
        self.last_config_mtime = 0
        self._miss_until = {}  # port -> monotonic time until which a failed lookup is not retried
    # --- Port Mapping ---
    def update_port_map(self, new_map: dict) -> None:
        """Atomically replace the current port-to-process mapping."""
        with self._data_lock:
            self.port_map = new_map.copy()

    def get_service_for_port(self, local_port: int, flow: tuple | None = None) -> str:
        """Retrieve the process name associated with a local port.
        
        Checks in-memory map first, then falls back to querying `ss` if missing.
        Returns 'Unknown' if no service is found or an error occurs.
        """
        if not local_port:
            return "Unknown"

        with self._data_lock:
            if local_port in self.port_map:
                return self.port_map[local_port]

        # Fast path: exact netlink lookup for IPv4 TCP, no fork
        if flow:
            name = lookup_tcp_owner(flow[0], local_port, flow[1], flow[2])
            if name:
                with self._data_lock:
                    self.port_map[local_port] = name
                return name

        # Recently failed lookup: don't fork ss again for this port
        if self._miss_until.get(local_port, 0) > time.monotonic():
            return "Unknown"

        # Fallback: Query system sockets directly via ss command
        try:
            result = subprocess.run(
                ["ss", "-tupna", f"sport = :{local_port}"],
                capture_output=True,
                text=True,
                check=True
            )
            match = re.search(r'users:\(\("([^"]+)",pid=(\d+)', result.stdout)
            
            if match:
                proc_name = match.group(1)
                proc_pid = int(match.group(2))
                
                # If the PID matches our own process, identify as "fiwu"
                service_name = "fiwu" if proc_pid == os.getpid() else proc_name
                
                with self._data_lock:
                    self.port_map[local_port] = service_name
                return service_name
        except subprocess.SubprocessError as e:
            logger.debug(f"Failed to query port {local_port} context: {e}")
        except Exception as e:
            logger.error(f"Unexpected error getting service context for port {local_port}: {e}")

        # Don't cache the failure in port_map: the socket may just not be visible yet
        self._miss_until[local_port] = time.monotonic() + 1.0
            
        return "Unknown"

    # --- Config Management ---

    def get_config(self) -> dict:
        """Retrieve current configuration from disk, respecting file modification time.
        
        If the config file has been modified externally, it reloads from disk.
        """
        with self._data_lock:
            try:
                current_mtime = os.path.getmtime(self.config_path)
                
                # Reload only if the file has changed since last read
                if current_mtime != self.last_config_mtime:
                    with open(self.config_path, "r") as f:
                        self.cached_config = json.load(f)
                    self.last_config_mtime = current_mtime
            except (OSError, json.JSONDecodeError) as e:
                logger.error(f"Config read error on {self.config_path}: {e}")
                
            return self.cached_config

    def save_config(self, new_config: dict) -> bool:
        """Save configuration to disk and update cache.
        """
        with self._data_lock:
            try:
                with open(self.config_path, "w") as f:
                    json.dump(new_config, f, indent=4)
                
                self.cached_config = new_config
                self.last_config_mtime = os.path.getmtime(self.config_path)
                return True
            except (OSError, TypeError) as e:
                logger.error(f"Failed to save config to disk: {e}")
                return False

    # --- Temporary (One-Time) Decisions ---
    def check_transient_rule(self, service_name: str, dst_ip: str) -> str | None:
        """Check for a one-time allow/block rule in memory.
        
        Returns 'ACCEPT', 'DROP', or None if no transient rule exists.
        """
        with self._data_lock:
            if (service_name, dst_ip) in self.one_time_block:
                return "DROP"
            if (service_name, dst_ip) in self.one_time_allow:
                return "ACCEPT"
            return None

    def add_transient_rule(self, service_name: str, dst_ip: str, allow: bool) -> None:
        """Add a temporary rule to memory.
        
        These rules expire when the process dies or is cleaned up.
        """
        with self._data_lock:
            target_set = self.one_time_allow if allow else self.one_time_block
            target_set.add((service_name, dst_ip))

    def clean_dead_processes(self) -> None:
        """Remove transient rules for processes that no longer exist on the system."""
        try:
            # Get current running process names natively via /proc
            running_names = set()
            for pid_dir in os.listdir('/proc'):
                if pid_dir.isdigit():
                    try:
                        with open(f"/proc/{pid_dir}/comm", "r") as f:
                            running_names.add(f.read().strip())
                    except OSError:
                        continue
                    
            with self._data_lock:
                # Identify entries where the process name is no longer active
                dead_allows = {item for item in self.one_time_allow if item[0] not in running_names}
                dead_blocks = {item for item in self.one_time_block if item[0] not in running_names}

                for item in dead_allows:
                    self.one_time_allow.remove(item)
                    logger.debug(f"Memory cleanup: removed temporary allow for {item[0]} ({item[1]})")

                for item in dead_blocks:
                    self.one_time_block.remove(item)
                    logger.debug(f"Memory cleanup: removed temporary block for {item[0]} ({item[1]})")
        except Exception as e:
            logger.error(f"Unexpected error during process cleanup: {e}")
            
    # --- UI & Async Queue Locks ---
    def claim_prompt(self, prompt_key: str) -> bool:
        """Attempt to claim a unique prompt key.
        
        Returns True if the key was newly added (claim successful), False if it already exists.
        """
        with self._data_lock:
            if prompt_key in self.pending_prompts:
                return False
            self.pending_prompts.add(prompt_key)
            return True

    def release_prompt(self, prompt_key: str) -> None:
        """Remove a prompt key from the pending set."""
        with self._data_lock:
            self.pending_prompts.discard(prompt_key)

    @property
    def ui_lock(self) -> threading.Lock:
        """Return the lock used for UI thread serialization."""
        return self._ui_lock