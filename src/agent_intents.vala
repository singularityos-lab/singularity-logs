namespace Singularity.Apps.Logs {

    internal class LogsIntents : Object {

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static string level_id(int priority) {
            if (priority <= 2) return "critical";
            if (priority == 3) return "error";
            if (priority == 4) return "warning";
            if (priority == 5) return "notice";
            if (priority == 6) return "info";
            return "debug";
        }

        private static int max_priority(string level) throws Error {
            switch (level) {
                case "": case "all": return 7;
                case "info": return 6;
                case "notice": return 5;
                case "warning": return 4;
                case "error": return 3;
                case "critical": return 2;
                default: throw new IOError.INVALID_ARGUMENT("unknown level %s", level);
            }
        }

        private static Gee.List<string> sources() {
            var list = new Gee.ArrayList<string>();
            if (Journal.available()) {
                list.add("journal");
                list.add("errors");
                list.add("user");
            }
            list.add("kernel");
            if (SealedLog.available()) list.add("sealed");
            if (Crashes.available()) list.add("crashes");
            foreach (string f in TextLog.files()) list.add("file:" + f);
            return list;
        }

        private static async Gee.List<Entry> load(string source, int boot) throws Error {
            if (source.has_prefix("file:")) {
                string path = source.substring(5);
                if (!(path in TextLog.files())) throw new IOError.NOT_FOUND("%s is not one of the log files; see logs_sources", path);
                return yield TextLog.read(path);
            }
            if ((source == "sealed" || source == "crashes") && CrashLock.required()) {
                throw new IOError.PERMISSION_DENIED("startup and crash records are locked; the person can unlock them in Logs");
            }
            if (source == "sealed") return yield SealedLog.read();
            if (source == "crashes") return yield Crashes.read();
            if (source == "kernel" && !Journal.available()) {
                if (Kernel.mirrored()) return yield Kernel.read_mirror();
                var k = yield Kernel.read_unprivileged();
                if (k == null) throw new IOError.PERMISSION_DENIED("kernel messages need the person to unlock them in Logs");
                return k;
            }
            if (!Journal.available()) throw new IOError.NOT_FOUND("no source %s; see logs_sources", source);
            bool known = source == "journal" || source == "errors" || source == "kernel" || source == "user" || source.has_prefix("unit:") || source.has_prefix("ident:");
            if (!known) throw new IOError.NOT_FOUND("no source %s; see logs_sources", source);
            return yield Journal.read(boot, source == "kernel", source == "user", source == "errors" ? 4 : 7, null, Journal.match_args(source));
        }

        private static void entry(Json.Builder b, Entry e) {
            b.begin_object();
            var dt = e.datetime();
            if (dt != null) b.set_member_name("time").add_string_value(dt.format_iso8601());
            b.set_member_name("level").add_string_value(level_id(e.priority));
            if (e.source != "") b.set_member_name("source").add_string_value(e.source);
            string m = e.message;
            if (m.length > 2000) m = m.substring(0, m.index_of_nth_char(2000)) + "...";
            b.set_member_name("message").add_string_value(m);
            b.end_object();
        }

        private static async void read(LogsApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                string source = text(args, "source");
                if (source == "") source = Journal.available() ? "journal" : "kernel";
                int top = max_priority(text(args, "level"));
                string q = text(args, "query").casefold();
                int limit = args.has_member("limit") ? (int) args.get_int_member("limit").clamp(1, 500) : 50;
                int boot = args.has_member("boot") ? (int) args.get_int_member("boot") : 0;
                int64 since = 0;
                if (args.has_member("since_minutes")) since = (new DateTime.now_utc().to_unix() - args.get_int_member("since_minutes") * 60) * 1000000;
                var all = yield load(source, boot);
                var picked = new Gee.ArrayList<Entry>();
                for (int i = all.size - 1; i >= 0 && picked.size < limit; i--) {
                    var e = all[i];
                    if (e.priority > top) continue;
                    if (since > 0 && e.time > 0 && e.time < since) continue;
                    if (q != "" && !e.message.casefold().contains(q) && !e.source.casefold().contains(q)) continue;
                    picked.add(e);
                }
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("source").add_string_value(source);
                b.set_member_name("scanned").add_int_value(all.size);
                b.set_member_name("order").add_string_value("newest first");
                b.set_member_name("entries").begin_array();
                foreach (var e in picked) entry(b, e);
                b.end_array();
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void problems(LogsApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            int limit = args.has_member("limit") ? (int) args.get_int_member("limit").clamp(1, 200) : 30;
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("problems").begin_array();
            var skipped = new Gee.ArrayList<string>();
            var found = new Gee.ArrayList<Entry>();
            var origin = new Gee.HashMap<Entry, string>();
            string[] wanted = Journal.available() ? new string[] { "errors" } : new string[] { "kernel" };
            foreach (string f in TextLog.files()) wanted += "file:" + f;
            foreach (string s in wanted) {
                try {
                    foreach (var e in yield load(s, 0)) {
                        if (e.priority > 4) continue;
                        found.add(e);
                        origin[e] = s;
                    }
                } catch (Error err) {
                    skipped.add(s + ": " + err.message);
                }
            }
            found.sort((x, y) => x.time > y.time ? -1 : (x.time < y.time ? 1 : 0));
            int n = 0;
            foreach (var e in found) {
                if (n++ == limit) break;
                entry(b, e);
            }
            b.end_array();
            b.set_member_name("total").add_int_value(found.size);
            if (skipped.size > 0) {
                b.set_member_name("not_read").begin_array();
                foreach (string s in skipped) b.add_string_value(s);
                b.end_array();
            }
            b.end_object();
            app.release();
            reply(b.get_root(), null);
        }

        internal static void install(LogsApp app) {
            var agent = app.agent;
            agent.add_intent("logs_sources", "The logs this computer keeps that Logs can read: the system journal, kernel messages, startup and update records, crash reports and log files.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("sources").begin_array();
                    foreach (string s in sources()) b.add_string_value(s);
                    b.end_array();
                    b.set_member_name("journal").add_boolean_value(Journal.available());
                    b.set_member_name("records_locked").add_boolean_value(CrashLock.required());
                    b.end_object();
                    return b.get_root();
                });
            agent.add_async_intent("logs_read", "Read one log, newest first, filtered by level, words and time. source comes from logs_sources.",
                "{\"type\":\"object\",\"properties\":{\"source\":{\"type\":\"string\"},\"level\":{\"type\":\"string\",\"enum\":[\"all\",\"info\",\"notice\",\"warning\",\"error\",\"critical\"]},\"query\":{\"type\":\"string\"},\"since_minutes\":{\"type\":\"integer\"},\"boot\":{\"type\":\"integer\",\"description\":\"0 is this boot, -1 the one before\"},\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    read.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("logs_problems", "Recent errors and warnings across the logs of this boot, newest first, to find out what went wrong.",
                "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    problems.begin(app, args, (owned) reply);
                });
        }
    }
}
