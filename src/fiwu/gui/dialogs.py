import os
import sys
import pwd
import psutil
import subprocess
import tkinter as tk

from fiwu.logger_config import logger


def ask_user_zenity(
    service_name: str, 
    dst_ip: str, 
    port: int | None,
    user: str,
    display: str,
    wayland_display: str,
    xdg_runtime_dir: str,
    dbus_address: str
) -> int:
    """Launch a Zenity dialog to ask the user for permission.
    
    Runs as the target desktop user via runuser/systemd-run to ensure 
    proper environment context.
    
    Returns:
        0 if allowed, 1 if blocked, 3 if an error occurred or dialog was closed.
    """
    message = f"{service_name} wants to connect to {dst_ip}:{port}"
    
    # Construct command to run zenity as the specific desktop user
    zenity_cmd = [
        "runuser", "-u", user, "--", "env",
        f"DISPLAY={display}",
        f"WAYLAND_DISPLAY={wayland_display}",
        f"XDG_RUNTIME_DIR={xdg_runtime_dir}",
        f"DBUS_SESSION_BUS_ADDRESS={dbus_address}",
        "systemd-run",
        "--pipe",
        "--user",
        "zenity", "--question", 
        "--title=Fiwu Alert", 
        f"--text={message}",
        "--width=250",
        "--ok-label=Yes", "--cancel-label=No"
    ]
    
    try:
        result = subprocess.run(zenity_cmd, capture_output=True, text=True)
        # Zenity returns 0 for Yes, 1 for Cancel/No
        if result.returncode in [0, 1]:
            return result.returncode
    except Exception as e:
        logger.error(f"[Zenity] Exception running popup: {e}")
        
    # Fallback to block on error
    return 3


