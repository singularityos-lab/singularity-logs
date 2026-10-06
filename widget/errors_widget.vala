using Gtk;
using Singularity;

namespace Singularity.Apps.Logs {

    public class ErrorsWidgetProvider : Object, OverviewWidgetProvider {
        public string id { get { return "logs.recent-errors"; } }
        public string provider_id { get { return "dev.sinty.logs"; } }
        public string display_name { get { return _("Recent Errors"); } }
        public string icon_name { get { return "dialog-error-symbolic"; } }
        private WidgetSize[] sizes = { WidgetSize (2, 2), WidgetSize (4, 2) };
        public WidgetSize[] supported_sizes { get { return sizes; } }

        public Gtk.Widget create_instance (string instance_id, WidgetSize size, Variant? config) {
            return new ErrorsWidget (size);
        }
    }

    public class ErrorsWidget : Box {
        private Box list;
        private Label count;
        private uint timer = 0;
        private Cancellable? cancel = null;
        private int rows_max;

        public ErrorsWidget (WidgetSize size) {
            Object (orientation: Orientation.VERTICAL, spacing: 6);
            add_css_class ("overview-widget-card");
            margin_start = 14;
            margin_end = 14;
            margin_top = 12;
            margin_bottom = 12;
            rows_max = size.h >= 2 ? 5 : 2;

            var header = new Button ();
            header.has_frame = false;
            header.add_css_class ("flat");
            header.tooltip_text = _("Show Problems in Logs");
            var hbox = new Box (Orientation.HORIZONTAL, 8);
            var icon = new Image.from_icon_name ("dev.sinty.logs");
            icon.pixel_size = 24;
            hbox.append (icon);
            var title = new Label (_("Recent Errors"));
            title.add_css_class ("heading");
            title.xalign = 0;
            title.hexpand = true;
            hbox.append (title);
            count = new Label ("");
            count.add_css_class ("dim-label");
            count.add_css_class ("caption");
            hbox.append (count);
            header.child = hbox;
            header.clicked.connect (() => launch ("--problems"));
            append (header);

            list = new Box (Orientation.VERTICAL, 4);
            list.vexpand = true;
            append (list);

            map.connect (() => {
                refresh ();
                if (timer == 0) timer = Timeout.add_seconds (60, () => {
                    refresh ();
                    return Source.CONTINUE;
                });
            });
            unmap.connect (() => {
                if (timer != 0) Source.remove (timer);
                timer = 0;
                if (cancel != null) cancel.cancel ();
            });
        }

        private void refresh () {
            if (!Journal.available ()) {
                show_status ("dialog-information-symbolic", _("The system journal is not available"));
                return;
            }
            if (cancel != null) cancel.cancel ();
            cancel = new Cancellable ();
            var c = cancel;
            Journal.recent_errors.begin (rows_max, c, (obj, res) => {
                if (c.is_cancelled ()) return;
                try {
                    fill (Journal.recent_errors.end (res));
                } catch (Error e) {
                    show_status ("dialog-warning-symbolic", _("Could not read the journal"));
                }
            });
        }

        private void clear () {
            Widget? child;
            while ((child = list.get_first_child ()) != null) list.remove (child);
        }

        private void show_status (string icon_name, string text) {
            clear ();
            count.label = "";
            var box = new Box (Orientation.VERTICAL, 6);
            box.valign = Align.CENTER;
            box.vexpand = true;
            var icon = new Image.from_icon_name (icon_name);
            icon.pixel_size = 32;
            icon.add_css_class ("dim-label");
            box.append (icon);
            var label = new Label (text);
            label.add_css_class ("dim-label");
            label.wrap = true;
            label.justify = Justification.CENTER;
            box.append (label);
            list.append (box);
        }

        private void fill (Gee.List<Entry> entries) {
            if (entries.size == 0) {
                show_status ("object-select-symbolic", _("No errors since the computer started"));
                return;
            }
            clear ();
            count.label = entries.size >= rows_max ? _("Latest %d").printf (rows_max) : ngettext ("%d error", "%d errors", entries.size).printf (entries.size);
            foreach (var e in entries) list.append (row (e));
        }

        private Widget row (Entry e) {
            var button = new Button ();
            button.has_frame = false;
            button.add_css_class ("flat");
            button.add_css_class ("overview-widget-tile");
            var box = new Box (Orientation.VERTICAL, 2);
            box.margin_start = 4;
            box.margin_end = 4;
            box.margin_top = 2;
            box.margin_bottom = 2;
            var top = new Box (Orientation.HORIZONTAL, 6);
            var source = new Label (e.source != "" ? e.source : _("Unknown Source"));
            source.add_css_class ("caption-heading");
            source.xalign = 0;
            source.hexpand = true;
            source.ellipsize = Pango.EllipsizeMode.END;
            top.append (source);
            var dt = e.datetime ();
            var time = new Label (dt != null ? dt.format ("%H:%M") : "");
            time.add_css_class ("caption");
            time.add_css_class ("dim-label");
            top.append (time);
            box.append (top);
            string text = e.message.replace ("\n", " ").strip ();
            var message = new Label (text.char_count () > 160 ? text.substring (0, text.index_of_nth_char (160)) : text);
            message.add_css_class ("caption");
            message.xalign = 0;
            message.ellipsize = Pango.EllipsizeMode.END;
            message.single_line_mode = true;
            box.append (message);
            button.child = box;
            string? unit = e.fields["_SYSTEMD_UNIT"];
            string? ident = e.fields["SYSLOG_IDENTIFIER"];
            string target = unit != null && unit.has_suffix (".service") && !unit.contains ("@") ? "unit:" + unit : (ident != null && ident != "" ? "ident:" + ident : "");
            button.clicked.connect (() => {
                if (target != "") launch ("--service=" + GLib.Shell.quote (target));
                else launch ("--problems");
            });
            return button;
        }

        private void launch (string args) {
            var info = new DesktopAppInfo ("dev.sinty.logs.desktop");
            string exe = info != null && info.get_executable () != null ? info.get_executable () : "singularity-logs";
            try {
                var app = AppInfo.create_from_commandline (GLib.Shell.quote (exe) + " " + args, null, AppInfoCreateFlags.NONE);
                app.launch (null, get_display ().get_app_launch_context ());
            } catch (Error e) {
                warning ("Recent errors widget: %s", e.message);
            }
        }
    }

    [CCode (cname = "singularity_logs_widget_new")]
    public static Object singularity_logs_widget_new () {
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            Intl.bindtextdomain ("singularity-logs", Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale"));
            Intl.bind_textdomain_codeset ("singularity-logs", "UTF-8");
        } catch (Error e) {
        }
        return new ErrorsWidgetProvider ();
    }
}
