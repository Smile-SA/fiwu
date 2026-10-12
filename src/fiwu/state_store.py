import threading
import json
import os
import re
import subprocess
import psutil

from fiwu.logger_config import logger


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

    # --- Port Mapping ---
    def update_port_map(self, new_map: dict) -> None:
        """Atomically replace the current port-to-process mapping."""
        with self._data_lock:
            self.port_map = new_map.copy()

    def get_service_for_port(self, local_port: int) -> str:
        """Retrieve the process name associated with a local port.
        
        Checks in-memory map first, then falls back to querying `ss` if missing.
        Returns 'Unknown' if no service is found or an error occurs.
        """
        if not local_port:
            return "Unknown"

        with self._data_lock:
            if local_port in self.port_map:
                return self.port_map[local_port]

        # Fallback: Query system sockets directly via ss command
        try:
            result = subprocess.run(
                ["ss", "-tupna", f"sport = :{local_port}"],
                capture_output=True,
                text=True,
                check=True
            )
            match = re.search(r'users:\(\("([^"]+)",pid=(\d+)\)', result.stdout)
            
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

        # Fallback if lookup fails or returns no match
        with self._data_lock:
            self.port_map[local_port] = "Unknown"
            
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
            # Get current running process names
            running_names = {p.info['name'] for p in psutil.process_iter(['name'])}
            
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
        except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
            # Expected on some systems when iterating processes
            logger.debug(f"Process iteration notice: {e}")
        except Exception as e:
            logger.error(f"Unexpected error during memory cleanup: {e}")

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