import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import GLib from 'gi://GLib';

const SERVICE_NAME = 'fiwu.service';

const ServiceToggle = GObject.registerClass(
class ServiceToggle extends QuickSettings.QuickMenuToggle {
    _init(extensionPath, extension) {
        const iconFile = Gio.File.new_for_path(`${extensionPath}/logo-symbolic.svg`);
        const customGIcon = new Gio.FileIcon({ file: iconFile });
        super._init({
            title: 'Fiwu',
            gicon: customGIcon,
            toggleMode: true,
        });

        this.menu.setHeader(customGIcon, 'Fiwu');
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const settingsItem = new PopupMenu.PopupMenuItem('Fiwu Settings');
        settingsItem.connect('activate', () => extension.openPreferences());
        this.menu.addMenuItem(settingsItem);

        this.checked = false;
        this._watchService();
        this.connect('clicked', () => this._toggleService());
    }

    _watchService() {
        // systemd exposes each unit through a dynamically resolved object path.
        Gio.DBus.system.call(
            'org.freedesktop.systemd1',
            '/org/freedesktop/systemd1',
            'org.freedesktop.systemd1.Manager',
            'LoadUnit',
            new GLib.Variant('(s)', ['fiwu.service']),
            new GLib.VariantType('(o)'),
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (conn, result) => {
                try {
                    const [path] = conn.call_finish(result).deepUnpack();

                    // Read the initial state, then keep the toggle synchronized
                    // with service changes made outside this extension.
                    const proxy = Gio.DBusProxy.new_sync(
                        Gio.DBus.system, Gio.DBusProxyFlags.NONE, null,
                        'org.freedesktop.systemd1',
                        path,
                        'org.freedesktop.systemd1.Unit',
                        null
                    );

                    const state = proxy.get_cached_property('ActiveState')?.unpack();
                    this.checked = state === 'active';

                    this._sigId = proxy.connect('g-properties-changed',
                        (_proxy, changed) => {
                            const v = changed.lookup_value('ActiveState',
                                new GLib.VariantType('s'));
                            if (v) this.checked = v.unpack() === 'active';
                        }
                    );
                    this._proxy = proxy;

                } catch (e) {
                    console.error(`DBus watch error: ${e.message}`);
                }
            }
        );
    }

    _toggleService() {
        const starting = this.checked;
        // Starting or stopping the service is paired with enabling or disabling
        // it so the current choice also controls the next boot.
        const action = starting ? 'start' : 'stop';
        const persist = starting ? 'enable' : 'disable';

        const run = (cmd) => {
            try {
                let proc = Gio.Subprocess.new(cmd, Gio.SubprocessFlags.NONE);
                proc.wait_async(null, (proc, result) => {
                    try {
                        proc.wait_finish(result);
                    } catch (e) {
                        console.error(`Failed to execute systemctl: ${e.message}`);
                        this.checked = !this.checked;
                    }
                });
            } catch (e) {
                console.error(`Failed to spawn subprocess: ${e.message}`);
            }
        };
        run(['sudo', '/usr/bin/systemctl', action, SERVICE_NAME]);
        run(['sudo', '/usr/bin/systemctl', persist, SERVICE_NAME]);
    }

    destroy() {
        // The signal belongs to the unit proxy and must be disconnected before
        // the toggle is removed from the Quick Settings menu.
        if (this._sigId) this._proxy.disconnectSignal(this._sigId);
        this._proxy = null;
        super.destroy();
    }
});

export default class ServiceToggleExtension extends Extension {
    enable() {
        this._toggle = new ServiceToggle(this.path, this);
        Main.panel.statusArea.quickSettings.menu.addItem(this._toggle);
    }

    disable() {
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
    }
}