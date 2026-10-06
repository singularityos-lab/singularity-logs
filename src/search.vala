namespace Singularity.Apps.Logs {

    public class LogsSearchProvider : Singularity.SearchProviderService {
        private weak LogsApp app;
        private Gee.List<string>? services = null;
        private int64 loaded = 0;

        public LogsSearchProvider (LogsApp app) {
            this.app = app;
        }

        private static bool is_prefix (string term) {
            string t = term.casefold ();
            return t == "log" || t == "logs" || t == _("log").casefold () || t == _("logs").casefold ();
        }

        private async Gee.List<string> known_services (Cancellable? cancellable) {
            int64 now = get_monotonic_time ();
            if (services == null || now - loaded > 60 * TimeSpan.SECOND) {
                services = yield Journal.services (cancellable);
                loaded = now;
            }
            return services;
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            if (terms.length == 0 || !is_prefix (terms[0]) || !Journal.available ()) return {};
            var all = yield known_services (cancellable);
            if (terms.length < 2) return {};
            string query = string.joinv (" ", terms[1:terms.length]).strip ().casefold ();
            if (query == "") return {};
            string[] exact = {};
            string[] prefix = {};
            string[] inside = {};
            foreach (string id in all) {
                string name = Journal.source_name (id).casefold ();
                if (name == query) exact += id;
                else if (name.has_prefix (query)) prefix += id;
                else if (name.contains (query)) inside += id;
            }
            string[] result = {};
            foreach (string id in exact) result += id;
            foreach (string id in prefix) result += id;
            foreach (string id in inside) result += id;
            return result;
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            foreach (string id in ids) {
                if (!id.has_prefix ("unit:") && !id.has_prefix ("ident:")) continue;
                var meta = new Singularity.SearchResultMeta (id, _("Logs of %s").printf (Journal.source_name (id)));
                meta.description = id.has_prefix ("unit:") ? _("Service %s").printf (id.substring (5)) : _("Program messages");
                meta.icon = new ThemedIcon ("dev.sinty.logs");
                meta.add_action ("problems", _("Show Problems"), "dialog-warning-symbolic");
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            app.show_source (id);
            return null;
        }

        public override async Singularity.SearchActivationReply? activate_action (string id, string action_id, string[] terms, uint32 timestamp) throws Error {
            app.show_source (id);
            var window = app.get_active_window ();
            if (action_id == "problems" && window != null) window.activate_action_variant ("win.level", new Variant.int32 (4));
            return null;
        }

        public override void launch_search (string[] terms, uint32 timestamp) {
            app.activate ();
        }
    }
}
