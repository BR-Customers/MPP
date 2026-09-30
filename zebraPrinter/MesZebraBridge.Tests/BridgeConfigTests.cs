// The conf file and the command line. Spec 12.1 leaves the FORMAT open; this is
// the assumption, and these tests are where it is pinned. The LOCATION (beside the
// exe) and the no-compiled-in-values rule are settled by spec 7 step 4 and 10.1.
//
// A typo must never stop the bridge listening, so an unknown key or a bad number
// is a warning the log will name, not a startup failure.

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class BridgeConfigTests
    {
        [Fact]
        public void Nothing_deployment_specific_is_compiled_in()
        {
            // Spec 10.1: "Nothing may be compiled into the bridge binary." An earlier
            // revision of this plan carried a DefaultGatewayAddress of 10.20.11.53 --
            // the DEVELOPMENT gateway on a laptop, correct on 2026-09-29 and stale
            // that same evening. A hardcoded address is invisible when it is wrong.
            Type t = typeof(BridgeConfig);
            Assert.Null(t.GetField("DefaultGatewayAddress",
                BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic));

            BridgeConfig c = BridgeConfig.Parse(new string[0]);
            Assert.Null(c.GatewayAddress);
            Assert.Null(c.Queue);
        }

        [Fact]
        public void An_absent_file_is_all_defaults_and_not_an_error()
        {
            BridgeConfig c = BridgeConfig.Load(Path.Combine(
                Path.GetTempPath(), "no-such-bridge-conf-" + Guid.NewGuid().ToString("N") + ".conf"));

            Assert.Null(c.Queue);                 // unconfigured, not detected
            Assert.Null(c.GatewayAddress);        // install will refuse, not widen
            Assert.Equal(9100, c.Port);
            Assert.Equal(14, c.LogRetainDays);
            Assert.Equal(BridgeConfig.DefaultLogDirectory, c.LogDirectory);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void The_conf_lives_beside_the_executable_not_under_ProgramData()
        {
            // Spec 7 step 4: the deployment is "MesZebraBridge.exe and its conf file".
            // Spec 10.1: the gateway address "lives in the conf file shipped beside
            // the executable -- authored once for all 54 installs".
            string exeDir = Path.GetDirectoryName(typeof(BridgeConfig).Assembly.Location);

            Assert.Equal(Path.Combine(exeDir, "MesZebraBridge.conf"), BridgeConfig.DefaultPath);
        }

        [Fact]
        public void The_log_directory_is_machine_state_under_ProgramData()
        {
            // Not beside the exe: logs are machine state, not shipped configuration,
            // and the deployment directory stays two files.
            Assert.Contains("BlueRidge", BridgeConfig.DefaultLogDirectory);
            Assert.Contains("MesZebraBridge", BridgeConfig.DefaultLogDirectory);
            Assert.EndsWith("logs", BridgeConfig.DefaultLogDirectory);
        }

        [Fact]
        public void Keys_are_case_insensitive_and_values_are_trimmed()
        {
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "queue =  Zebra GX420d (RAW)  ",
                "GATEWAYADDRESS=172.17.10.161",
                "Port = 9100",
                "LogRetainDays=30"
            });

            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Equal(9100, c.Port);
            Assert.Equal(30, c.LogRetainDays);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void Comments_and_blank_lines_are_ignored()
        {
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "# MES Zebra Bridge configuration",
                "",
                "   ",
                "# Queue = written by install",
                "GatewayAddress=172.17.10.161"
            });

            Assert.Null(c.Queue);
            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void A_value_containing_an_equals_sign_keeps_it()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { @"LogDirectory=C:\Logs\a=b" });
            Assert.Equal(@"C:\Logs\a=b", c.LogDirectory);
        }

        [Fact]
        public void An_unknown_key_is_a_warning_not_a_failure()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Prnter=Zebra", "Port=9100" });

            Assert.Equal(9100, c.Port);
            Assert.Single(c.Warnings);
            Assert.Contains("Prnter", c.Warnings[0]);
        }

        [Fact]
        public void A_line_with_no_equals_sign_is_a_warning_not_a_failure()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "just some text", "Port=9100" });

            Assert.Equal(9100, c.Port);
            Assert.Single(c.Warnings);
            Assert.Contains("just some text", c.Warnings[0]);
        }

        [Fact]
        public void An_unparseable_or_out_of_range_number_keeps_the_default_and_warns()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Port=nine thousand", "LogRetainDays=0" });

            Assert.Equal(9100, c.Port);
            Assert.Equal(14, c.LogRetainDays);
            Assert.Equal(2, c.Warnings.Count);
        }

        [Fact]
        public void An_empty_queue_value_stays_unconfigured_rather_than_becoming_a_blank_name()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Queue=" });
            Assert.Null(c.Queue);
        }

        [Fact]
        public void Command_line_options_override_the_file()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Queue=From File", "GatewayAddress=10.0.0.1" });

            c.ApplyCommandLine(new[] { "install", "--queue", "From Args", "--gateway", "172.17.10.161", "--port", "9101" });

            Assert.Equal("From Args", c.Queue);
            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Equal(9101, c.Port);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void An_option_with_no_value_is_a_warning_and_changes_nothing()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "GatewayAddress=172.17.10.161" });

            c.ApplyCommandLine(new[] { "install", "--gateway" });

            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Single(c.Warnings);
            Assert.Contains("--gateway", c.Warnings[0]);
        }

        [Fact]
        public void An_unknown_option_is_a_warning_and_changes_nothing()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);

            c.ApplyCommandLine(new[] { "install", "--printer", "Zebra" });

            Assert.Single(c.Warnings);
            Assert.Contains("--printer", c.Warnings[0]);
        }

        [Fact]
        public void The_conf_path_can_be_redirected_from_the_command_line()
        {
            Assert.Equal(@"D:\alt\bridge.conf",
                BridgeConfig.ConfPathFromCommandLine(new[] { "run", "--conf", @"D:\alt\bridge.conf" }));

            Assert.Equal(BridgeConfig.DefaultPath,
                BridgeConfig.ConfPathFromCommandLine(new[] { "run" }));

            Assert.Equal(BridgeConfig.DefaultPath,
                BridgeConfig.ConfPathFromCommandLine(new[] { "run", "--conf" }));   // no value
        }

        [Fact]
        public void Set_queue_records_the_name_and_blanks_it_back_out_when_asked()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);

            c.SetQueue("  Zebra GX420d (RAW) ");
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);

            c.SetQueue("");
            Assert.Null(c.Queue);
        }

        [Fact]
        public void A_written_conf_file_reads_back_identically()
        {
            // install and set-queue both write this file, so the round trip is the
            // contract -- a printer swap must not lose the gateway address.
            BridgeConfig original = BridgeConfig.Parse(new string[0]);
            original.Queue = "Zebra GX420d (RAW)";
            original.GatewayAddress = "172.17.10.161";
            original.Port = 9100;
            original.LogRetainDays = 21;

            string path = Path.Combine(Path.GetTempPath(),
                "bridge-conf-" + Guid.NewGuid().ToString("N") + ".conf");
            try
            {
                original.Save(path);

                BridgeConfig reloaded = BridgeConfig.Load(path);

                Assert.Equal(original.Queue, reloaded.Queue);
                Assert.Equal(original.GatewayAddress, reloaded.GatewayAddress);
                Assert.Equal(original.Port, reloaded.Port);
                Assert.Equal(original.LogRetainDays, reloaded.LogRetainDays);
                Assert.Equal(original.LogDirectory, reloaded.LogDirectory);
                Assert.Empty(reloaded.Warnings);
            }
            finally
            {
                try { File.Delete(path); } catch (Exception) { }
            }
        }

        [Fact]
        public void A_rewrite_after_a_printer_swap_keeps_every_other_value()
        {
            // The swap path: load, SetQueue, Save. Nothing else may move.
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "Queue=Old Printer",
                "GatewayAddress=172.17.10.161",
                "Port=9100",
                "LogRetainDays=21"
            });

            c.SetQueue("New Printer");
            IList<string> lines = c.ToConfLines();
            BridgeConfig reloaded = BridgeConfig.Parse(lines);

            Assert.Equal("New Printer", reloaded.Queue);
            Assert.Equal("172.17.10.161", reloaded.GatewayAddress);
            Assert.Equal(21, reloaded.LogRetainDays);
        }

        [Fact]
        public void A_written_conf_file_is_commented_and_ascii_so_a_human_can_read_it()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);
            IList<string> lines = c.ToConfLines();

            Assert.Contains(lines, l => l.StartsWith("#"));
            Assert.Contains(lines, l => l.StartsWith("Port="));
            foreach (string l in lines)
                foreach (char ch in l)
                    Assert.True(ch < 128, "non-ASCII in conf line: " + l);
        }

        [Fact]
        public void An_unconfigured_gateway_is_written_as_a_commented_placeholder_not_a_guess()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);

            string text = string.Join("\n", new List<string>(c.ToConfLines()).ToArray());

            Assert.Contains("# GatewayAddress=", text);
            Assert.DoesNotContain("\nGatewayAddress=", "\n" + text);
        }
    }
}
