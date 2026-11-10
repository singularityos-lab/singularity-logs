using Singularity.Apps.Logs;

void test_journal_line () {
    var e = Journal.parse_json_line ("{\"MESSAGE\":\"Started foo\",\"PRIORITY\":\"3\",\"__REALTIME_TIMESTAMP\":\"1790417999523930\",\"SYSLOG_IDENTIFIER\":\"systemd\",\"_PID\":\"1\"}");
    assert (e != null && e.message == "Started foo" && e.priority == 3 && e.source == "systemd");
    assert (e.time == 1790417999523930 && e.fields["_PID"] == "1");
    var k = Journal.parse_json_line ("{\"MESSAGE\":\"usb 1-1: new device\",\"_TRANSPORT\":\"kernel\",\"SYSLOG_IDENTIFIER\":\"kernel\"}");
    assert (k.source == "kernel" && k.priority == 6);
    var bin = Journal.parse_json_line ("{\"MESSAGE\":[104,105],\"PRIORITY\":\"4\"}");
    assert (bin.message == "hi" && bin.priority == 4);
    assert (Journal.parse_json_line ("not json") == null);
    assert (Journal.parse_json_line ("") == null);
}

void test_text_lines () {
    var a = TextLog.parse_line ("2026-09-26T10:00:05.123+02:00 host sshd[1]: error: connection reset", "auth.log");
    assert (a.time > 0 && a.message.has_prefix ("host sshd") && a.priority == 3);
    var b = TextLog.parse_line ("Sep  2 08:01:02 host cron[5]: job started", "syslog");
    assert (b.time > 0 && b.message == "host cron[5]: job started" && b.priority == 6);
    var c = TextLog.parse_line ("just a line with a warning", "x.log");
    assert (c.time == 0 && c.priority == 4);
}

void test_dmesg () {
    var list = Kernel.parse_dmesg ("<3>[    1.250000] nvme: failed\n<6>[   12.000000] usb 1-1: ok\n\n");
    assert (list.size == 2);
    assert (list[0].priority == 3 && list[0].message == "nvme: failed" && list[0].time > 0);
    assert (list[1].time - list[0].time == 10750000);
}

void test_fields () {
    var e = Journal.parse_fields ({ "MESSAGE=hello=world", "PRIORITY=2", "_SYSTEMD_UNIT=x.service", "bogus", "=x" }, 123);
    assert (e.message == "hello=world" && e.priority == 2 && e.source == "x.service" && e.time == 123);
    assert (!e.fields.has_key ("bogus"));
    var k = Journal.parse_fields ({ "MESSAGE=m", "_TRANSPORT=kernel", "SYSLOG_IDENTIFIER=kernel" }, 0);
    assert (k.source == "kernel" && k.time == 0);
}

void test_matches () {
    var unit = Journal.match_args ("unit:sshd.service");
    assert (unit.length == 1 && unit[0] == "_SYSTEMD_UNIT=sshd.service");
    var ident = Journal.match_args ("ident:cron");
    assert (ident.length == 1 && ident[0] == "SYSLOG_IDENTIFIER=cron");
    assert (Journal.match_args ("journal").length == 0);
    var all = Journal.query_matches (ident, true, 2, "abc");
    assert (string.joinv (" ", all) == "SYSLOG_IDENTIFIER=cron _TRANSPORT=kernel PRIORITY=0 PRIORITY=1 PRIORITY=2 _BOOT_ID=abc");
    assert (Journal.query_matches ({}, false, 7, null).length == 0);
    string? id = Journal.current_boot_id ();
    assert (id == null || (id.length == 32 && !id.contains ("-")));
}

void test_kmsg () {
    assert (Kernel.kmsg_line ("6,1042,5123456,-;usb 1-2: new\\x0atwo\n SUBSYSTEM=usb\n") == "<6>[    5.123456] usb 1-2: new\n<6>[    5.123456] two\n");
    assert (Kernel.kmsg_line ("30,7,42,c;tab\\x09bell\\x07end") == "<30>[    0.000042] tab\tbell end\n");
    assert (Kernel.kmsg_line ("no separator") == null);
    assert (Kernel.kmsg_line ("x,1,2;m") == null);
    assert (Kernel.kmsg_line ("6,1;m") == null);
    var list = Kernel.parse_dmesg (Kernel.kmsg_line ("3,1,2000000,-;boom"));
    assert (list.size == 1 && list[0].priority == 3 && list[0].message == "boom");
    string dir = DirUtils.make_tmp ("kmsg-XXXXXX");
    assert (Kernel.read_kmsg (Path.build_filename (dir, "none")) == null);
    string fake = Path.build_filename (dir, "kmsg");
    FileUtils.set_contents (fake, "4,9,1000000,-;disk warm");
    assert (Kernel.read_kmsg (fake) == "<4>[    1.000000] disk warm\n");
}