def ask_user_tkinter(
    service_name: str, 
    dst_ip: str, 
    port: int | None,
    user: str | None = None,
    display: str | None = None,
    wayland_display: str | None = None,
    xdg_runtime_dir: str | None = None,
    dbus_address: str | None = None
) -> int:
    """Launch a Tkinter dialog to ask the user for permission.
    
    If 'user' is specified, it spawns a subprocess running as that user to 
    ensure proper desktop environment integration. Otherwise, it runs natively.
    
    Returns:
        0 (Allow once), 1 (Block once), 2 (Allow all), 3 (Block all), 
        or 4 (Error/Fallback).
    """
    if user is not None:
        # Spawn as user to ensure proper X11/Wayland integration
        module_dir = os.path.dirname(os.path.abspath(__file__))
        
        inline_code = (
            f"import sys; sys.path.insert(0, {module_dir!r}); "
            f"from fiwu.gui.dialogs import ask_user_tkinter; "
            f"sys.exit(ask_user_tkinter({service_name!r}, {dst_ip!r}, {port!r}))"
        )

        cmd = [
            "runuser", "-u", user, "--", "env",
            f"DISPLAY={display}",
            f"WAYLAND_DISPLAY={wayland_display}",
            f"XDG_RUNTIME_DIR={xdg_runtime_dir}",
            f"DBUS_SESSION_BUS_ADDRESS={dbus_address}",
            "systemd-run", "--pipe", "--user",
            "--setenv=GDK_BACKEND=x11",
            "--setenv=TK_USE_INPUT_METHODS=0",
            sys.executable, "-c", inline_code
        ]

        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode in [0, 1, 2, 3, 4, 5]:
                return result.returncode
        except Exception as e:
            logger.error(f"[TK] Exception running popup: {e}")
            
        # Fallback to error state
        return 3

    # --- Native Tkinter Window Construction ---
    
    result = {'code': 3}

    root = tk.Tk(className="Fiwu")
    root.title("Fiwu Alert")
    
    dpi = root.winfo_fpixels('1i')
    scale = dpi / 96.0
    try:
        root.tk.call('tk', 'scaling', scale)
    except Exception:
        pass

    CSS = {
        "bg": "#2D2D2D",
        "fg": "#E5E5E5",
        "fg_bold": "#FFFFFF",
        "disabled_fg": "#555555",
        "font_main": ("Ubuntu", int(12 * scale)),
        "font_bold": ("Ubuntu", int(12 * scale), "bold"),
        "font_control": ("Ubuntu", int(11 * scale)),
        "font_btn": ("Ubuntu", int(11 * scale), "bold"),
        "btn_bg": "#3D3D3D",
        "btn_hover": "#4A4A4A",
        "btn_active": "#2D2D2D",
        "btn_border": "#555555",
        "cb_size": int(20 * scale),
        "cb_bg_off": "#3D3D3D",
        "cb_bg_on": "#666666",
        "cb_border_off": "#555555",
        "cb_border_on": "#FFFFFF",
        "window_width": int(375 * scale),
        "padding_x": int(20 * scale),
        "padding_y": int(20 * scale),
    }

    root.configure(bg=CSS["bg"])
    root.resizable(False, False)

    try:
        root.attributes("-topmost", True)
    except Exception:
        pass

    main_frame = tk.Frame(root, bg=CSS["bg"], padx=CSS["padding_x"], pady=CSS["padding_y"])
    main_frame.pack(fill="both", expand=True)

    msg_frame = tk.Frame(main_frame, bg=CSS["bg"])
    msg_frame.pack(fill="x", pady=(0, 24))

    row1 = tk.Frame(msg_frame, bg=CSS["bg"])
    row1.pack(anchor="center")

    tk.Label(row1, text=service_name, bg=CSS["bg"], fg=CSS["fg_bold"], font=CSS["font_bold"]).pack(side="left")
    tk.Label(row1, text=" wants to connect to", bg=CSS["bg"], fg=CSS["fg"], font=CSS["font_main"]).pack(side="left")
    tk.Label(msg_frame, text=f"{dst_ip}:{port}", bg=CSS["bg"], fg=CSS["fg_bold"], font=CSS["font_bold"]).pack(anchor="center", pady=(4, 0))

    def make_checkbox(parent, text, command=None):
        frame = tk.Frame(parent, bg=CSS["bg"], cursor="hand2")
        var = tk.BooleanVar(value=False)
        state = {"enabled": True}

        canvas = tk.Canvas(frame, width=CSS["cb_size"], height=CSS["cb_size"], bg=CSS["bg"], highlightthickness=0, bd=0)
        canvas.pack(side="left", padx=(0, 10))

        label = tk.Label(frame, text=text, bg=CSS["bg"], fg=CSS["fg"], font=CSS["font_control"])
        label.pack(side="left")

        def draw(hover=False):
            canvas.delete("all")
            sz = CSS["cb_size"]
            if not state["enabled"]:
                bg_col, border_col = "#222222", "#444444"
            elif var.get():
                bg_col, border_col = CSS["cb_bg_on"], CSS["cb_border_on"]
            elif hover:
                bg_col, border_col = CSS["btn_hover"], CSS["cb_border_off"]
            else:
                bg_col, border_col = CSS["cb_bg_off"], CSS["cb_border_off"]

            canvas.create_rectangle(0, 0, sz - 1, sz - 1, fill=bg_col, outline=border_col, width=1)
            if var.get():
                canvas.create_text(sz // 2, sz // 2, text="✔", fill="#FFFFFF", font=("Sans", 10, "bold"))

        def toggle(event=None):
            if not state["enabled"]:
                return
            var.set(not var.get())
            draw()
            if command:
                command()

        for w in (frame, canvas, label):
            w.bind("<Button-1>", toggle)
            w.bind("<Enter>", lambda e: draw(hover=True))
            w.bind("<Leave>", lambda e: draw(hover=False))

        draw()
        return {
            "widget": frame,
            "is_checked": lambda: var.get(),
            "set_checked": lambda val: (var.set(val), draw()),
            "set_enabled": lambda val: (state.update({"enabled": val}), label.config(fg=CSS["fg"] if val else CSS["disabled_fg"]), draw())
        }

    cb_frame = tk.Frame(main_frame, bg=CSS["bg"])
    cb_frame.pack(pady=(0, 26))

    cb_once = make_checkbox(cb_frame, "Apply once", lambda: cb_all["set_enabled"](not cb_once["is_checked"]()))
    cb_all = make_checkbox(cb_frame, "Apply to all IPs", lambda: cb_once["set_enabled"](not cb_all["is_checked"]()))

    cb_once["widget"].pack(side="left", padx=(0, 28))
    cb_all["widget"].pack(side="left")

    def choose_yes():
        # 2 = Allow once, 4 = Allow all
        result['code'] = 2 if cb_once["is_checked"]() else (4 if cb_all["is_checked"]() else 0)
        root.destroy()

    def choose_no():
        # 3 = Block once, 5 = Block all
        result['code'] = 3 if cb_once["is_checked"]() else (5 if cb_all["is_checked"]() else 1)
        root.destroy()

    def make_button(parent, text, command):
        canvas = tk.Canvas(parent, width=1, height=int(40 * scale), bg=CSS["bg"], highlightthickness=0, bd=0, cursor="hand2", takefocus=True)

        def draw(state="normal"):
            canvas.delete("all")
            w, h = canvas.winfo_width(), canvas.winfo_height()
            if w < 10 or h < 10:
                return

            bg_col = CSS["btn_hover"] if state == "hover" else CSS["btn_bg"]
            has_focus = (canvas.focus_get() == canvas)
            border_col = CSS["cb_border_on"] if has_focus else CSS["btn_border"]
            r = int(6 * scale)

            # Draw rounded rectangle corners
            canvas.create_arc((0, 0, 2*r, 2*r), start=90, extent=90, fill=bg_col, outline="", style="pieslice")
            canvas.create_arc((w-2*r, 0, w, 2*r), start=0, extent=90, fill=bg_col, outline="", style="pieslice")
            canvas.create_arc((w-2*r, h-2*r, w, h), start=270, extent=90, fill=bg_col, outline="", style="pieslice")
            canvas.create_arc((0, h-2*r, 2*r, h), start=180, extent=90, fill=bg_col, outline="", style="pieslice")
            
            canvas.create_rectangle((r, 0, w-r, h), fill=bg_col, outline="")
            canvas.create_rectangle((0, r, w, h-r), fill=bg_col, outline="")

            # Border lines
            canvas.create_arc((0, 0, 2*r, 2*r), start=90, extent=90, outline=border_col, style="arc")
            canvas.create_arc((w-2*r-1, 0, w-1, 2*r), start=0, extent=90, outline=border_col, style="arc")
            canvas.create_arc((w-2*r-1, h-2*r-1, w-1, h-1), start=270, extent=90, outline=border_col, style="arc")
            canvas.create_arc((0, h-2*r-1, 2*r, h-1), start=180, extent=90, outline=border_col, style="arc")

            canvas.create_line(r, 0, w-r, 0, fill=border_col)
            canvas.create_line(r, h-1, w-r, h-1, fill=border_col)
            canvas.create_line(0, r, 0, h-r, fill=border_col)
            canvas.create_line(w-1, r, w-1, h-r, fill=border_col)

            canvas.create_text(w // 2, h // 2, text=text, fill=CSS["fg_bold"], font=CSS["font_btn"])

        canvas.bind("<Configure>", lambda e: draw("normal"))
        canvas.bind("<Enter>", lambda e: draw("hover"))
        canvas.bind("<Leave>", lambda e: draw("normal"))
        canvas.bind("<FocusIn>", lambda e: draw("normal"))
        canvas.bind("<FocusOut>", lambda e: draw("normal"))
        canvas.bind("<Button-1>", lambda e: (canvas.focus_set(), command()))
        canvas.bind("<space>", lambda e: command())
        canvas.bind("<Return>", lambda e: command())
        return canvas

    btn_frame = tk.Frame(main_frame, bg=CSS["bg"])
    btn_frame.pack(fill="x")

    btn_no = make_button(btn_frame, "No", choose_no)
    btn_yes = make_button(btn_frame, "Yes", choose_yes)

    btn_no.pack(side="left", expand=True, fill="x", padx=(0, 8))
    btn_yes.pack(side="left", expand=True, fill="x", padx=(8, 0))

    root.bind("<Escape>", lambda e: choose_no())

    root.update_idletasks()
    width = CSS["window_width"]
    height = root.winfo_reqheight()
    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    root.geometry(f"{width}x{height}+{(sw - width) // 2}+{(sh - height) // 2}")

    root.mainloop()
    return result['code']


def ask_user_gui(
    service_name: str, 
    dst_ip: str, 
    port: int | None,
    force_zenity: bool = False, 
    force_tk: bool = False, 
    gui_engine_pref: str = "tkinter"
) -> int:
    """Determine GUI backend and launch the appropriate user prompt.
    
    Detects the current desktop session environment to set up correct 
    DISPLAY, WAYLAND_DISPLAY, and DBUS variables for privileged processes.
    """
    # Determine target user (desktop user or sudoer)
    user = os.environ.get("FIWU_DESKTOP_USER") or os.environ.get("SUDO_USER")
    display = ":0"
    wayland_display = "wayland-0"
    dbus_address = None

    gui_processes = ['gnome-shell', 'Xorg', 'wayland', 'kwin_wayland', 'xfce4-session', 'lxsession', 'mate-session']
    
    # Search for a running GUI process to extract environment variables
    for proc in psutil.process_iter(['username', 'name', 'environ']):
        try:
            if proc.info['name'] in gui_processes:
                user = user or proc.info['username']
                if proc.info['environ']:
                    env = proc.info['environ']
                    display = env.get('DISPLAY', display)
                    wayland_display = env.get('WAYLAND_DISPLAY', wayland_display)
                    dbus_address = env.get('DBUS_SESSION_BUS_ADDRESS', dbus_address)
                break
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    user = user or "root"

    try:
        pw = pwd.getpwnam(user)
        uid = pw.pw_uid
        xdg_runtime_dir = f"/run/user/{uid}"
        dbus_address = dbus_address or f"unix:path=/run/user/{uid}/bus"

        # Determine which GUI engine to use
        if force_zenity:
            gui_engine = "zenity"
        elif force_tk:
            gui_engine = "tkinter"
        else:
            gui_engine = gui_engine_pref

        if gui_engine == "zenity":
            return ask_user_zenity(service_name, dst_ip, port, user, display, wayland_display, xdg_runtime_dir, dbus_address)
        else:
            try:
                return ask_user_tkinter(service_name, dst_ip, port, user, display, wayland_display, xdg_runtime_dir, dbus_address)
            except Exception as e:
                logger.error(f"Tkinter execution failed, defaulting return: {e}")
                return 3
    except Exception as e:
        logger.error(f"GUI session detection error: {e}")
        return 3