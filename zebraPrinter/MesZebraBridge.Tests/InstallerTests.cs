// The install verb's decisions and command strings. Pure, so the exact netsh
// arguments and the exact refusals are pinned here -- a missing inbound rule is
// the failure that on 2026-09-29 read as `DispatchFailed / "Connect timed out"`
// and cost most of an afternoon, and a wrongly-scoped one is worse than missing.
//
// CreateService, ChangeServiceConfig2, the real netsh call and the restart need an
// elevated prompt and a real machine; Task 15 covers those.

using System;
using System.Collections.Generic;
using System.IO;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class InstallerTests
    {
        private static PrinterEntry Q(string name, string driver, string port)
        {
            return new PrinterEntry(name, driver, port, 0, 0);
        }

        private static BridgeConfig Conf(params string[] lines)
        {
            return BridgeConfig.Parse(lines);
        }

        [Fact]
        public void The_service_identity_is_the_one_the_spec_names()
        {
            Assert.Equal("MesZebraBridge", Installer.ServiceName);
            Assert.False(string.IsNullOrEmpty(Installer.DisplayName));
            Assert.Contains("9100", Installer.Description);
            Assert.Contains("9100", Installer.FirewallRuleName);
        }

        [Fact]
        public void An_argument_is_quoted_so_a_queue_name_with_spaces_survives()
        {
            Assert.Equal("\"Zebra GX420d (RAW)\"", Installer.QuoteArg("Zebra GX420d (RAW)"));
            Assert.Equal("\"\"", Installer.QuoteArg(null));
            Assert.Equal("\"a\\\"b\"", Installer.QuoteArg("a\"b"));
        }

        [Fact]
        public void The_firewall_rule_is_inbound_tcp_on_the_port_and_scoped_to_the_gateway()
        {
            string args = Installer.BuildFirewallAddArgs("172.17.10.161", 9100);

            Assert.StartsWith("advfirewall firewall add rule ", args);
            Assert.Contains("dir=in", args);
            Assert.Contains("action=allow", args);
            Assert.Contains("protocol=TCP", args);
            Assert.Contains("localport=9100", args);
            Assert.Contains("remoteip=\"172.17.10.161\"", args);
            Assert.Contains("enable=yes", args);
            Assert.Contains("name=" + Installer.QuoteArg(Installer.FirewallRuleName), args);
            Assert.DoesNotContain("\n", args);
        }

        [Fact]
        public void A_non_default_port_reaches_the_rule()
        {
            Assert.Contains("localport=19100", Installer.BuildFirewallAddArgs("172.17.10.161", 19100));
        }

        [Fact]
        public void The_rule_is_never_left_unscoped_because_an_unscoped_rule_defeats_the_point()
        {
            // 9100 open to the plant is an unauthenticated raw-print listener on 54
            // machines. Refusing beats silently widening.
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs(null, 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("", 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("   ", 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("any", 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("ANY", 9100));
        }

        [Fact]
        public void The_delete_args_name_the_same_rule_so_install_is_idempotent()
        {
            string del = Installer.BuildFirewallDeleteArgs();

            Assert.StartsWith("advfirewall firewall delete rule ", del);
            Assert.Contains("name=" + Installer.QuoteArg(Installer.FirewallRuleName), del);
        }

        [Fact]
        public void Netsh_is_called_by_absolute_path_from_system32()
        {
            // Never by bare name: an install runs elevated, and a `netsh.exe`
            // earlier on PATH would then run elevated too.
            Assert.True(Path.IsPathRooted(Installer.NetshPath));
            Assert.EndsWith("netsh.exe", Installer.NetshPath, StringComparison.OrdinalIgnoreCase);
            Assert.True(File.Exists(Installer.NetshPath), "netsh.exe not found at " + Installer.NetshPath);
        }

        [Fact]
        public void The_elevation_check_answers_without_throwing()
        {
            bool elevated = Installer.IsElevated();
            Assert.True(elevated || !elevated);
        }

        // ---- what install decides about the queue -----------------------------

        [Fact]
        public void An_explicit_queue_wins_and_detection_is_not_consulted_at_all()
        {
            // --queue is how the commissioner resolves the ambiguous host, so it
            // must not be second-guessed by a detection result.
            BridgeConfig c = Conf();
            c.SetQueue("Zebra GX420d (RAW)");

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>(), out message);

            Assert.True(ok);
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Contains("Zebra GX420d (RAW)", message);
            Assert.Contains("detection skipped", message);
        }

        [Fact]
        public void Exactly_one_live_candidate_is_written_to_the_conf_and_reported()
        {
            // Spec 7 step 4: install "reports the queue it bound so it can be checked
            // against step 1".
            BridgeConfig c = Conf();

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("Microsoft Print to PDF", "Microsoft Print To PDF", "PORTPROMPT:"),
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002")
            }, out message);

            Assert.True(ok);
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Contains("Zebra GX420d (RAW)", message);
            Assert.Contains("USB002", message);
        }

        [Fact]
        public void The_real_ambiguous_host_stops_the_install_and_demands_a_name()
        {
            // Two live candidates on USB001 plus a stale LPT1:. install must NOT
            // proceed -- an unbound service that silently picked wrong is worse than
            // a commissioner re-running one command with a name they can see.
            BridgeConfig c = Conf();

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("ZDesigner GX420d (Copy 1)", "ZDesigner GX420d", "USB001"),
                Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:"),
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB001")
            }, out message);

            Assert.False(ok);
            Assert.Null(c.Queue);
            Assert.Contains("--queue", message);
            Assert.Contains("Zebra GX420d (RAW)", message);
            Assert.Contains("ZDesigner GX420d (Copy 1)", message);
        }

        [Fact]
        public void No_zebra_driver_stops_the_install_and_says_so()
        {
            BridgeConfig c = Conf();

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("Microsoft Print to PDF", "Microsoft Print To PDF", "PORTPROMPT:")
            }, out message);

            Assert.False(ok);
            Assert.Null(c.Queue);
            Assert.Contains("no Zebra", message);
        }

        [Fact]
        public void A_queue_already_in_the_conf_is_kept_across_a_re_install()
        {
            // Idempotency: re-running install on a commissioned machine must not
            // re-detect and silently move the binding.
            BridgeConfig c = Conf("Queue=Zebra GX420d (RAW)", "GatewayAddress=172.17.10.161");

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("Some Other Zebra", "ZDesigner GX420d", "USB003")
            }, out message);

            Assert.True(ok);
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Contains("detection skipped", message);
        }
    }
}
