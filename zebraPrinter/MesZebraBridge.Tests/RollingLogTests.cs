// The local log file. A service has no console, so this file is the only record at
// the machine -- spec section 3 calls it out because on 2026-09-29 the bridge's
// output survived only because someone happened to redirect it.
//
// Every test writes into its own temp directory and deletes it afterwards.

using System;
using System.IO;
using System.Text.RegularExpressions;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class RollingLogTests : IDisposable
    {
        private readonly string _dir;

        public RollingLogTests()
        {
            _dir = Path.Combine(Path.GetTempPath(), "MesZebraBridgeTests_" + Guid.NewGuid().ToString("N"));
        }

        public void Dispose()
        {
            try { if (Directory.Exists(_dir)) Directory.Delete(_dir, true); }
            catch (Exception) { }
        }

        [Fact]
        public void A_line_carries_a_local_timestamp_with_offset_a_level_and_the_message()
        {
            var log = new RollingLog(_dir, 14, false);

            log.Info("bound 'Zebra GX420d (RAW)' on port USB002");

            string text = File.ReadAllText(log.CurrentPath);
            Assert.Matches(
                @"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2} INFO bound 'Zebra GX420d \(RAW\)' on port USB002",
                text);
        }

        [Fact]
        public void The_file_name_carries_the_date_so_it_rolls_daily()
        {
            var log = new RollingLog(_dir, 14, false);
            log.Info("hello");

            string name = Path.GetFileName(log.CurrentPath);
            Assert.Matches(@"^bridge-\d{8}\.log$", name);
            Assert.Contains(DateTime.Now.ToString("yyyyMMdd"), name);
        }

        [Fact]
        public void The_directory_is_created_on_first_write()
        {
            Assert.False(Directory.Exists(_dir));
            var log = new RollingLog(_dir, 14, false);
            log.Info("hello");
            Assert.True(Directory.Exists(_dir));
        }

        [Fact]
        public void A_multi_line_message_becomes_one_line_so_the_log_stays_greppable()
        {
            var log = new RollingLog(_dir, 14, false);

            log.Error("queue not found: 'X'\nvisible:\n  A\n  B");

            string[] lines = File.ReadAllLines(log.CurrentPath);
            Assert.Single(lines);
            Assert.Contains("visible: A B", lines[0]);
        }

        [Fact]
        public void Writes_append_rather_than_truncate()
        {
            var log = new RollingLog(_dir, 14, false);
            log.Info("first");
            log.Info("second");

            string[] lines = File.ReadAllLines(log.CurrentPath);
            Assert.Equal(2, lines.Length);
            Assert.EndsWith("first", lines[0]);
            Assert.EndsWith("second", lines[1]);
        }

        [Fact]
        public void A_log_older_than_the_retention_window_is_pruned_on_the_first_write()
        {
            Directory.CreateDirectory(_dir);
            string stale = Path.Combine(_dir,
                "bridge-" + DateTime.Now.AddDays(-40).ToString("yyyyMMdd") + ".log");
            string recent = Path.Combine(_dir,
                "bridge-" + DateTime.Now.AddDays(-2).ToString("yyyyMMdd") + ".log");
            File.WriteAllText(stale, "old\n");
            File.WriteAllText(recent, "recent\n");

            var log = new RollingLog(_dir, 14, false);
            log.Info("hello");

            Assert.False(File.Exists(stale));
            Assert.True(File.Exists(recent));
            Assert.True(File.Exists(log.CurrentPath));
        }

        [Fact]
        public void A_file_in_the_directory_that_is_not_ours_is_left_alone()
        {
            Directory.CreateDirectory(_dir);
            string foreign = Path.Combine(_dir, "notes.txt");
            File.WriteAllText(foreign, "keep me\n");

            var log = new RollingLog(_dir, 1, false);
            log.Info("hello");

            Assert.True(File.Exists(foreign));
        }

        [Fact]
        public void An_unwritable_directory_does_not_throw_because_a_print_must_not_fail_on_logging()
        {
            // A path that cannot be created on Windows. The bridge has to keep
            // printing regardless -- a lost log line is not worth a lost label.
            var log = new RollingLog("Z:\\definitely\\not\\a\\real\\volume\\logs", 14, false);

            log.Info("this must not throw");
            log.Error("nor this");
        }
    }
}
