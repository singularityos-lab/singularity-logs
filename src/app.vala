using Gtk;

namespace Singularity.Apps.Logs {

    public class LogsApp : Singularity.Application {
        private string? pending_source = null;

        public LogsApp () {
            Object (application_id: "dev.sinty.logs", flags: ApplicationFlags.DEFAULT_FLAGS);
            add_main_option ("problems", 0, OptionFlags.NONE, OptionArg.NONE, _("Show the problems of the current session"), null);
            add_main_option ("service", 0, OptionFlags.NONE, OptionArg.STRING, _("Show the messages of a service"), _("SERVICE"));
        }

        protected override int handle_local_options (VariantDict options) {
            string? source = null;
            if (options.contains ("problems")) source = "errors";
            string service;
            if (options.lookup ("service", "s", out service) && service.strip () != "") {
                service = service.strip ();
                source = service.has_prefix ("unit:") || service.has_prefix ("ident:") ? service : "unit:" + (service.contains (".") ? service : service + ".service");
            }
            if (source == null) return -1;
            try {
                register ();
            } catch (Error e) {
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("show-source", new Variant.string (source));
                return 0;
            }
            pending_source = source;
            return -1;
        }

        public void show_source (string source) {
            var window = get_active_window () as LogsWindow;
            if (window == null) window = new LogsWindow (this);
            window.present ();
            window.show_source (source);
        }

        protected override void startup () {
            base.startup ();
            IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/dev/sinty/logs/icons");
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            var menu = new GLib.Menu ();
            var file_menu = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("Export…"), "win.export");
            file_menu.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Close Window"), "win.close");
            f2.append (_("Quit"), "app.quit");
            file_menu.append_section (null, f2);
            menu.append_submenu (_("File"), file_menu);
            var edit_menu = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Copy Message"), "win.copy");
            e1.append (_("Find"), "win.find");
            edit_menu.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Settings"), "app.settings");
            edit_menu.append_section (null, e2);
            menu.append_submenu (_("Edit"), edit_menu);
            var view_menu = new GLib.Menu ();
            if (Journal.available ()) {
                var v1 = new GLib.Menu ();
                v1.append (_("All Messages"), "win.source('journal')");
                v1.append (_("Problems"), "win.source('errors')");
                v1.append (_("Kernel"), "win.source('kernel')");
                v1.append (_("Your Apps"), "win.source('user')");
                view_menu.append_section (null, v1);
            }
            var v2 = new GLib.Menu ();
            v2.append (_("Everything"), "win.level(7)");
            v2.append (_("Notices and Above"), "win.level(5)");
            v2.append (_("Warnings and Errors"), "win.level(4)");
            v2.append (_("Errors Only"), "win.level(3)");
            view_menu.append_section (null, v2);
            var v3 = new GLib.Menu ();
            v3.append (_("Follow New Messages"), "win.follow");
            v3.append (_("Reload"), "win.reload");
            view_menu.append_section (null, v3);
            var v4 = new GLib.Menu ();
            v4.append (_("Show Sidebar"), "win.toggle-sidebar");
            view_menu.append_section (null, v4);
            menu.append_submenu (_("View"), view_menu);
            set_menubar (menu);
            var quit_action = new SimpleAction ("quit", null);
            quit_action.activate.connect (() => quit ());
            add_action (quit_action);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.logs");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var source_action = new SimpleAction ("show-source", VariantType.STRING);
            source_action.activate.connect ((param) => show_source (param.get_string ()));
            add_action (source_action);
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.export", { "<Control>s" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.reload", { "F5" });
            set_accels_for_action ("win.toggle-sidebar", { "F9" });
        }

        public override void activate () {
            if (pending_source != null) {
                string source = pending_source;
                pending_source = null;
                show_source (source);
                return;
            }
            var window = get_active_window ();
            if (window == null) window = new LogsWindow (this);
            window.present ();
        }

        private const string CSS = """
.logs-list {
    background: transparent;
    padding: 0 12px 12px 12px;
}

.logs-list > row {
    border-radius: 8px;
    padding: 0;
}

.logs-list > row:hover {
    background-color: alpha(@window_fg_color, 0.05);
}

.logs-list > row:selected {
    background-color: alpha(@accent_bg_color, 0.2);
    color: inherit;
}

.logs-row {
    padding: 5px 10px;
    font-size: 13px;
}

.logs-time {
    font-feature-settings: "tnum";
    font-size: 12px;
}

.logs-source {
    font-weight: 600;
    font-size: 12px;
}

.logs-message-strong {
    font-weight: 600;
}

.logs-dot {
    min-width: 8px;
    min-height: 8px;
    border-radius: 99px;
}

.logs-dot.logs-error,
.logs-chip.logs-error {
    background-color: @error_color;
}

.logs-dot.logs-warning,
.logs-chip.logs-warning {
    background-color: @warning_color;
}

.logs-dot.logs-notice,
.logs-chip.logs-notice {
    background-color: @link_color;
}

.logs-dot.logs-info {
    background-color: alpha(@window_fg_color, 0.25);
}

.logs-chip.logs-info {
    background-color: alpha(@window_fg_color, 0.45);
}

.logs-chip {
    padding: 2px 10px;
    border-radius: 99px;
    color: white;
    font-size: 12px;
    font-weight: 600;
}

.logs-panel {
    padding: 18px;
    border-radius: 20px;
    background-color: alpha(@window_fg_color, 0.05);
}

.logs-detail-message {
    font-family: monospace;
    font-size: 12px;
    padding: 12px;
    border-radius: 12px;
    background-color: @view_bg_color;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-logs", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-logs", "UTF-8");
        Intl.textdomain ("singularity-logs");
        var app = new LogsApp ();
        new LogsSearchProvider (app).export (app);
        return app.run (args);
    }
}
