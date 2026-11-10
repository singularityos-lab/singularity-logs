[CCode (cheader_filename = "systemd/sd-journal.h")]
namespace SdJournal {
    [CCode (cname = "int", cprefix = "SD_JOURNAL_", has_type_id = false)]
    [Flags]
    public enum OpenFlags {
        LOCAL_ONLY,
        RUNTIME_ONLY,
        SYSTEM,
        CURRENT_USER
    }

    [CCode (cname = "int", cprefix = "SD_JOURNAL_", has_type_id = false)]
    public enum Wakeup {
        NOP,
        APPEND,
        INVALIDATE
    }

    [Compact]
    [CCode (cname = "sd_journal", cprefix = "sd_journal_", free_function = "sd_journal_close")]
    public class Journal {
        [CCode (cname = "sd_journal_open")]
        public static int open (out Journal ret, OpenFlags flags);
        public int next ();
        public int previous ();
        public int seek_head ();
        public int seek_tail ();
        public int get_realtime_usec (out uint64 usec);
        public void restart_data ();
        [CCode (cname = "sd_journal_enumerate_data")]
        public int enumerate_data ([CCode (type = "const void **", array_length_type = "size_t")] out unowned uint8[] data);
        public int add_match ([CCode (type = "const void *", array_length_type = "size_t")] uint8[] data);
        public int add_disjunction ();
        public int add_conjunction ();
        public void flush_matches ();
        public int query_unique (string field);
        [CCode (cname = "sd_journal_enumerate_unique")]
        public int enumerate_unique ([CCode (type = "const void **", array_length_type = "size_t")] out unowned uint8[] data);
        public void restart_unique ();
        public int wait (uint64 timeout_usec);
        public int set_data_threshold (size_t size);
    }
}
