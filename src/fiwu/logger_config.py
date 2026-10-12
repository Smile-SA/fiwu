import logging
import os
from pathlib import Path

# Directory for log files
LOG_DIR = Path("/var/log/fiwu")
LOG_FILE = LOG_DIR / "fiwu.log"


def setup_logger() -> logging.Logger:
    """Configure and return the Fiwu logger.
    
    Sets up both file and console handlers with appropriate formats.
    Ensures log directory exists before writing.
    """
    # Ensure log directory exists
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("fiwu")
    logger.setLevel(logging.DEBUG)  # Capture all levels internally

    # Prevent duplicate handlers if this function is called multiple times
    if logger.handlers:
        return logger

    # File Handler
    try:
        fh = logging.FileHandler(LOG_FILE)
        fh.setLevel(logging.DEBUG)
        file_fmt = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        fh.setFormatter(file_fmt)
        logger.addHandler(fh)
    except (PermissionError, OSError) as e:
        # If we can't write to logs, fallback to console only
        print(f"Warning: Cannot write to log file {LOG_FILE}: {e}", flush=True)

    # Console Handler (stdout)
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)  # Only show INFO and above in console by default
    console_fmt = logging.Formatter('%(levelname)s - %(message)s')
    ch.setFormatter(console_fmt)
    logger.addHandler(ch)

    return logger


# Initialize the global logger instance when this module is imported
logger = setup_logger()