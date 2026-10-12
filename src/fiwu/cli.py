import argparse
import json
import os
import signal
import subprocess
from pathlib import Path

# Constants for service management
SERVICE = "fiwu.service"
CONFIG = Path("/etc/fiwu/config.json")
BACKUP_DIR = Path("/var/backups/fiwu")
BACKUP = BACKUP_DIR / "config.json"


def start() -> None:
    """Start the Fiwu service and ensure unbuffered Python output."""
    subprocess.run(["sudo", "systemctl", "set-environment", "PYTHONUNBUFFERED=1"], check=False)
    subprocess.run(["sudo", "systemctl", "start", SERVICE], check=False)

def stop() -> None:
    """Stop the Fiwu service."""
    subprocess.run(["sudo", "systemctl", "stop", SERVICE], check=False)

def status() -> None:
    """Display the current status of the Fiwu service."""
    subprocess.run(["systemctl", "--no-pager", "status", SERVICE])

def rules() -> None:
    """Print the location of the configuration file and display its contents."""
    print(f"Configuration: {CONFIG}", flush=True)

    if CONFIG.exists():
        # Use explicit cat path to avoid alias issues in sudo
        subprocess.run(["sudo", "/usr/bin/cat", str(CONFIG)])
    else:
        print("Config not found", flush=True)

def set_gui(mode: str) -> None:
    """Update the GUI backend in config.json and restart the service.
    
    Args:
        mode: The desired GUI backend ('zenity' or 'tkinter').
    """
    if CONFIG.exists():
        try:
            result = subprocess.run(
                ["sudo", "/usr/bin/cat", str(CONFIG)],
                capture_output=True,
                text=True,
                check=True,
            )
            config = json.loads(result.stdout)
        except (json.JSONDecodeError, subprocess.CalledProcessError) as e:
            print(f"Could not read {CONFIG}: {e}")
            return
    else:
        config = {}

    config["gui"] = mode

    try:
        # Write new config using tee for permission handling
        subprocess.run(
            ["sudo", "/usr/bin/tee", str(CONFIG)],
            input=json.dumps(config, indent=4).encode(),
            stdout=subprocess.DEVNULL,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"Failed to update {CONFIG}: {e}")
        return
          
    # Restart service to apply GUI changes
    subprocess.run(["sudo", "systemctl", "restart", SERVICE], check=False)

def get_logs() -> None:
    """Exec into journalctl to follow logs for the Fiwu service."""
    os.execvp("sudo", ["sudo", "journalctl", "-u", SERVICE, "-f", "-n", "50"])

def upgrade() -> bool:
    """Upgrade Fiwu via APT and restart if updated successfully.
    
    Returns:
        True if upgrade was successful, False otherwise.
    """
    print("Checking for package updates via APT...", flush=True)
    subprocess.run(["sudo", "apt-get", "update"], check=False)
    result = subprocess.run(
        ["sudo", "apt-get", "install", "--only-upgrade", "-y", "fiwu"], check=False
    )
    if result.returncode == 0:
        subprocess.run(["sudo", "systemctl", "restart", SERVICE], check=False)
        return True
    return False

def uninstall() -> None:
    """Uninstall Fiwu by running install.sh scripts or purging via APT.
    
    Attempts to find uninstall.sh in the current directory, then repo root,
    before falling back to apt purge.
    """
    # 1. Check current working directory for uninstall.sh
    cwd_script = Path.cwd() / "uninstall.sh"
    if cwd_script.exists():
        os.execvp("sudo", ["sudo", "bash", str(cwd_script)])

    # 2. Check repo root fallback
    script_dir = Path(__file__).resolve().parent
    repo_uninstall = script_dir.parents[1] / "uninstall.sh"
    if repo_uninstall.exists():
        os.execvp("sudo", ["sudo", "bash", str(repo_uninstall)])

    # 3. Fallback for standalone package installations
    print("Purging APT package...", flush=True)
    subprocess.run(["sudo", "apt-get", "purge", "-y", "fiwu"], check=False)
    subprocess.run(["sudo", "apt-get", "autoremove", "-y"], check=False)

def reinstall() -> None:
    """Reinstall Fiwu by running install.sh scripts or via APT.
    
    Attempts to find install.sh in the current directory, then repo root,
    before falling back to apt reinstall.
    """
    # 1. Check current working directory for install.sh
    cwd_script = Path.cwd() / "install.sh"
    if cwd_script.exists():
        os.execvp("sudo", ["sudo", "bash", "-c", f"cd {cwd_script.parent} && ./install.sh"])

    # 2. Check repo root fallback
    script_dir = Path(__file__).resolve().parent
    repo_install = script_dir.parents[1] / "install.sh"
    if repo_install.exists():
        os.execvp("sudo", ["sudo", "bash", "-c", f"cd {repo_install.parent} && ./install.sh"])

    # 3. Fallback to APT reinstall if installed via remote PPA
    print("Reinstalling via APT...", flush=True)
    subprocess.run(["sudo", "apt-get", "install", "--reinstall", "-y", "fiwu"], check=False)

def main() -> None:
    """Parse arguments and execute the corresponding command."""
    parser = argparse.ArgumentParser(prog="fiwu", description="Fiwu Ctrl")

    group = parser.add_mutually_exclusive_group()

    # Service Control
    group.add_argument("-e", "--start", dest="start", action="store_true", help="start service")
    group.add_argument("-c", "--stop", dest="stop", action="store_true", help="stop service")
    group.add_argument("-s", "--status", dest="status", action="store_true", help="service status")
    
    # Diagnostics
    group.add_argument("-l", "--logs", dest="logs", action="store_true", help="show logs")
    group.add_argument("-r", "--rules", dest="rules", action="store_true", help="show rules")
    
    # Maintenance
    group.add_argument("-u", "--upgrade", dest="upgrade", action="store_true", help="upgrade service")
    group.add_argument(
        "-i",
        "--reinstall",
        dest="reinstall",
        action="store_true",
        help="repair/reinstall (re-run install.sh)",
    )
    
    # GUI Configuration
    group.add_argument(
        "-g",
        "--gui",
        dest="gui",
        choices=["zenity", "tkinter", "dev"],
        metavar="{zenity,tkinter}",
        help="set GUI backend and restart service (zenity/tkinter)",
    )
    
    # Removal
    group.add_argument("-x", "--uninstall", dest="uninstall", action="store_true", help="uninstall fiwu")

    args = parser.parse_args()

    if args.start:
        start()
    elif args.stop:
        stop()
    elif args.status:
        status()
    elif args.rules:
        rules()
    elif args.logs:
        get_logs()
    elif args.gui:
        set_gui(args.gui)
    elif args.upgrade:
        upgrade()
    elif args.uninstall:
        uninstall()
    elif args.reinstall:
        reinstall()
    else:
        parser.print_help()

if __name__ == "__main__":
    main()