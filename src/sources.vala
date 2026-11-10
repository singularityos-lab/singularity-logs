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

    [CCode (cname = "getgroups", cheader_filename = "unistd.h")]
    private extern int sys_getgroups (int size, [CCode (array_length = false)] Posix.gid_t[] list);

    public class Journal : Object {
        public const int LIMIT = 6000;
        private delegate Object? Work ();

        public static bool available () {
#if HAVE_SD_JOURNAL
            if (!FileUtils.test ("/var/log/journal", FileTest.IS_DIR) && !FileUtils.test ("/run/log/journal", FileTest.IS_DIR)) return false;
            return open_journal (false) != null;
#else
            return false;
#endif
        }

        public static void finish (Entry e) {
            e.message = e.fields["MESSAGE"] ?? "";
            if (e.fields.has_key ("__REALTIME_TIMESTAMP")) e.time = int64.parse (e.fields["__REALTIME_TIMESTAMP"]);
            if (e.fields.has_key ("PRIORITY")) e.priority = int.parse (e.fields["PRIORITY"]);
            string? src = e.fields["SYSLOG_IDENTIFIER"] ?? e.fields["_SYSTEMD_UNIT"] ?? e.fields["_COMM"];
            if (e.fields.has_key ("_TRANSPORT") && e.fields["_TRANSPORT"] == "kernel") src = "kernel";
            e.source = src ?? "";
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
            finish (e);
            return e;
        }

        public static Entry parse_fields (string[] fields, uint64 realtime) {
            var e = new Entry ();
            foreach (unowned string field in fields) {
                int eq = field.index_of_char ('=');
                if (eq <= 0) continue;
                e.fields[field.substring (0, eq)] = field.substring (eq + 1).make_valid ();
            }
            if (realtime > 0) e.fields["__REALTIME_TIMESTAMP"] = realtime.to_string ();
            finish (e);
            return e;
        }

        public static string[] match_args (string source) {
            if (source.has_prefix ("unit:")) return { "_SYSTEMD_UNIT=" + source.substring (5) };
            if (source.has_prefix ("ident:")) return { "SYSLOG_IDENTIFIER=" + source.substring (6) };
            return {};
        }

        public static string[] query_matches (string[] matches, bool kernel, int max_priority, string? boot_id) {
            string[] all = {};
            foreach (string m in matches) all += m;
            if (kernel) all += "_TRANSPORT=kernel";
            if (max_priority < 7) {
                for (int p = 0; p <= max_priority; p++) all += "PRIORITY=%d".printf (p);
            }
            if (boot_id != null) all += "_BOOT_ID=" + boot_id;
            return all;
        }

        public static string source_name (string source) {
            if (source.has_prefix ("unit:")) {
                string unit = source.substring (5);
                return unit.has_suffix (".service") ? unit.substring (0, unit.length - 8) : unit;
            }
            if (source.has_prefix ("ident:")) return source.substring (6);
            return source;
        }

        public static string? current_boot_id () {
            try {
                string id;
                FileUtils.get_contents ("/proc/sys/kernel/random/boot_id", out id);
                return id.strip ().replace ("-", "");
            } catch (FileError e) {
                return null;
            }
        }

        private static async Object? in_thread (owned Work work) {
            Object? result = null;
            SourceFunc resume = in_thread.callback;
            new Thread<void*> ("logs-journal", () => {
                result = work ();
                Idle.add ((owned) resume);
                return null;
            });
            yield;
            return result;
        }

#if HAVE_SD_JOURNAL
        private static SdJournal.Journal? open_journal (bool user_only) {
            SdJournal.Journal? j = null;
            if (SdJournal.Journal.open (out j, user_only ? SdJournal.OpenFlags.CURRENT_USER : SdJournal.OpenFlags.LOCAL_ONLY) < 0) return null;
            return (owned) j;
        }

        private static string text (uint8[] data) {
            var copy = new uint8[data.length + 1];
            Memory.copy (copy, data, data.length);
            copy[data.length] = 0;
            return ((string) copy).dup ();
        }

        private static Entry current (SdJournal.Journal j) {
            string[] fields = {};
            unowned uint8[] data;
            j.restart_data ();
            while (j.enumerate_data (out data) > 0) fields += text (data);
            uint64 usec = 0;
            j.get_realtime_usec (out usec);
            return parse_fields (fields, usec);
        }

        private static void apply (SdJournal.Journal j, string[] matches) {
            foreach (string m in matches) j.add_match (m.data);
        }

        private static Gee.ArrayList<Entry> collect (bool user_only, string[] matches, int limit) {
            var list = new Gee.ArrayList<Entry> ();
            var j = open_journal (user_only);
            if (j == null) return list;
            apply (j, matches);
            j.seek_tail ();
            while (list.size < limit && j.previous () > 0) list.add (current (j));
            list.sort ((a, b) => a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
            return list;
        }

        private static Gee.ArrayList<string> unique (string field) {
            var values = new Gee.ArrayList<string> ();
            var j = open_journal (false);
            if (j == null || j.query_unique (field) < 0) return values;
            unowned uint8[] data;
            string prefix = field + "=";
            while (j.enumerate_unique (out data) > 0) {
                string value = text (data);
                if (value.has_prefix (prefix)) values.add (value.substring (prefix.length).make_valid ());
            }
            return values;
        }

        private static Gee.ArrayList<Boot> list_boots () {
            var list = new Gee.ArrayList<Boot> ();
            var j = open_journal (false);
            if (j == null) return list;
            foreach (string id in unique ("_BOOT_ID")) {
                j.flush_matches ();
                j.add_match (("_BOOT_ID=" + id).data);
                var b = new Boot ();
                b.id = id;
                uint64 usec = 0;
                j.seek_head ();
                if (j.next () > 0 && j.get_realtime_usec (out usec) >= 0) b.first = (int64) usec;
                j.seek_tail ();
                if (j.previous () > 0 && j.get_realtime_usec (out usec) >= 0) b.last = (int64) usec;
                list.add (b);
            }
            list.sort ((a, b) => a.first < b.first ? -1 : (a.first > b.first ? 1 : 0));
            for (int i = 0; i < list.size; i++) list[i].index = i - (list.size - 1);
            return list;
        }
#endif

        public static async Gee.List<Boot> boots () {
#if HAVE_SD_JOURNAL
            var list = (Gee.ArrayList<Boot>) yield in_thread (() => list_boots ());
            list.sort ((a, b) => b.index - a.index);
            return list;
#else
            return new Gee.ArrayList<Boot> ();
#endif
        }

        private static async string? boot_id_for (int boot) {
            if (boot == 0) return current_boot_id ();
            foreach (var b in yield boots ()) if (b.index == boot) return b.id;
            return null;
        }

        public static async Gee.List<Entry> read (int boot, bool kernel, bool user_only, int max_priority, Cancellable? cancel, string[] matches = {}) throws Error {
#if HAVE_SD_JOURNAL
            string[] wanted = matches;
            string? id = yield boot_id_for (boot);
            if (id == null) return new Gee.ArrayList<Entry> ();
            string[] all = query_matches (wanted, kernel, max_priority, id);
            return (Gee.ArrayList<Entry>) yield in_thread (() => collect (user_only, all, LIMIT));
#else
            return new Gee.ArrayList<Entry> ();
#endif
        }

        public static async Gee.List<Entry> recent_errors (int count, Cancellable? cancel) throws Error {
#if HAVE_SD_JOURNAL
            string[] all = query_matches ({}, false, 3, current_boot_id ());
            var list = (Gee.ArrayList<Entry>) yield in_thread (() => collect (false, all, count));
            var newest_first = new Gee.ArrayList<Entry> ();
            for (int i = list.size - 1; i >= 0; i--) newest_first.add (list[i]);
            return newest_first;
#else
            return new Gee.ArrayList<Entry> ();
#endif
        }

        public static async Gee.List<string> services (Cancellable? cancel) {
            var list = new Gee.ArrayList<string> ();
#if HAVE_SD_JOURNAL
            var names = new Gee.HashSet<string> ();
            var units = (Gee.ArrayList<string>) yield in_thread (() => unique ("_SYSTEMD_UNIT"));
            var idents = (Gee.ArrayList<string>) yield in_thread (() => unique ("SYSLOG_IDENTIFIER"));
            foreach (string u in units) {
                if (!u.has_suffix (".service") || u.contains ("@")) continue;
                if (names.add (source_name ("unit:" + u))) list.add ("unit:" + u);
            }
            foreach (string t in idents) {
                if (t == "" || t.contains ("/") || t.contains (" ")) continue;
                if (names.add (t)) list.add ("ident:" + t);
            }
#endif
            return list;
        }

        public static string[] group_names () {
            string[] names = {};
            var gids = new Posix.gid_t[256];
            int n = sys_getgroups (gids.length, gids);
            for (int i = 0; i < n; i++) {
                unowned Posix.Group? g = Posix.getgrgid (gids[i]);
                if (g != null) names += g.gr_name;
            }
            unowned Posix.Group? primary = Posix.getgrgid (Posix.getgid ());
            if (primary != null) names += primary.gr_name;
            return names;
        }

        public static bool can_read_system () {
            string[] groups = { "systemd-journal", "adm", "wheel" };
            foreach (string g in group_names ()) foreach (string w in groups) if (g == w) return true;
            return Posix.getuid () == 0;
        }
    }

    public class Follower : Object {
        public signal void entry (Entry e);
        private string[] matches;
        private bool user_only;
        private int running = 0;
        private Thread<void*>? thread = null;

        public Follower (string[] matches, bool kernel, bool user_only) {
            this.matches = Journal.query_matches (matches, kernel, 7, null);
            this.user_only = user_only;
        }

        public bool start () {
#if HAVE_SD_JOURNAL
            AtomicInt.set (ref running, 1);
            thread = new Thread<void*> ("logs-follow", () => {
                SdJournal.Journal? j = null;
                if (SdJournal.Journal.open (out j, user_only ? SdJournal.OpenFlags.CURRENT_USER : SdJournal.OpenFlags.LOCAL_ONLY) < 0) return null;
                foreach (string m in matches) j.add_match (m.data);
                j.seek_tail ();
                j.previous ();
                while (AtomicInt.get (ref running) == 1) {
                    j.wait (250000);
                    while (AtomicInt.get (ref running) == 1 && j.next () > 0) {
                        string[] fields = {};
                        unowned uint8[] data;
                        j.restart_data ();
                        while (j.enumerate_data (out data) > 0) {
                            var copy = new uint8[data.length + 1];
                            Memory.copy (copy, data, data.length);
                            fields += ((string) copy).dup ();
                        }
                        uint64 usec = 0;
                        j.get_realtime_usec (out usec);
                        var e = Journal.parse_fields (fields, usec);
                        Idle.add (() => {
                            if (AtomicInt.get (ref running) == 1) entry (e);
                            return Source.REMOVE;
                        });
                    }
                }
                return null;
            });
            return true;
#else
            return false;
#endif
        }

        public void stop () {
            AtomicInt.set (ref running, 0);
            if (thread != null) {
                thread.join ();
                thread = null;
            }
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

        public const string SERVICE = "dev.sinty.Logs1";
        public static string[] service_dirs = { "/usr/share/dbus-1/system-services", "/usr/local/share/dbus-1/system-services" };

        public static bool can_elevate () {
            foreach (string dir in service_dirs) {
                if (FileUtils.test (Path.build_filename (dir, SERVICE + ".service"), FileTest.IS_REGULAR)) return true;
            }
            return false;
        }

        public static string? kmsg_line (string record) {
            int semi = record.index_of_char (';');
            if (semi <= 0) return null;
            string[] head = record.substring (0, semi).split (",");
            if (head.length < 3) return null;
            int64 pri = 0, usec = 0;
            if (!int64.try_parse (head[0], out pri) || !int64.try_parse (head[2], out usec) || pri < 0 || usec < 0) return null;
            string body = record.substring (semi + 1);
            int nl = body.index_of_char ('\n');
            if (nl >= 0) body = body.substring (0, nl);
            var message = new StringBuilder ();
            for (int i = 0; i < body.length; i++) {
                if (body[i] == '\\' && i + 3 < body.length && body[i + 1] == 'x') {
                    int hi = body[i + 2].xdigit_value ();
                    int lo = body[i + 3].xdigit_value ();
                    int v = hi * 16 + lo;
                    if (hi >= 0 && lo >= 0) {
                        message.append_c (v == '\n' || v == '\t' || v >= 0x20 ? (char) v : ' ');
                        i += 3;
                        continue;
                    }
                }
                message.append_c (body[i]);
            }
            var out_text = new StringBuilder ();
            foreach (string line in message.str.split ("\n")) {
                out_text.append_printf ("<%d>[%5" + int64.FORMAT + ".%06" + int64.FORMAT + "] %s\n", (int) pri, usec / 1000000, usec % 1000000, line);
            }
            return out_text.str;
        }

        public static string? read_kmsg (string path) {
            int fd = Posix.open (path, Posix.O_RDONLY | Posix.O_NONBLOCK | Posix.O_CLOEXEC);
            if (fd < 0) return null;
            var text = new StringBuilder ();
            var buf = new uint8[16385];
            while (true) {
                ssize_t n = Posix.read (fd, buf, buf.length - 1);
                if (n < 0 && Posix.errno == Posix.EPIPE) continue;
                if (n < 0 && Posix.errno == Posix.EAGAIN) break;
                if (n <= 0) {
                    if (n < 0 && text.len == 0) {
                        Posix.close (fd);
                        return null;
                    }
                    break;
                }
                buf[n] = 0;
                string? line = kmsg_line ((string) buf);
                if (line != null) text.append (line);
            }
            Posix.close (fd);
            return text.str;
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
            if (!can_elevate ()) throw new IOError.NOT_FOUND (_("Reading the kernel log needs the system log service"));
            var bus = yield Bus.get (BusType.SYSTEM);
            Variant reply;
            try {
                reply = yield bus.call (SERVICE, "/dev/sinty/Logs1", SERVICE, "ReadKernel", null,
                    new VariantType ("(s)"), DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, null);
            } catch (Error e) {
                string? remote = DBusError.get_remote_error (e);
                if (remote == "org.freedesktop.DBus.Error.AccessDenied") throw new IOError.PERMISSION_DENIED (_("Reading the kernel log was not authorized"));
                DBusError.strip_remote_error (e);
                throw new IOError.FAILED ("%s", e.message);
            }
            return parse_dmesg (reply.get_child_value (0).get_string ());
        }

        public static async Gee.List<Entry>? read_unprivileged () {
            string? text = read_kmsg ("/dev/kmsg");
            return text != null ? parse_dmesg (text) : null;
        }
    }

    public class SealedLog : Object {
        public const string RING = "/var/lib/sealedlog/ring";
        public const string DIR = "/var/log/sealedlog";

        public static string key_path () {
            return Path.build_filename (Environment.get_user_data_dir (), "sealedlog", "reader.key");
        }

        public static bool available () {
#if HAVE_SINTY_CORE
            return FileUtils.test (key_path (), FileTest.EXISTS)
                && (FileUtils.test (RING, FileTest.EXISTS) || FileUtils.test (DIR, FileTest.IS_DIR));
#else
            return false;
#endif
        }

#if HAVE_SINTY_CORE
        public static Gee.List<Entry> collect (string key, string? ring, string? cold, string? dictionary) throws Error {
            SintyCore.LogEntries? found;
            int rc = SintyCore.logs_sealed (key, ring, cold, dictionary, 0, out found);
            if (rc < 0) throw new IOError.FAILED (strerror (-rc));
            var list = new Gee.ArrayList<Entry> ();
            for (size_t i = 0; i < found.count (); i++) {
                unowned SintyCore.LogEntry? raw = found.at (i);
                var e = new Entry ();
                e.time = (int64) raw.realtime_usec;
                e.priority = raw.priority;
                e.source = (string) raw.identifier;
                e.message = (string) raw.message;
                e.fields["BOOT"] = (string) raw.boot_id;
                e.fields["SEQ"] = raw.seq.to_string ();
                list.add (e);
            }
            return list;
        }
#endif

        public static async Gee.List<Entry> read () throws Error {
#if HAVE_SINTY_CORE
            Gee.List<Entry>? list = null;
            Error? failure = null;
            SourceFunc resume = read.callback;
            string key = key_path ();
            new Thread<void> ("sealed-log", () => {
                try {
                    list = collect (key, null, null, null);
                } catch (Error e) {
                    failure = e;
                }
                Idle.add ((owned) resume);
            });
            yield;
            if (failure != null) throw failure;
            return list;
#else
            throw new IOError.NOT_SUPPORTED ("sealed log reader not built in");
#endif
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
