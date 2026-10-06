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

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/logs/journal", test_journal_line);
    Test.add_func ("/logs/text", test_text_lines);
    Test.add_func ("/logs/dmesg", test_dmesg);
    return Test.run ();
}
