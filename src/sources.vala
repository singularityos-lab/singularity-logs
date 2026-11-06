namespace Singularity.Apps.Logs {

    public class Entry : Object {
        public int64 time;
        public int priority = 6;
        public string source = "";
        public string message = "";
        public Gee.TreeMap<string, string> fields = new Gee.TreeMap<string, string> ();

        public string level_label () {
            if (priority <= 2) return _("Critical");
            if (priority == 3) return _("Error");
            if (priority == 4) return _("Warning");
            if (priority == 5) return _("Notice");
            if (priority == 6) return _("Info");
            return _("Debug");
        }

        public string level_class () {
            if (priority <= 3) return "logs-error";
            if (priority == 4) return "logs-warning";
            if (priority == 5) return "logs-notice";
            return "logs-info";
        }

        public DateTime? datetime () {
            if (time <= 0) return null;
            return new DateTime.from_unix_local (time / 1000000).add (time % 1000000);
        }
    }

    public class Boot : Object {
        public int index;
        public string id;
        public int64 first;
        public int64 last;
    }

    public class Journal : Object {
        public const int LIMIT = 6000;

        public static bool available () {
            return Environment.find_program_in_path ("journalctl") != null
                && (FileUtils.test ("/var/log/journal", FileTest.IS_DIR) || FileUtils.test ("/run/log/journal", FileTest.IS_DIR));
        }

        public static Entry? parse_json_line (string line) {
            if (line.strip () == "") return null;
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (line);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return null;
            var obj = root.get_object ();
            var e = new Entry ();
            foreach (string key in obj.get_members ()) {
                var node = obj.get_member (key);
                if (node.get_node_type () != Json.NodeType.VALUE) {
                    if (key == "MESSAGE" && node.get_node_type () == Json.NodeType.ARRAY) {
                        var sb = new StringBuilder ();
                        foreach (var b in node.get_array ().get_elements ()) sb.append_c ((char) b.get_int ());
                        e.fields[key] = sb.str.make_valid ();
                    }
                    continue;
                }
                e.fields[key] = node.get_value ().type () == typeof (string) ? node.get_string () : node.get_value ().strdup_contents ();
            }
            e.message = e.fields["MESSAGE"] ?? "";
            if (e.fields.has_key ("__REALTIME_TIMESTAMP")) e.time = int64.parse (e.fields["__REALTIME_TIMESTAMP"]);
            if (e.fields.has_key ("PRIORITY")) e.priority = int.parse (e.fields["PRIORITY"]);
            string? src = e.fields["SYSLOG_IDENTIFIER"] ?? e.fields["_SYSTEMD_UNIT"] ?? e.fields["_COMM"];
            if (e.fields.has_key ("_TRANSPORT") && e.fields["_TRANSPORT"] == "kernel") src = "kernel";
            e.source = src ?? "";
            return e;
        }

        public static string[] match_args (string source) {
            if (source.has_prefix ("unit:")) return { "-u", source.substring (5) };
            if (source.has_prefix ("ident:")) return { "-t", source.substring (6) };
            return {};
        }

        public static string source_name (string source) {
            if (source.has_prefix ("unit:")) {
                string unit = source.substring (5);
                return unit.has_suffix (".service") ? unit.substring (0, unit.length - 8) : unit;
            }
            if (source.has_prefix ("ident:")) return source.substring (6);
            return source;
        }

        public static async Gee.List<Entry> read (int boot, bool kernel, bool user_only, int max_priority, Cancellable? cancel, string[] matches = {}) throws Error {
            string[] argv = { "journalctl", "-o", "json", "--no-pager", "-n", LIMIT.to_string (), "-b", boot.to_string () };
            foreach (string m in matches) argv += m;
            if (kernel) argv += "-k";
            if (user_only) argv += "--user";
            if (max_priority < 7) {
                argv += "-p";
                argv += max_priority.to_string ();
            }
            var proc = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string output, errors;
            yield proc.communicate_utf8_async (null, cancel, out output, out errors);
            var list = new Gee.ArrayList<Entry> ();
            foreach (unowned string line in (output ?? "").split ("\n")) {
                var e = parse_json_line (line);
                if (e != null) list.add (e);
            }
            if (list.size == 0 && errors != null && errors.strip () != "" && !proc.get_successful ()) {
                throw new IOError.FAILED ("%s", errors.strip ());
            }
            return list;
        }

        public static async Gee.List<Boot> boots () {
            var list = new Gee.ArrayList<Boot> ();
            try {
                var proc = new Subprocess.newv ({ "journalctl", "--list-boots", "-o", "json", "--no-pager" },
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string output;
                yield proc.communicate_utf8_async (null, null, out output, null);
                var parser = new Json.Parser ();
                parser.load_from_data (output ?? "[]");
                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.ARRAY) {
                    foreach (var node in root.get_array ().get_elements ()) {
                        var o = node.get_object ();
                        var b = new Boot ();
                        b.index = (int) o.get_int_member ("index");
                        b.id = o.get_string_member ("boot_id");
                        b.first = o.get_int_member ("first_entry");
                        b.last = o.get_int_member ("last_entry");
                        list.add (b);
                    }
                }
            } catch (Error e) {
            }
            list.sort ((a, b) => b.index - a.index);
            return list;
        }

        public static async Gee.List<Entry> recent_errors (int count, Cancellable? cancel) throws Error {
            var proc = new Subprocess.newv ({ "journalctl", "-o", "json", "--no-pager", "-b", "0", "-p", "3", "-n", count.to_string () },
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string output;
            yield proc.communicate_utf8_async (null, cancel, out output, null);
            var list = new Gee.ArrayList<Entry> ();
            foreach (unowned string line in (output ?? "").split ("\n")) {
                var e = parse_json_line (line);
                if (e != null) list.insert (0, e);
            }
            return list;
        }

        private static async string[] field_values (string field, Cancellable? cancel) {
            try {
                var proc = new Subprocess.newv ({ "journalctl", "--no-pager", "-F", field }, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string output;
                yield proc.communicate_utf8_async (null, cancel, out output, null);
                return (output ?? "").strip ().split ("\n");
            } catch (Error e) {
                return {};
            }
        }

        public static async Gee.List<string> services (Cancellable? cancel) {
            var list = new Gee.ArrayList<string> ();
            var names = new Gee.HashSet<string> ();
            string[] units = {};
            string[] idents = {};
            int pending = 2;
            field_values.begin ("_SYSTEMD_UNIT", cancel, (obj, res) => {
                units = field_values.end (res);
                if (--pending == 0) services.callback ();
            });
            field_values.begin ("SYSLOG_IDENTIFIER", cancel, (obj, res) => {
                idents = field_values.end (res);
                if (--pending == 0) services.callback ();
            });
            yield;
            foreach (string u in units) {
                if (!u.has_suffix (".service") || u.contains ("@")) continue;
                if (names.add (source_name ("unit:" + u))) list.add ("unit:" + u);
            }
            foreach (string t in idents) {
                if (t == "" || t.contains ("/") || t.contains (" ")) continue;
                if (names.add (t)) list.add ("ident:" + t);
            }
            return list;
        }

        public static bool can_read_system () {
            string[] groups = { "systemd-journal", "adm", "wheel" };
            try {
                string output;
                Process.spawn_sync (null, { "id", "-Gn" }, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL, null, out output, null, null);
                foreach (string g in output.strip ().split (" ")) foreach (string w in groups) if (g == w) return true;
            } catch (Error e) {
            }
            return Posix.getuid () == 0;
        }
    }

    public class TextLog : Object {
        public const int LIMIT = 6000;
        private static Regex? iso_re = null;
        private static Regex? bsd_re = null;

        public static Gee.List<string> files () {
            var list = new Gee.ArrayList<string> ();
            collect ("/var/log", list, 0);
            foreach (string path in new string[] { "/run/boot-splash.log", "/run/singularity/session-common.log", "/run/singularity/labwc.log" }) {
                if (Posix.access (path, Posix.R_OK) == 0) list.add (path);
            }
            list.sort ((a, b) => Path.get_basename (a).collate (Path.get_basename (b)));
            return list;
        }

        private static void collect (string dir, Gee.List<string> list, int depth) {
            if (depth > 2) return;
            try {
                var d = Dir.open (dir);
                string? name;
                while ((name = d.read_name ()) != null) {
                    string path = Path.build_filename (dir, name);
                    if (FileUtils.test (path, FileTest.IS_DIR)) {
                        if (name != "journal" && path != Crashes.DIR && path != SealedLog.DIR) collect (path, list, depth + 1);
                        continue;
                    }
                    if (name.has_suffix (".gz") || name.has_suffix (".xz") || name.has_suffix (".zst") || name.has_suffix (".bz2")) continue;
                    if (name == "wtmp" || name == "btmp" || name == "lastlog" || name == "faillog") continue;
                    if (Posix.access (path, Posix.R_OK) != 0) continue;
                    list.add (path);
                }
            } catch (FileError e) {
            }
        }

        public static int guess_priority (string text) {
            string t = text.down ();
            if (t.contains ("panic") || t.contains ("fatal") || t.contains ("critical") || t.contains ("segfault")) return 2;
            if (t.contains ("error") || t.contains ("failed") || t.contains ("failure") || t.contains (" err ") || t.contains ("denied")) return 3;
            if (t.contains ("warn")) return 4;
            return 6;
        }

        public static Entry parse_line (string line, string source) {
            var e = new Entry ();
            e.source = source;
            e.message = line;
            try {
                if (iso_re == null) iso_re = new Regex ("^(\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2})(?:[.,]\\d+)?(Z|[+-]\\d{2}:?\\d{2})?\\s+(.*)$");
                if (bsd_re == null) bsd_re = new Regex ("^([A-Z][a-z]{2})\\s+(\\d{1,2})\\s+(\\d{2}):(\\d{2}):(\\d{2})\\s+(.*)$");
                MatchInfo m;
                if (iso_re.match (line, 0, out m)) {
                    string stamp = m.fetch (1).replace (" ", "T") + (m.fetch (2) != "" ? m.fetch (2) : "");
                    var dt = new DateTime.from_iso8601 (stamp, new TimeZone.local ());
                    if (dt != null) {
                        e.time = dt.to_unix () * 1000000;
                        e.message = m.fetch (3);
                    }
                } else if (bsd_re.match (line, 0, out m)) {
                    string[] months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
                    int month = 0;
                    for (int i = 0; i < 12; i++) if (months[i] == m.fetch (1)) month = i + 1;
                    if (month > 0) {
                        var now = new DateTime.now_local ();
                        var dt = new DateTime.local (now.get_year (), month, int.parse (m.fetch (2)), int.parse (m.fetch (3)), int.parse (m.fetch (4)), int.parse (m.fetch (5)));
                        if (dt != null && dt.compare (now.add_days (1)) > 0) dt = dt.add_years (-1);
                        if (dt != null) {
                            e.time = dt.to_unix () * 1000000;
                            e.message = m.fetch (6);
                        }
                    }
                }
            } catch (RegexError err) {
            }
            e.priority = guess_priority (e.message);
            return e;
        }

        public static async Gee.List<Entry> read (string path) throws Error {
            var file = File.new_for_path (path);
            uint8[] data;
            yield file.load_contents_async (null, out data, null);
            string text = ((string) data).make_valid ((ssize_t) data.length);
            var lines = text.split ("\n");
            var list = new Gee.ArrayList<Entry> ();
            int start = int.max (0, lines.length - LIMIT);
            string name = Path.get_basename (path);
            for (int i = start; i < lines.length; i++) {
                if (lines[i].strip () == "") continue;
                list.add (parse_line (lines[i], name));
            }
            return list;
        }
    }

    public class Kernel : Object {
        public static Gee.List<Entry> parse_dmesg (string output) {
            var list = new Gee.ArrayList<Entry> ();
            int64 boot_time = get_real_time () - get_monotonic_time ();
            foreach (unowned string line in output.split ("\n")) {
                if (line.strip () == "") continue;
                var e = new Entry ();
                e.source = "kernel";
                string rest = line;
                int prio = 6;
                if (rest.has_prefix ("<")) {
                    int close = rest.index_of (">");
                    if (close > 0) {
                        int raw = int.parse (rest.substring (1, close - 1));
                        prio = raw & 7;
                        rest = rest.substring (close + 1);
                    }
                }
                if (rest.has_prefix ("[")) {
                    int close = rest.index_of ("]");
                    if (close > 0) {
                        double secs = double.parse (rest.substring (1, close - 1).strip ());
                        e.time = boot_time + (int64) (secs * 1000000);
                        rest = rest.substring (close + 1).strip ();
                    }
                }
                e.priority = prio;
                e.message = rest;
                list.add (e);
            }
            return list;
        }

        public const string MIRROR = "/run/log/kernel.log";

        public static bool mirrored () {
            return Posix.access (MIRROR, Posix.R_OK) == 0;
        }

        public static bool can_elevate () {
            return Environment.find_program_in_path ("pkexec") != null;
        }

        public static async Gee.List<Entry> read_mirror () throws Error {
            var text = new StringBuilder ();
            foreach (string path in new string[] { MIRROR + ".1", MIRROR }) {
                if (Posix.access (path, Posix.R_OK) != 0) continue;
                uint8[] data;
                yield File.new_for_path (path).load_contents_async (null, out data, null);
                text.append ((string) data);
            }
            var list = parse_dmesg (text.str);
            if (list.size > TextLog.LIMIT) return list.slice (list.size - TextLog.LIMIT, list.size);
            return list;
        }

        public static async Gee.List<Entry> read_privileged () throws Error {
            var proc = new Subprocess.newv ({ "pkexec", "dmesg", "-r" }, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string output, errors;
            yield proc.communicate_utf8_async (null, null, out output, out errors);
            if (!proc.get_successful ()) throw new IOError.PERMISSION_DENIED (_("Reading the kernel log was not authorized"));
            return parse_dmesg (output ?? "");
        }

        public static async Gee.List<Entry>? read_unprivileged () {
            try {
                var proc = new Subprocess.newv ({ "dmesg", "-r" }, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string output;
                yield proc.communicate_utf8_async (null, null, out output, null);
                if (!proc.get_successful ()) return null;
                return parse_dmesg (output ?? "");
            } catch (Error e) {
                return null;
            }
        }
    }

    public class SealedLog : Object {
        public const string TOOL = "/usr/libexec/sealedlogd";
        public const string DIR = "/var/log/sealedlog";

        public static bool available () {
            return FileUtils.test (TOOL, FileTest.IS_EXECUTABLE)
                && FileUtils.test (Path.build_filename (Environment.get_user_data_dir (), "sealedlog", "reader.key"), FileTest.EXISTS);
        }

        public static Gee.List<Entry> parse (string output) {
            var list = new Gee.ArrayList<Entry> ();
            string boot = "";
            foreach (unowned string raw in output.split ("\n")) {
                string line = raw.strip ();
                if (line == "") continue;
                if (line.has_prefix ("== boot ")) {
                    boot = line.substring (8).strip ();
                    continue;
                }
                var parts = Regex.split_simple ("\\s+", line);
                if (parts.length < 4) continue;
                var e = new Entry ();
                var dt = new DateTime.from_iso8601 (parts[0] + "T" + parts[1], new TimeZone.local ());
                if (dt != null) e.time = dt.to_unix () * 1000000 + dt.get_microsecond ();
                e.source = parts[2];
                e.message = string.joinv (" ", parts[3:parts.length]);
                e.priority = TextLog.guess_priority (e.message);
                if (boot != "") e.fields["BOOT"] = boot;
                list.add (e);
            }
            return list;
        }

        public static async Gee.List<Entry> read () throws Error {
            var proc = new Subprocess.newv ({ TOOL, "read" }, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string output, errors;
            yield proc.communicate_utf8_async (null, null, out output, out errors);
            if (!proc.get_successful ()) throw new IOError.FAILED ((errors ?? "").strip ());
            var list = parse (output ?? "");
            list.sort ((a, b) => a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
            return list;
        }
    }

    public class Crashes : Object {
        public const string DIR = "/var/log/pstore";

        public static bool available () {
            return FileUtils.test (DIR, FileTest.IS_DIR) && Posix.access (DIR, Posix.R_OK | Posix.X_OK) == 0;
        }

        private static int64 stamp (string name) {
            if (name.length != 15 || name[8] != '-') return 0;
            var t = new DateTime.local (int.parse (name.substring (0, 4)), int.parse (name.substring (4, 2)), int.parse (name.substring (6, 2)),
                int.parse (name.substring (9, 2)), int.parse (name.substring (11, 2)), double.parse (name.substring (13, 2)));
            return t != null ? t.to_unix () * 1000000 : 0;
        }

        public static async Gee.List<Entry> read () throws Error {
            var list = new Gee.ArrayList<Entry> ();
            var names = new Gee.ArrayList<string> ();
            var d = Dir.open (DIR);
            string? name;
            while ((name = d.read_name ()) != null) {
                if (FileUtils.test (Path.build_filename (DIR, name), FileTest.IS_DIR)) names.add (name);
            }
            names.sort ((a, b) => strcmp (a, b));
            foreach (string crash in names) {
                int64 when = stamp (crash);
                string dir = Path.build_filename (DIR, crash);
                var files = new Gee.ArrayList<string> ();
                var cd = Dir.open (dir);
                string? f;
                while ((f = cd.read_name ()) != null) files.add (f);
                files.sort ((a, b) => strcmp (a, b));
                var head = new Entry ();
                head.time = when;
                head.priority = 2;
                head.source = "pstore";
                head.message = _("The system stopped unexpectedly. What the kernel saved before the restart follows.");
                head.fields["CRASH"] = crash;
                list.add (head);
                foreach (string file in files) {
                    string path = Path.build_filename (dir, file);
                    if (Posix.access (path, Posix.R_OK) != 0) continue;
                    uint8[] data;
                    yield File.new_for_path (path).load_contents_async (null, out data, null);
                    foreach (var e in Kernel.parse_dmesg ((string) data)) {
                        e.time = when;
                        e.source = "pstore";
                        e.fields["CRASH"] = crash;
                        e.fields["FILE"] = file;
                        list.add (e);
                    }
                }
            }
            return list;
        }
    }

    public class CrashLock : Object {
        public const string ACTION = "dev.sinty.logs.read-crashes";
        public const string POLICY = "/usr/share/polkit-1/actions/dev.sinty.logs.policy";
        private static bool unlocked;

        public static bool required () {
            return !unlocked && FileUtils.test (POLICY, FileTest.EXISTS);
        }

        private static uint64 start_time () {
            string stat;
            try {
                FileUtils.get_contents ("/proc/self/stat", out stat);
            } catch (Error e) {
                return 0;
            }
            var rest = stat.substring (stat.last_index_of (")") + 2).split (" ");
            return rest.length > 19 ? uint64.parse (rest[19]) : 0;
        }

        public static async bool unlock () throws Error {
            var bus = yield Bus.get (BusType.SYSTEM);
            var subject = new VariantBuilder (new VariantType ("a{sv}"));
            subject.add ("{sv}", "pid", new Variant.uint32 ((uint32) Posix.getpid ()));
            subject.add ("{sv}", "start-time", new Variant.uint64 (start_time ()));
            var details = new VariantBuilder (new VariantType ("a{ss}"));
            var reply = yield bus.call ("org.freedesktop.PolicyKit1", "/org/freedesktop/PolicyKit1/Authority",
                "org.freedesktop.PolicyKit1.Authority", "CheckAuthorization",
                new Variant ("((s@a{sv})s@a{ss}us)", "unix-process", subject.end (), ACTION, details.end (), 1u, ""),
                new VariantType ("((bba{ss}))"), DBusCallFlags.NONE, int.MAX, null);
            unlocked = reply.get_child_value (0).get_child_value (0).get_boolean ();
            return unlocked;
        }
    }
}