void test_groups () {
    unowned Posix.Group? primary = Posix.getgrgid (Posix.getgid ());
    bool found = false;
    foreach (string g in Journal.group_names ()) if (primary != null && g == primary.gr_name) found = true;
    assert (primary == null || found);
}

[DBus (name = "dev.sinty.Logs1")]
public class MockLogs : Object {
    [DBus (visible = false)]
    public bool refuse = false;

    public string read_kernel () throws Error {
        if (refuse) throw new DBusError.ACCESS_DENIED ("no");
        return "<3>[    1.000000] secret\n<6>[    2.000000] fine\n";
    }
}

Gee.List<Entry>? privileged (out Error? failure) {
    var loop = new MainLoop ();
    Gee.List<Entry>? result = null;
    Error? got = null;
    Kernel.read_privileged.begin ((obj, res) => {
        try {
            result = Kernel.read_privileged.end (res);
        } catch (Error e) {
            got = e;
        }
        loop.quit ();
    });
    loop.run ();
    failure = got;
    return result;
}

void test_privileged () {
    string dir = DirUtils.make_tmp ("logs-svc-XXXXXX");
    Kernel.service_dirs = { dir };
    assert (!Kernel.can_elevate ());
    Error? failure;
    privileged (out failure);
    assert (failure is IOError.NOT_FOUND);
    FileUtils.set_contents (Path.build_filename (dir, "dev.sinty.Logs1.service"), "[D-BUS Service]\nName=dev.sinty.Logs1\n");
    assert (Kernel.can_elevate ());

    var bus = new TestDBus (TestDBusFlags.NONE);
    bus.up ();
    Environment.set_variable ("DBUS_SYSTEM_BUS_ADDRESS", bus.get_bus_address (), true);
    var mock = new MockLogs ();
    var conn = Bus.get_sync (BusType.SYSTEM);
    conn.register_object ("/dev/sinty/Logs1", mock);
    conn.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        new Variant ("(su)", "dev.sinty.Logs1", 0), null, DBusCallFlags.NONE, -1);
    var list = privileged (out failure);
    assert (failure == null && list.size == 2 && list[0].message == "secret" && list[0].priority == 3);
    mock.refuse = true;
    privileged (out failure);
    assert (failure is IOError.PERMISSION_DENIED);
    bus.down ();
}

#if HAVE_SINTY_CORE
void test_sealed () {
    string dir = Environment.get_variable ("SEALED_DATA");
    string key = Path.build_filename (dir, "reader.key");
    string cold = Path.build_filename (dir, "cold");
    try {
        var list = SealedLog.collect (key, Path.build_filename (dir, "ring"), cold, "/nonexistent");
        assert (list.size == 24);
        assert (list[0].source == "loader");
        assert (list[0].message == "boot-start");
        assert (list[0].fields["BOOT"] == "1");
        assert (list[0].priority == 6);
        assert (list[0].time == (int64) 1762700001000 * 1000);
        assert (list[1].message == "panic 1 99");
        assert (list[1].priority == 2);
        assert (list[2].message == "blob\nline one\nline two");
        assert (list[23].fields["BOOT"] == "3");
        var tampered = SealedLog.collect (key, Path.build_filename (dir, "ring-tampered"), cold, "/nonexistent");
        bool chain = false;
        bool unopened = false;
        foreach (var e in tampered) {
            if (e.message == "chain: seq 5: previous hash mismatch") chain = true;
            if (e.message == "seq 4: block does not open with this key") unopened = true;
        }
        assert (chain && unopened);
    } catch (Error e) {
        error (e.message);
    }
    try {
        SealedLog.collect (Path.build_filename (dir, "missing.key"), null, null, null);
        assert_not_reached ();
    } catch (Error e) {
    }
}
#endif

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/logs/journal", test_journal_line);
    Test.add_func ("/logs/text", test_text_lines);
    Test.add_func ("/logs/dmesg", test_dmesg);
    Test.add_func ("/logs/fields", test_fields);
    Test.add_func ("/logs/matches", test_matches);
    Test.add_func ("/logs/kmsg", test_kmsg);
    Test.add_func ("/logs/groups", test_groups);
    Test.add_func ("/logs/privileged", test_privileged);
#if HAVE_SINTY_CORE
    Test.add_func ("/logs/sealed", test_sealed);
#endif
    return Test.run ();
}
