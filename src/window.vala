using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Logs {

    public class LogsWindow : Singularity.Widgets.Window {
        private LogsApp app;
        private AppSidebar sidebar;
        private Gee.HashMap<string, SidebarRow> rows = new Gee.HashMap<string, SidebarRow> ();
        private Box services_box;
        private string current = "";
        private int boot = 0;
        private int min_level = 7;
        private bool current_was_errors = false;
        private string query = "";
        private Gee.List<Entry> entries = new Gee.ArrayList<Entry> ();
        private GLib.ListStore store;
        private SingleSelection selection;
        private ListView list;
        private Stack stack;
        private StatusPage empty;
        private StatusPage loading;
        private SearchBubble search;
        private Label title;
        private Label subtitle;
        private Button level_bubble;
        private Button boot_bubble;
        private Button follow_bubble;
        private Revealer panel_revealer;
        private Label detail_level;
        private Label detail_time;
        private Label detail_source;
        private Label detail_message;
        private Grid detail_fields;
        private Cancellable? loading_cancel = null;
        private Subprocess? follower = null;
        private Gee.List<Boot> boots = new Gee.ArrayList<Boot> ();
        private SimpleAction act_copy;
        private SimpleAction act_source;
        private SimpleAction act_level;
        private SimpleAction act_follow;

        public LogsWindow (LogsApp app) {
            Object (application: app);
            this.app = app;
            set_default_size (1180, 760);
            set_title (_("Logs"));

            sidebar = new AppSidebar (230);
            set_sidebar (sidebar);
            set_sidebar_visible (true);

            search = add_bubble_search (_("Search Logs"), (text) => {
                query = text;
                apply_filter ();
            });
            search.entry.input_hints = InputHints.NO_SPELLCHECK;
            level_bubble = add_bubble_icon ("logs-filter-symbolic", _("Show"), () => show_level_menu ());
            boot_bubble = add_bubble_icon ("system-reboot-symbolic", _("Start of the Computer"), () => show_boot_menu ());
            follow_bubble = add_bubble_icon ("media-playback-start-symbolic", _("Follow New Messages"), () => toggle_follow ());
            add_bubble_icon ("document-save-symbolic", _("Export"), () => export.begin ());

            var act_export = new SimpleAction ("export", null);
            act_export.activate.connect (() => export.begin ());
            add_action (act_export);
            var act_close = new SimpleAction ("close", null);
            act_close.activate.connect (() => close ());
            add_action (act_close);
            act_copy = new SimpleAction ("copy", null);
            act_copy.set_enabled (false);
            act_copy.activate.connect (copy_selected);
            add_action (act_copy);
            var act_find = new SimpleAction ("find", null);
            act_find.activate.connect (() => search.grab_focus_entry ());
            add_action (act_find);
            act_source = new SimpleAction.stateful ("source", VariantType.STRING, new Variant.string (""));
            act_source.activate.connect ((param) => select (param.get_string ()));
            add_action (act_source);
            act_level = new SimpleAction.stateful ("level", VariantType.INT32, new Variant.int32 (min_level));
            act_level.activate.connect ((param) => {
                min_level = param.get_int32 ();
                apply_filter ();
            });
            add_action (act_level);
            act_follow = new SimpleAction.stateful ("follow", null, new Variant.boolean (false));
            act_follow.activate.connect (() => toggle_follow ());
            add_action (act_follow);
            var act_reload = new SimpleAction ("reload", null);
            act_reload.activate.connect (() => {
                stop_follow ();
                load.begin ();
            });
            add_action (act_reload);
            var act_sidebar = new SimpleAction.stateful ("toggle-sidebar", null, new Variant.boolean (true));
            act_sidebar.activate.connect (() => {
                set_sidebar_visible (!get_sidebar_visible ());
                act_sidebar.set_state (new Variant.boolean (get_sidebar_visible ()));
            });
            add_action (act_sidebar);

            var content = new Box (Orientation.HORIZONTAL, 0);
            var main = new Box (Orientation.VERTICAL, 0);
            main.hexpand = true;
            var header = new Box (Orientation.VERTICAL, 2);
            header.margin_start = 24;
            header.margin_end = 24;
            header.margin_bottom = 8;
            header.margin_top = 16;
            Singularity.Widgets.apply_view_edge (header);
            title = new Label ("");
            title.xalign = 0;
            title.add_css_class ("title-2");
            subtitle = new Label ("");
            subtitle.xalign = 0;
            subtitle.add_css_class ("dim-label");
            header.append (title);
            header.append (subtitle);
            main.append (header);

            store = new GLib.ListStore (typeof (Entry));
            selection = new SingleSelection (store);
            selection.autoselect = false;
            selection.can_unselect = true;
            selection.selected = Gtk.INVALID_LIST_POSITION;
            selection.notify["selected"].connect (() => {
                var e = selection.selected_item as Entry;
                act_copy.set_enabled (e != null);
                if (e != null) show_entry (e);
                else close_panel ();
            });
            var factory = new SignalListItemFactory ();
            factory.setup.connect ((obj) => {
                var li = (ListItem) obj;
                var row = new Box (Orientation.HORIZONTAL, 12);
                row.add_css_class ("logs-row");
                var dot = new Box (Orientation.HORIZONTAL, 0);
                dot.add_css_class ("logs-dot");
                dot.valign = Align.CENTER;
                row.append (dot);
                var time = new Label ("");
                time.add_css_class ("logs-time");
                time.add_css_class ("dim-label");
                time.xalign = 0;
                time.width_chars = 15;
                row.append (time);
                var source = new Label ("");
                source.add_css_class ("logs-source");
                source.xalign = 0;
                source.width_chars = 16;
                source.max_width_chars = 16;
                source.ellipsize = Pango.EllipsizeMode.END;
                row.append (source);
                var message = new Label ("");
                message.xalign = 0;
                message.hexpand = true;
                message.ellipsize = Pango.EllipsizeMode.END;
                message.single_line_mode = true;
                row.append (message);
                li.child = row;
            });
            factory.bind.connect ((obj) => {
                var li = (ListItem) obj;
                var e = (Entry) li.item;
                var row = (Box) li.child;
                var dot = row.get_first_child ();
                foreach (string c in new string[] { "logs-error", "logs-warning", "logs-notice", "logs-info" }) dot.remove_css_class (c);
                dot.add_css_class (e.level_class ());
                dot.tooltip_text = e.level_label ();
                var time = (Label) dot.get_next_sibling ();
                var dt = e.datetime ();
                time.label = dt != null ? dt.format ("%d %b %H:%M:%S") : "";
                var source = (Label) time.get_next_sibling ();
                source.label = e.source;
                var message = (Label) source.get_next_sibling ();
                string m = e.message.replace ("\n", " ").strip ();
                message.label = m.length > 400 ? m.substring (0, m.index_of_nth_char (400)) : m;
                message.remove_css_class ("logs-message-strong");
                if (e.priority <= 3) message.add_css_class ("logs-message-strong");
            });
            list = new ListView (selection, factory);
            list.add_css_class ("logs-list");
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = list;

            empty = new StatusPage ();
            empty.icon_name = "dev.sinty.logs";
            loading = new StatusPage ();
            loading.icon_name = "content-loading-symbolic";
            loading.title = _("Reading Logs");
            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named (scroll, "list");
            stack.add_named (empty, "empty");
            stack.add_named (loading, "loading");
            main.append (stack);
            content.append (main);

            panel_revealer = new Revealer ();
            panel_revealer.transition_type = RevealerTransitionType.SLIDE_LEFT;
            panel_revealer.child = build_panel ();
            panel_revealer.hexpand = false;
            panel_revealer.visible = false;
            panel_revealer.notify["child-revealed"].connect (() => {
                if (!panel_revealer.reveal_child && !panel_revealer.child_revealed) panel_revealer.visible = false;
            });
            content.append (panel_revealer);
            set_content (content);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape && panel_revealer.reveal_child) {
                    selection.selected = Gtk.INVALID_LIST_POSITION;
                    return true;
                }
                if ((state & Gdk.ModifierType.CONTROL_MASK) != 0 && (keyval == Gdk.Key.f || keyval == Gdk.Key.F)) {
                    search.grab_focus_entry ();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);
            close_request.connect (() => {
                stop_follow ();
                return false;
            });

            build_sidebar ();
            load_boots.begin ();
        }

        private void build_sidebar () {
            bool journal = Journal.available ();
            sidebar.box.append (new SidebarSectionLabel (_("System")));
            if (journal) {
                add_row ("journal", "view-list-symbolic", _("All Messages"));
                add_row ("errors", "dialog-error-symbolic", _("Problems"));
                add_row ("kernel", "system-run-symbolic", _("Kernel"));
                add_row ("user", "avatar-default-symbolic", _("Your Apps"));
            } else {
                add_row ("kernel", "system-run-symbolic", _("Kernel"));
            }
            services_box = new Box (Orientation.VERTICAL, 0);
            services_box.visible = false;
            services_box.append (new SidebarSectionLabel (_("Services")));
            sidebar.box.append (services_box);
            var files = TextLog.files ();
            if (files.size > 0) {
                sidebar.box.append (new SidebarSectionLabel (_("Log Files")));
                foreach (string f in files) {
                    string name = f.has_prefix ("/var/log/") ? f.substring (9) : f;
                    add_row ("file:" + f, "text-x-generic-symbolic", name);
                }
            }
            select (journal ? "journal" : (files.size > 0 ? "file:" + files[0] : "kernel"));
        }

        private void add_row (string id, string icon, string label, Box? box = null) {
            var row = new SidebarRow (icon, label);
            row.clicked.connect (() => select (id));
            rows[id] = row;
            (box ?? sidebar.box).append (row);
        }

        private static bool is_service (string id) {
            return id.has_prefix ("unit:") || id.has_prefix ("ident:");
        }

        private bool is_journal (string id) {
            return id == "journal" || id == "errors" || id == "user" || is_service (id) || (id == "kernel" && Journal.available ());
        }

        public void show_source (string id) {
            if (is_service (id)) {
                if (!Journal.available ()) return;
                if (!rows.has_key (id)) add_row (id, "application-x-executable-symbolic", Journal.source_name (id), services_box);
                services_box.visible = true;
            } else if (!rows.has_key (id)) {
                return;
            }
            select (id);
        }

        private void select (string id) {
            stop_follow ();
            current = id;
            if (id == "errors") min_level = 4;
            else if (current_was_errors) min_level = 7;
            current_was_errors = id == "errors";
            foreach (var e in rows.entries) e.value.set_active (e.key == id);
            boot_bubble.visible = is_journal (id);
            follow_bubble.visible = is_journal (id) && boot == 0;
            act_source.set_state (new Variant.string (id));
            act_follow.set_enabled (follow_bubble.visible);
            load.begin ();
        }

        private string current_label () {
            if (current.has_prefix ("file:")) return current.substring (5);
            if (is_service (current)) return Journal.source_name (current);
            switch (current) {
                case "journal": return _("All Messages");
                case "errors": return _("Problems");
                case "kernel": return _("Kernel");
                case "user": return _("Your Apps");
                default: return "";
            }
        }

        private async void load_boots () {
            if (Journal.available ()) boots = yield Journal.boots ();
        }

        private async void load () {
            if (loading_cancel != null) loading_cancel.cancel ();
            var cancel = new Cancellable ();
            loading_cancel = cancel;
            stack.visible_child_name = "loading";
            title.label = current_label ();
            subtitle.label = "";
            Gee.List<Entry> result = new Gee.ArrayList<Entry> ();
            string? problem = null;
            try {
                if (current.has_prefix ("file:")) {
                    result = yield TextLog.read (current.substring (5));
                } else if (current == "kernel" && !Journal.available ()) {
                    var k = yield Kernel.read_unprivileged ();
                    if (k == null) problem = "kernel-locked";
                    else result = k;
                } else {
                    result = yield Journal.read (boot, current == "kernel", current == "user", current == "errors" ? 4 : 7, cancel, Journal.match_args (current));
                }
            } catch (Error e) {
                if (cancel.is_cancelled ()) return;
                problem = e.message;
            }
            if (cancel.is_cancelled ()) return;
            entries = result;
            if (problem == "kernel-locked") {
                show_locked_kernel ();
                return;
            }
            if (problem != null) {
                empty.icon_name = "dialog-warning";
                empty.title = _("Could Not Read This Log");
                empty.description = problem;
                empty.child = pill (_("Try Again"), () => load.begin ());
                stack.visible_child_name = "empty";
                return;
            }
            apply_filter ();
            scroll_to_end ();
        }

        private void scroll_to_end () {
            int frames = 0;
            list.add_tick_callback ((widget, clock) => {
                if (++frames < 2) return Source.CONTINUE;
                uint n = store.get_n_items ();
                if (n > 0) list.scroll_to (n - 1, ListScrollFlags.NONE, null);
                return Source.REMOVE;
            });
        }

        private void show_locked_kernel () {
            empty.icon_name = "changes-prevent-symbolic";
            empty.title = _("The Kernel Log Is Protected");
            empty.description = _("Reading it needs an administrator password.");
            var unlock = new Button.with_label (_("Show Kernel Log"));
            unlock.add_css_class ("suggested-action");
            unlock.add_css_class ("pill");
            unlock.halign = Align.CENTER;
            unlock.clicked.connect (() => {
                Kernel.read_privileged.begin ((obj, res) => {
                    try {
                        entries = Kernel.read_privileged.end (res);
                        apply_filter ();
                    } catch (Error e) {
                        empty.description = e.message;
                    }
                });
            });
            empty.child = unlock;
            stack.visible_child_name = "empty";
        }

        private Button pill (string label, owned WelcomePage.ActionCallback callback) {
            WelcomePage.ActionCallback cb = (owned) callback;
            var b = new Button.with_label (label);
            b.add_css_class ("pill");
            b.add_css_class ("suggested-action");
            b.halign = Align.CENTER;
            b.clicked.connect (() => cb ());
            return b;
        }

        private void show_nothing_logged () {
            var old = stack.get_child_by_name ("none");
            if (old != null) stack.remove (old);
            var page = new WelcomePage ();
            page.is_section = true;
            page.app_icon_name = "dev.sinty.logs";
            if (min_level < 7) {
                page.title = _("No Problems");
                page.subtitle = _("Nothing at this level was logged.");
                if (current == "errors") {
                    page.add_action ("text-x-generic", _("All Messages"), _("Every message the system and your apps logged"), () => select ("journal"));
                } else {
                    page.add_action ("text-x-generic", _("Show All Levels"), _("Include information and debug messages"), () => {
                        min_level = 7;
                        apply_filter ();
                    });
                }
            } else {
                page.title = _("No Messages");
                page.subtitle = _("This log is empty.");
                if (current != "journal") page.add_action ("text-x-generic", _("All Messages"), _("Every message the system and your apps logged"), () => select ("journal"));
            }
            page.add_action ("emblem-synchronizing", _("Reload"), _("Read this log again"), () => load.begin ());
            stack.add_named (page, "none");
            stack.visible_child_name = "none";
        }

        private bool matches (Entry e, string q) {
            if (e.priority > min_level) return false;
            if (q == "") return true;
            return e.message.casefold ().contains (q) || e.source.casefold ().contains (q);
        }

        private void apply_filter () {
            act_level.set_state (new Variant.int32 (min_level));
            string q = query.strip ().casefold ();
            var shown = new Object[0];
            int errors = 0, warnings = 0;
            foreach (var e in entries) {
                if (e.priority <= 3) errors++;
                else if (e.priority == 4) warnings++;
                if (matches (e, q)) shown += e;
            }
            selection.selected = Gtk.INVALID_LIST_POSITION;
            store.remove_all ();
            store.splice (0, 0, shown);
            string counts = ngettext ("%d message", "%d messages", shown.length).printf (shown.length);
            if (errors > 0) counts += " · " + ngettext ("%d error", "%d errors", errors).printf (errors);
            if (warnings > 0) counts += " · " + ngettext ("%d warning", "%d warnings", warnings).printf (warnings);
            if (is_journal (current) && boot != 0) counts += " · " + boot_label (boot);
            subtitle.label = counts;
            if (shown.length == 0 && q != "") {
                empty.icon_name = "system-search";
                empty.title = _("No Messages");
                empty.description = _("Nothing matches your search.");
                empty.child = pill (_("Clear Search"), () => search.clear ());
                stack.visible_child_name = "empty";
            } else if (shown.length == 0) {
                show_nothing_logged ();
            } else {
                stack.visible_child_name = "list";
            }
        }

        private void popup_menu (ContextMenu menu) {
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private ContextMenu bubble_menu (Widget bubble) {
            var menu = new ContextMenu (stack);
            Graphene.Rect bounds;
            if (bubble.compute_bounds (stack, out bounds)) {
                var rect = Gdk.Rectangle ();
                rect.x = (int) bounds.origin.x;
                rect.y = (int) bounds.origin.y;
                rect.width = (int) bounds.size.width;
                rect.height = (int) bounds.size.height;
                menu.pointing_to = rect;
            }
            menu.position = PositionType.BOTTOM;
            return menu;
        }

        private void show_level_menu () {
            var menu = bubble_menu (level_bubble);
            string[] labels = { _("Everything"), _("Notices and Above"), _("Warnings and Errors"), _("Errors Only") };
            int[] levels = { 7, 5, 4, 3 };
            for (int i = 0; i < labels.length; i++) {
                int lvl = levels[i];
                menu.add_item (labels[i], lvl == min_level ? "object-select-symbolic" : null, () => {
                    min_level = lvl;
                    apply_filter ();
                });
            }
            popup_menu (menu);
        }

        private string boot_label (int index) {
            if (index == 0) return _("Current Session");
            foreach (var b in boots) {
                if (b.index != index) continue;
                var start = new DateTime.from_unix_local (b.first / 1000000);
                return _("Started %s").printf (start.format ("%-d %b %H:%M"));
            }
            return _("Earlier Session");
        }

        private void show_boot_menu () {
            var menu = bubble_menu (boot_bubble);
            int shown = 0;
            foreach (var b in boots) {
                if (shown++ >= 10) break;
                int idx = b.index;
                menu.add_item (boot_label (idx), idx == boot ? "object-select-symbolic" : null, () => {
                    boot = idx;
                    select (current);
                });
            }
            if (shown == 0) menu.add_item (_("Current Session"), "object-select-symbolic", () => { });
            popup_menu (menu);
        }

        private void toggle_follow () {
            if (follower != null) {
                stop_follow ();
                return;
            }
            string[] argv = { "journalctl", "-o", "json", "--no-pager", "-f", "-n", "0" };
            foreach (string m in Journal.match_args (current)) argv += m;
            if (current == "kernel") argv += "-k";
            if (current == "user") argv += "--user";
            try {
                follower = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            } catch (Error e) {
                return;
            }
            act_follow.set_state (new Variant.boolean (true));
            follow_bubble.icon_name = "media-playback-pause-symbolic";
            follow_bubble.tooltip_text = _("Stop Following");
            follow_bubble.add_css_class ("suggested-action");
            read_follow.begin (new DataInputStream (follower.get_stdout_pipe ()));
        }

        private async void read_follow (DataInputStream input) {
            while (follower != null) {
                string? line = null;
                try {
                    line = yield input.read_line_utf8_async (Priority.DEFAULT, null);
                } catch (Error e) {
                    break;
                }
                if (line == null) break;
                var e = Journal.parse_json_line (line);
                if (e == null) continue;
                entries.add (e);
                if (matches (e, query.strip ().casefold ())) {
                    store.append (e);
                    if (stack.visible_child_name != "list") stack.visible_child_name = "list";
                    if (selection.selected == Gtk.INVALID_LIST_POSITION) scroll_to_end ();
                }
            }
        }

        private void stop_follow () {
            if (follower != null) {
                follower.force_exit ();
                follower = null;
            }
            if (act_follow != null) act_follow.set_state (new Variant.boolean (false));
            if (follow_bubble != null) {
                follow_bubble.icon_name = "media-playback-start-symbolic";
                follow_bubble.tooltip_text = _("Follow New Messages");
                follow_bubble.remove_css_class ("suggested-action");
            }
        }

        private Widget build_panel () {
            var outer = new Box (Orientation.VERTICAL, 0);
            outer.set_size_request (380, -1);
            outer.margin_end = 16;
            outer.margin_bottom = 16;
            Singularity.Widgets.apply_view_edge (outer);
            var panel = new Box (Orientation.VERTICAL, 12);
            panel.add_css_class ("logs-panel");
            panel.vexpand = true;
            var top = new Box (Orientation.HORIZONTAL, 8);
            detail_level = new Label ("");
            detail_level.add_css_class ("logs-chip");
            detail_level.halign = Align.START;
            detail_level.valign = Align.CENTER;
            top.append (detail_level);
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            top.append (spacer);
            var copy = new Button.from_icon_name ("edit-copy-symbolic");
            copy.add_css_class ("flat");
            copy.add_css_class ("circular");
            copy.tooltip_text = _("Copy Message");
            copy.clicked.connect (copy_selected);
            top.append (copy);
            var close = new Button.from_icon_name ("window-close-symbolic");
            close.add_css_class ("flat");
            close.add_css_class ("circular");
            close.tooltip_text = _("Close");
            close.clicked.connect (() => selection.selected = Gtk.INVALID_LIST_POSITION);
            top.append (close);
            panel.append (top);
            detail_source = new Label ("");
            detail_source.xalign = 0;
            detail_source.add_css_class ("title-4");
            detail_source.wrap = true;
            panel.append (detail_source);
            detail_time = new Label ("");
            detail_time.xalign = 0;
            detail_time.add_css_class ("dim-label");
            panel.append (detail_time);
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            var inner = new Box (Orientation.VERTICAL, 14);
            detail_message = new Label ("");
            detail_message.xalign = 0;
            detail_message.yalign = 0;
            detail_message.wrap = true;
            detail_message.wrap_mode = Pango.WrapMode.WORD_CHAR;
            detail_message.selectable = true;
            detail_message.add_css_class ("logs-detail-message");
            inner.append (detail_message);
            detail_fields = new Grid ();
            detail_fields.column_spacing = 12;
            detail_fields.row_spacing = 4;
            inner.append (detail_fields);
            scroll.child = inner;
            panel.append (scroll);
            outer.append (panel);
            return outer;
        }

        private static string friendly_field (string key) {
            switch (key) {
                case "_PID": return _("Process");
                case "_UID": return _("User ID");
                case "_COMM": return _("Command");
                case "_EXE": return _("Program");
                case "_CMDLINE": return _("Command Line");
                case "_SYSTEMD_UNIT": return _("Service");
                case "_SYSTEMD_USER_UNIT": return _("User Service");
                case "_HOSTNAME": return _("Computer");
                case "_TRANSPORT": return _("Transport");
                case "CODE_FILE": return _("Source File");
                case "CODE_LINE": return _("Line");
                case "CODE_FUNC": return _("Function");
                case "ERRNO": return _("Error Number");
                default: return key;
            }
        }

        private void show_entry (Entry e) {
            detail_level.label = e.level_label ();
            foreach (string c in new string[] { "logs-error", "logs-warning", "logs-notice", "logs-info" }) detail_level.remove_css_class (c);
            detail_level.add_css_class (e.level_class ());
            detail_source.label = e.source != "" ? e.source : _("Unknown Source");
            var dt = e.datetime ();
            detail_time.label = dt != null ? dt.format ("%A %-d %B %Y, %H:%M:%S") : "";
            detail_message.label = e.message;
            Widget? child;
            while ((child = detail_fields.get_first_child ()) != null) detail_fields.remove (child);
            string[] keys = { "_SYSTEMD_UNIT", "_SYSTEMD_USER_UNIT", "_COMM", "_EXE", "_PID", "_UID", "_CMDLINE", "CODE_FILE", "CODE_LINE", "CODE_FUNC", "ERRNO", "_HOSTNAME", "_TRANSPORT" };
            int row = 0;
            foreach (string k in keys) {
                if (!e.fields.has_key (k)) continue;
                var kl = new Label (friendly_field (k));
                kl.xalign = 1;
                kl.yalign = 0;
                kl.add_css_class ("dim-label");
                var vl = new Label (e.fields[k]);
                vl.xalign = 0;
                vl.wrap = true;
                vl.wrap_mode = Pango.WrapMode.WORD_CHAR;
                vl.selectable = true;
                vl.hexpand = true;
                detail_fields.attach (kl, 0, row, 1, 1);
                detail_fields.attach (vl, 1, row, 1, 1);
                row++;
            }
            panel_revealer.visible = true;
            panel_revealer.reveal_child = true;
        }

        private void copy_selected () {
            var e = selection.selected_item as Entry;
            if (e != null) get_clipboard ().set_text (e.message);
        }

        private void close_panel () {
            panel_revealer.reveal_child = false;
        }

        private async void export () {
            var dialog = new FileDialog ();
            dialog.title = _("Export Log");
            string safe = current_label ().replace ("/", "-");
            dialog.initial_name = "%s %s.txt".printf (safe, new DateTime.now_local ().format ("%Y-%m-%d %H%M"));
            try {
                var file = yield dialog.save (this, null);
                if (file == null) return;
                var sb = new StringBuilder ();
                for (uint i = 0; i < store.get_n_items (); i++) {
                    var e = (Entry) store.get_item (i);
                    var dt = e.datetime ();
                    sb.append_printf ("%s  %-8s %s: %s\n", dt != null ? dt.format ("%Y-%m-%d %H:%M:%S") : "", e.level_label (), e.source, e.message);
                }
                yield file.replace_contents_async (sb.str.data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
            }
        }
    }
}
