import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import Gdk from 'gi://Gdk';
import GLib from 'gi://GLib';
import { ExtensionPreferences } from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

const CONFIG_PATH = '/etc/fiwu/config.json';
const POLL_INTERVAL = 2;
const SERVICE_NAME = 'fiwu.service';

// These keys configure Fiwu itself; every other top-level key represents a process.
const RESERVED_TOP_KEYS = new Set(['gui', 'default', 'block_processes', 'allow_processes']);

function getProcessState(rule) {
    // Normalize both the legacy string form and the newer per-IP object form
    // into the three states understood by the preferences UI.
    if (typeof rule === 'string') {
        return { mode: rule === 'blocked' ? 'on' : 'off', ips: {} };
    }

    if (rule && typeof rule === 'object') {
        const ips = {};
        for (const [key, value] of Object.entries(rule)) {
            if (key !== 'global' && key !== ':all') ips[key] = value;
        }

        if (rule[':all'] === true) {
            return { mode: rule.global === 'blocked' ? 'on' : 'off', ips };
        }
        return { mode: 'mixed', ips };
    }

    return { mode: 'mixed', ips: {} };
}

function describeProcessState(state) {
    if (state.mode === 'on') return 'Blocked';
    if (state.mode === 'off') return 'Allowed';
    const count = Object.keys(state.ips).length;
    if (count === 0) return 'Custom — will ask on next connection';
    return count === 1 ? '1 custom IP rule' : `${count} custom IP rules`;
}

function ensureCustomCss(display) {
    // Adwaita does not provide the mixed state used by Fiwu's per-process rules,
    // so the preferences window supplies custom style.
    const provider = new Gtk.CssProvider();
    provider.load_from_string(`
        .fiwu-process-row:not(.fiwu-mixed) image.expander-row-arrow,
        .fiwu-process-row:not(.fiwu-mixed) .expander-row-arrow,
        .fiwu-process-row:not(.fiwu-mixed) image.expander {
            opacity: 0 !important;
            color: transparent !important;
        }

        scale.fiwu-tristate {
            min-width: 64px;
            max-width: 64px;
            min-height: 26px;
            padding: 0;
            margin: 0;
            border: none;
            outline: none;
            box-shadow: none;
            background: none;
        }

        scale.fiwu-tristate contents {
            border: none;
            outline: none;
            box-shadow: none;
            background: none;
            padding: 0;
            margin: 0;
        }

        scale.fiwu-tristate trough {
            min-width: 64px;
            max-width: 64px;
            min-height: 26px;
            max-height: 26px;
            border-radius: 13px;
            border: none;
            outline: none;
            box-shadow: none;
            background-color: alpha(currentColor, 0.18);
            transition: background-color 200ms ease;

            background-image: 
                radial-gradient(circle, alpha(white, 0.35) 1.5px, transparent 1.75px),
                radial-gradient(circle, alpha(white, 0.35) 1.5px, transparent 1.75px),
                radial-gradient(circle, alpha(white, 0.35) 1.5px, transparent 1.75px);

            background-repeat: no-repeat;
            background-size: 6px 6px, 6px 6px, 6px 6px;

            background-position: 
                8px center, 
                center center, 
                calc(100% - 8px) center;
        }
        scale.fiwu-tristate trough highlight { 
            background: none; 
            box-shadow: none; 
        }

        scale.fiwu-tristate slider {
            min-width: 18px;
            min-height: 18px;
            margin: 4px;
            border-radius: 9999px;
            background-color: white;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
            transition: all 200ms cubic-bezier(0.2, 0, 0, 1);
        }

        scale.fiwu-tristate.state-mixed trough { 
            background-color: alpha(@accent_bg_color, 0.55); 
        }
        scale.fiwu-tristate.state-on trough { 
            background-color: @accent_bg_color; 
        }
        scale.fiwu-tristate.state-off trough { 
            background-color: alpha(currentColor, 0.25); 
        }

        switch.fiwu-ip-switch {
            transform: scale(0.887);
            transform-origin: right center;
            margin: 0;
        }

        switch.fiwu-ip-switch slider {
            background-color: transparent;
            box-shadow: none;
            background-image: radial-gradient(circle, white 9px, transparent 9.5px);
            background-position: center;
            background-repeat: no-repeat;
        }
    `);

    const targetDisplay = display || Gdk.Display.get_default();
    if (targetDisplay) {
        Gtk.StyleContext.add_provider_for_display(
            targetDisplay,
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_USER
        );
    }
}

