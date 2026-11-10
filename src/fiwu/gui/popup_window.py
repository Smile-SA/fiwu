import json
import os
import signal
import sys
import time
from pathlib import Path

# Make `fiwu` importable (dev checkout or installed package)
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from fiwu.gui.dialogs import ask_user_tkinter  


_TRACE = os.path.exists("/tmp/fiwu_trace")  # benchmark-only 


def _trace(tag: str) -> None:
    if _TRACE:
        try:
            with open("/tmp/fiwu_trace.log", "a") as f:
                f.write(f"{tag} {time.monotonic():.6f}\n")
        except OSError:
            pass


def _answer(req: dict, code: int) -> None:
    try:  # single write < PIPE_BUF: atomic, no stdio buffer shared with the parent
        os.write(1, (json.dumps({"id": req.get("id"), "code": code}) + "\n").encode())
    except OSError:
        pass


def _popup_child(req: dict) -> None:
    """Runs in the forked popup process. Never returns."""
    _trace("child")
    try:
        try:
            os.close(0)  # the request pipe belongs to the parent
        except OSError:
            pass
        sent = []

        def send(code):
            if sent:
                return
            sent.append(1)
            _answer(req, code)

        try:
            code = ask_user_tkinter(req["service"], req["ip"], req["port"], on_answer=send)
        except Exception:
            code = 3
        send(code)
    finally:
        os._exit(0)


def _supervise(req: dict) -> None:
    """Runs in a forked supervisor. Starts the real popup and, if that process dies
    without exiting cleanly (Tk fatal X error, crash, kill), answers 'block' (3) so
    fiwu never waits forever on a popup that no longer exists. Never returns."""
    try:
        try:
            os.close(0)
        except OSError:
            pass
        signal.signal(signal.SIGCHLD, signal.SIG_DFL) 
        try:
            pid = os.fork()
        except OSError:
            _answer(req, 3)
            return
        if pid == 0:
            _popup_child(req)
        _, status = os.waitpid(pid, 0)
        if not (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0):
            _answer(req, 3)
    finally:
        os._exit(0)


def serve() -> None:
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    sys.stdout.write("READY\n")
    sys.stdout.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        _trace("recv")
        try:
            req = json.loads(line)
        except ValueError:
            continue
        try:
            pid = os.fork()
        except OSError:
            _answer(req, 3)
            continue
        if pid == 0:
            _supervise(req)


if __name__ == "__main__":
    serve()