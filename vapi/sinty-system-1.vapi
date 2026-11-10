[CCode (cheader_filename = "sinty-system/v1.h", lower_case_cprefix = "sinty_")]
namespace SintyCore {
    [CCode (cname = "SintyLogEntry", has_type_id = false, destroy_function = "")]
    public struct LogEntry {
        public uint64 realtime_usec;
        public uint64 monotonic_usec;
        public uint64 seq;
        public int32 pid;
        public uint8 priority;
        public char boot_id[40];
        public char identifier[64];
        public char unit[128];
        public char message[2048];
    }

    [Compact]
    [CCode (cname = "SintyLogEntries", free_function = "sinty_logs_entries_free")]
    public class LogEntries {
        [CCode (cname = "sinty_logs_entries_count")]
        public size_t count ();
        [CCode (cname = "sinty_logs_entries_at")]
        public unowned LogEntry? at (size_t i);
    }

    [CCode (cname = "sinty_logs_sealed")]
    public int logs_sealed (string key, string? ring, string? cold, string? dictionary, uint32 boots, out LogEntries? list);
}