function makeTriState(initialMode, onChange) {
    const modes = ['off', 'mixed', 'on'];

    const scale = new Gtk.Scale({
        orientation: Gtk.Orientation.HORIZONTAL,
        adjustment: new Gtk.Adjustment({ lower: 0, upper: 2, step_increment: 1 }),
        draw_value: false,
        round_digits: 0,
        has_origin: false,
        valign: Gtk.Align.CENTER,
        hexpand: false,
        css_classes: ['fiwu-tristate'],
    });

    let suppress = false;

    const setMode = (mode) => {
        // Programmatic updates must not be mistaken for user input and written
        // back to the config while the UI is being refreshed.
        suppress = true;
        scale.set_value(modes.indexOf(mode));
        for (const m of modes) scale.remove_css_class(`state-${m}`);
        scale.add_css_class(`state-${mode}`);
        suppress = false;
    };

    setMode(initialMode);

    scale.connect('value-changed', () => {
        if (suppress) return;
        const selectedMode = modes[Math.round(scale.get_value())];
        setMode(selectedMode);
        onChange(selectedMode);
    });

    return { scaleWidget: scale, setMode };
}

export default class FiwuPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        ensureCustomCss(window.get_display());

        // The config and service are shared with the daemon, so this window
        // treats them as external state and periodically reconciles its controls.
        this._pollSourceId = null;
        this._lastKnownConfig = null;
        this._serviceProxy = null;
        this._serviceSigId = null;
        this._suppressToggle = false;

        this._processRows = new Map();

        const page = new Adw.PreferencesPage({
            title: 'Fiwu',
            icon_name: 'preferences-system-symbolic',
        });
        window.add(page);

        const heroGroup = new Adw.PreferencesGroup();
        page.add(heroGroup);

        const fiwuRow = new Adw.ExpanderRow({
            title: 'Fiwu',
            subtitle: 'Loading…',
            show_enable_switch: true,
        });
        fiwuRow.connect('notify::enable-expansion', () => {
            if (this._suppressToggle) return;
            this._setServiceActive(fiwuRow.enable_expansion);
        });

        heroGroup.add(fiwuRow);

        const uiRow = new Adw.ComboRow({
            title: 'UI Mode',
            model: Gtk.StringList.new(['zenity', 'tkinter']),
        });

        uiRow.connect('notify::selected', () => {
            const selectedGui = ['zenity', 'tkinter'][uiRow.selected];
            const configUpdate = { gui: selectedGui };

            this._writeConfig(configUpdate, () => {
                this._setServiceActive(false);
                this._setServiceActive(true);
            });
        });

        fiwuRow.add_row(uiRow);

        const defaultGroup = new Adw.PreferencesGroup({ title: 'Default Policy' });
        page.add(defaultGroup);

        const defaultRow = new Adw.ActionRow({
            title: 'Block by default',
            subtitle: 'Block all unlisted processes',
        });

        const defaultToggle = new Gtk.Switch({ valign: Gtk.Align.CENTER });

        defaultToggle.connect('notify::active', () => {
            this._writeConfig({
                default: defaultToggle.active ? 'block' : 'allow',
            });
        });

        defaultRow.add_suffix(defaultToggle);
        defaultRow.activatable_widget = defaultToggle;
        defaultGroup.add(defaultRow);

        const clearRow = new Adw.ActionRow({
            title: 'Clear all rules',
            subtitle: 'Remove all blocked and allowed processes',
        });

        const clearBtn = new Gtk.Button({
            icon_name: 'user-trash-symbolic',
            valign: Gtk.Align.CENTER,
            css_classes: ['destructive-action'],
        });

        const cancelBtn = new Gtk.Button({
            label: 'Cancel',
            valign: Gtk.Align.CENTER,
            css_classes: ['flat'],
            visible: false,
        });

        const confirmBtn = new Gtk.Button({
            label: 'Clear',
            valign: Gtk.Align.CENTER,
            css_classes: ['destructive-action'],
            visible: false,
        });

        let autoRevertId = null;

        const showConfirm = () => {
            clearBtn.visible = false;
            cancelBtn.visible = true;
            confirmBtn.visible = true;
            clearRow.subtitle = 'Are you sure? This cannot be undone.';

            autoRevertId = GLib.timeout_add_seconds(
                GLib.PRIORITY_DEFAULT,
                5,
                () => {
                    showNormal();
                    autoRevertId = null;
                    return GLib.SOURCE_REMOVE;
                }
            );
        };

        const showNormal = () => {
            if (autoRevertId !== null) {
                GLib.source_remove(autoRevertId);
                autoRevertId = null;
            }
            clearBtn.visible = true;
            cancelBtn.visible = false;
            confirmBtn.visible = false;
            clearRow.subtitle = 'Remove all blocked and allowed processes';
        };

        clearBtn.connect('clicked', showConfirm);
        cancelBtn.connect('clicked', showNormal);

        confirmBtn.connect('clicked', () => {
            showNormal();
            this._mutateConfig((fresh) => {
                for (const key of Object.keys(fresh)) {
                    if (!RESERVED_TOP_KEYS.has(key)) delete fresh[key];
                }
            });
        });

        clearRow.add_suffix(cancelBtn);
        clearRow.add_suffix(confirmBtn);
        clearRow.add_suffix(clearBtn);

        const dangerGroup = new Adw.PreferencesGroup({
            title: 'Danger Zone',
        });

        dangerGroup.add(clearRow);

        this._processGroup = new Adw.PreferencesGroup({
            title: 'Process Status',
        });

        page.add(this._processGroup);
        page.add(dangerGroup);

        this._watchService((active) => {
            // Avoid sending a second systemctl request when D-Bus reports a
            // state change that was caused by the preferences window itself.
            this._suppressToggle = true;

            if (fiwuRow.enable_expansion !== active)
                fiwuRow.enable_expansion = active;

            fiwuRow.subtitle = active
                ? 'Actively managing network access per process'
                : 'Disabled — all processes have network access';

            if (active) {
                fiwuRow.remove_css_class('dim-label');
            } else {
                fiwuRow.add_css_class('dim-label');
            }

            for (const group of [defaultGroup, this._processGroup, dangerGroup]) {
                group.sensitive = active;
            }

            this._suppressToggle = false;
        });

        const applyConfig = (config) => {
            if (!config) return;

            // Polling is cheap, but rebuilding rows and controls for unchanged
            // JSON would create needless signal traffic and visual churn.
            const serialized = JSON.stringify(config);
            if (serialized === this._lastKnownConfig) return;
            this._lastKnownConfig = serialized;

            const guiIndex = ['zenity', 'tkinter'].indexOf(config.gui ?? 'zenity');
            if (uiRow.selected !== guiIndex) {
                uiRow.selected = guiIndex;
            }

            const shouldBlock = config.default === 'block';
            if (defaultToggle.active !== shouldBlock) {
                defaultToggle.active = shouldBlock;
            }

            this._syncProcesses(config);
        };

        this._applyConfig = applyConfig;
        this._readConfig(applyConfig);

        this._pollSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            POLL_INTERVAL,
            () => {
                this._readConfig(applyConfig);
                return GLib.SOURCE_CONTINUE;
            }
        );

        window.connect('destroy', () => {
            // Stop all GLib sources and D-Bus callbacks before the window dies.
            if (this._pollSourceId !== null) {
                GLib.source_remove(this._pollSourceId);
                this._pollSourceId = null;
            }
            if (autoRevertId !== null) {
                GLib.source_remove(autoRevertId);
            }
            if (this._serviceSigId !== null && this._serviceProxy) {
                this._serviceProxy.disconnectSignal(this._serviceSigId);
            }
            this._serviceProxy = null;
        });
    }

    _watchService(callback) {
        // Resolve the unit once, then observe ActiveState changes through D-Bus.
        Gio.DBus.system.call(
            'org.freedesktop.systemd1',
            '/org/freedesktop/systemd1',
            'org.freedesktop.systemd1.Manager',
            'LoadUnit',
            new GLib.Variant('(s)', [SERVICE_NAME]),
            new GLib.VariantType('(o)'),
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (conn, result) => {
                try {
                    const [path] = conn.call_finish(result).deepUnpack();

                    const proxy = Gio.DBusProxy.new_sync(
                        Gio.DBus.system, Gio.DBusProxyFlags.NONE, null,
                        'org.freedesktop.systemd1',
                        path,
                        'org.freedesktop.systemd1.Unit',
                        null
                    );

                    this._serviceProxy = proxy;

                    // Report the current state immediately, then forward future
                    // changes to the preferences row.
                    const state = proxy.get_cached_property('ActiveState')?.unpack();
                    callback(state === 'active');

                    this._serviceSigId = proxy.connect('g-properties-changed',
                        (_proxy, changed) => {
                            const v = changed.lookup_value('ActiveState',
                                new GLib.VariantType('s'));
                            if (v) callback(v.unpack() === 'active');
                        }
                    );
                } catch (e) {
                    console.error(`DBus watch error: ${e.message}`);
                }
            }
        );
    }

    _setServiceActive(active) {
        // Keep runtime state and boot persistence aligned with one user action.
        const action = active ? 'start' : 'stop';
        const persist = active ? 'enable' : 'disable';

        const run = (cmd) => {
            try {
                const proc = Gio.Subprocess.new(cmd, Gio.SubprocessFlags.NONE);
                proc.wait_async(null, (proc, result) => {
                    try {
                        proc.wait_finish(result);
                    } catch (e) {
                        console.error(`Failed to execute systemctl: ${e.message}`);
                    }
                });
            } catch (e) {
                console.error(`Failed to spawn subprocess: ${e.message}`);
            }
        };

        run(['sudo', '/usr/bin/systemctl', action, SERVICE_NAME]);
        run(['sudo', '/usr/bin/systemctl', persist, SERVICE_NAME]);
    }

    _syncProcesses(config) {
        // Reconcile the existing widget map with the config instead of rebuilding
        // the whole process list every time the polling timer fires.
        const names = Object.keys(config).filter(k => !RESERVED_TOP_KEYS.has(k));
        const next = new Set(names);

        for (const name of Array.from(this._processRows.keys())) {
            if (!next.has(name)) {
                this._processGroup.remove(this._processRows.get(name).row);
                this._processRows.delete(name);
            }
        }

        for (const name of names) {
            let entry = this._processRows.get(name);
            if (!entry) {
                entry = this._createProcessRow(name);
                this._processGroup.add(entry.row);
                this._processRows.set(name, entry);
            }

            const state = getProcessState(config[name]);

            entry.control.setMode(state.mode);
            entry.row.subtitle = describeProcessState(state);

            const isMixed = state.mode === 'mixed';
            if (isMixed) {
                entry.row.add_css_class('fiwu-mixed');
            } else {
                entry.row.remove_css_class('fiwu-mixed');
                entry.row.expanded = false;
            }

            this._syncIpRows(entry, name, state.ips);
        }
    }

    _createProcessRow(name) {
        const row = new Adw.ExpanderRow({ title: name });
        row.add_css_class('fiwu-process-row');

        // IP-level rules only have meaning for a mixed process state.
        row.connect('notify::expanded', () => {
            if (!row.has_css_class('fiwu-mixed') && row.expanded) {
                row.expanded = false;
            }
        });

        const control = makeTriState('off', (mode) => {
            this._setProcessMode(name, mode);
            const isMixed = mode === 'mixed';
            if (isMixed) {
                row.add_css_class('fiwu-mixed');
                row.expanded = true;
            } else {
                row.remove_css_class('fiwu-mixed');
                row.expanded = false;
            }
        });

        const removeBtn = new Gtk.Button({
            icon_name: 'user-trash-symbolic',
            valign: Gtk.Align.CENTER,
            css_classes: ['flat', 'destructive-action'],
            tooltip_text: `Remove ${name}`,
        });

        removeBtn.connect('clicked', () => {
            this._mutateConfig((fresh) => { delete fresh[name]; });
        });

        const suffixBox = new Gtk.Box({ 
            orientation: Gtk.Orientation.HORIZONTAL, 
            spacing: 12, 
            valign: Gtk.Align.CENTER 
        });
        suffixBox.append(control.scaleWidget);
        suffixBox.append(removeBtn);
        row.add_suffix(suffixBox);

        return { row, control, ipRows: new Map() };
    }

    _setProcessMode(name, mode) {
        // Changing the global mode preserves any existing per-IP overrides.
        this._mutateConfig((fresh) => {
            const current = fresh[name];
            let ips = {};

            if (typeof current === 'object' && current !== null) {
                for (const [k, v] of Object.entries(current)) {
                    if (k !== 'global' && k !== ':all') ips[k] = v;
                }
            }

            if (mode === 'mixed') {
                fresh[name] = ips;
            } else {
                fresh[name] = {
                    ...ips,
                    global: mode === 'on' ? 'blocked' : 'allowed',
                    ':all': true,
                };
            }
        });
    }

    _syncIpRows(entry, processName, ips) {
        // Apply the same incremental reconciliation to the child IP rows.
        const map = entry.ipRows;
        const next = new Set(Object.keys(ips));

        for (const ip of Array.from(map.keys())) {
            if (!next.has(ip)) {
                entry.row.remove(map.get(ip).row);
                map.delete(ip);
            }
        }

        for (const [ip, status] of Object.entries(ips)) {
            let ipEntry = map.get(ip);

            if (!ipEntry) {
                const ipRow = new Adw.ActionRow({ title: ip });

                const toggle = new Gtk.Switch({ 
                    valign: Gtk.Align.CENTER,
                    css_classes: ['fiwu-ip-switch'],
                });

                ipEntry = { row: ipRow, toggle, suppress: false };
                map.set(ip, ipEntry);

                toggle.connect('notify::active', () => {
                    if (ipEntry.suppress) return;
                    this._mutateConfig((fresh) => {
                        if (!fresh[processName] || typeof fresh[processName] !== 'object') return;
                        fresh[processName][ip] = toggle.active ? 'blocked' : 'allowed';
                    });
                });

                const removeBtn = new Gtk.Button({
                    icon_name: 'user-trash-symbolic',
                    valign: Gtk.Align.CENTER,
                    css_classes: ['flat', 'destructive-action'],
                    tooltip_text: `Remove ${ip}`,
                });

                removeBtn.connect('clicked', () => {
                    this._mutateConfig((fresh) => {
                        if (fresh[processName] && typeof fresh[processName] === 'object')
                            delete fresh[processName][ip];
                    });
                });

                const suffixBox = new Gtk.Box({ 
                    orientation: Gtk.Orientation.HORIZONTAL, 
                    spacing: 12, 
                    valign: Gtk.Align.CENTER 
                });
                suffixBox.append(toggle);
                suffixBox.append(removeBtn);
                ipRow.add_suffix(suffixBox);
                ipRow.activatable_widget = toggle;

                entry.row.add_row(ipRow);
            }

            const shouldBeBlocked = status === 'blocked';
            if (ipEntry.toggle.active !== shouldBeBlocked) {
                ipEntry.suppress = true;
                ipEntry.toggle.active = shouldBeBlocked;
                ipEntry.suppress = false;
            }
        }
    }

    _readConfig(callback) {
        // The daemon config is root-owned; sudo is used only for this read,
        // while parsing remains local to the preferences process.
        try {
            const proc = Gio.Subprocess.new(
                ['sudo', '/usr/bin/cat', CONFIG_PATH],
                Gio.SubprocessFlags.STDOUT_PIPE
            );

            proc.communicate_utf8_async(null, null, (proc, result) => {
                try {
                    const [, stdout] = proc.communicate_utf8_finish(result);
                    callback(JSON.parse(stdout));
                } catch (e) {
                    console.error(`Config parse error: ${e.message}`);
                    callback(null);
                }
            });
        } catch (e) {
            console.error(`Read error: ${e.message}`);
            callback(null);
        }
    }

    _writeConfig(patch, callback) {
        // Read the latest file before applying a small patch so unrelated rules
        // changed by the daemon or another preferences action are retained.
        this._readConfig((fresh) => {
            if (!fresh) return;

            Object.assign(fresh, patch);

            const jsonStr = JSON.stringify(fresh, null, 2);
            const proc = Gio.Subprocess.new(
                ['sudo', '/usr/bin/tee', CONFIG_PATH],
                Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE
            );

            proc.communicate_utf8_async(jsonStr, null, (proc, result) => {
                try {
                    proc.communicate_utf8_finish(result);
                    if (callback) callback();
                } catch (e) {
                    console.error(`Failed to write config: ${e.message}`);
                }
            });
        });
    }

    _mutateConfig(mutator) {
        // Mutations use the same fresh-read pattern as patches, but expose the
        // whole object to callers that add or remove dynamic process rules.
        this._readConfig((fresh) => {
            if (!fresh) return;

            mutator(fresh);

            const json = JSON.stringify(fresh, null, 4);
            const proc = Gio.Subprocess.new(
                ['sudo', '/usr/bin/tee', CONFIG_PATH],
                Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE
            );

            proc.communicate_async(
                new TextEncoder().encode(json),
                null,
                (proc, result) => {
                    try {
                        proc.communicate_finish(result);
                    } catch (e) {
                        console.error(`Write error: ${e.message}`);
                    }
                }
            );
        });
    }
}