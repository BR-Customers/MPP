// The bootstrap's pure parts: what the startup banner says, and that the config
// the service builds from is the same one the console verbs build from.
//
// ServiceBase.Run and a real SCM start are exercised in Task 15, not here.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class HostTests : IDisposable
    {
        private readonly string _dir;

        public HostTests()
        {
            _dir = Path.Combine(Path.GetTempPath(), "MesZebraBridgeHost_" + Guid.NewGuid().ToString("N"));
        }

        public void Dispose()
        {
            try { if (Directory.Exists(_dir)) Directory.Delete(_dir, true); }
            catch (Exception) { }
        }

        [Fact]
        public void The_startup_banner_names_the_version_the_port_the_queue_and_the_log_path()
        {
            // Spec section 1: the 2026-09-29 diagnosis needed three uncorrelated
            // sources. The banner is the machine's own answer to "what is this thing
            // bound to", which is the question that cost the most time.
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "Port=9100",
                "Queue=Zebra GX420d (RAW)",
                "GatewayAddress=172.17.10.161",
                "LogDirectory=" + _dir
            });

            IList<string> banner = Host.StartupBanner(c, new QueueBinding(c.Queue).Diagnosis);
            string text = string.Join(" | ", new List<string>(banner).ToArray());

            Assert.Contains("MesZebraBridge", text);
            Assert.Contains(Protocol.BridgeVersion, text);
            Assert.Contains("0.0.0.0:9100", text);
            Assert.Contains("Zebra GX420d (RAW)", text);
            Assert.Contains(_dir, text);
            Assert.Contains("172.17.10.161", text);
            Assert.Contains(BridgeConfig.ConfFileName, text);   // where to go and change it
        }

        [Fact]
        public void The_banner_shouts_when_there_is_no_queue_to_bind()
        {
            // A commissioned terminal and an un-commissioned one must not produce
            // banners that read the same at a glance.
            BridgeConfig c = BridgeConfig.Parse(new[] { "GatewayAddress=172.17.10.161" });

            string text = string.Join(" | ", new List<string>(
                Host.StartupBanner(c, new QueueBinding(c.Queue).Diagnosis)).ToArray());

            Assert.Contains("(none)", text);
            Assert.Contains("no Queue=", text);
        }

        [Fact]
        public void The_banner_repeats_every_configuration_warning_so_a_typo_is_visible()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Prnter=Zebra", "Port=nope" });

            string text = string.Join(" | ", new List<string>(Host.StartupBanner(c, "x")).ToArray());

            Assert.Contains("Prnter", text);
            Assert.Contains("nope", text);
        }

        [Fact]
        public void Loading_the_config_applies_the_command_line_over_the_file()
        {
            BridgeConfig c = Host.LoadConfig(new[] { "run", "--queue", "Hand Picked", "--log-dir", _dir });

            Assert.Equal("Hand Picked", c.Queue);
            Assert.Equal(_dir, c.LogDirectory);
        }

        [Fact]
        public void The_host_binds_all_interfaces_because_the_gateway_is_on_another_machine()
        {
            // 0.0.0.0, carried over from the Python bridge (spec section 3). The
            // firewall rule Task 13 adds is what keeps that from being wide open.
            Assert.Equal(IPAddress.Any, Host.BindAddress);
        }

        [Fact]
        public void The_host_builds_a_server_that_starts_and_stops_cleanly()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "LogDirectory=" + _dir });

            // Set Port DIRECTLY rather than through the conf: `Port=0` is outside
            // BridgeConfig's valid [1, 65535] range, so parsing it would warn and
            // fall back to 9100 -- and this test would then bind the real port that
            // other work is using. 0 here means "ephemeral", which is what we want.
            c.Port = 0;

            RollingLog log;
            QueueBinding binding;
            using (BridgeServer server = Host.Build(c, false, out log, out binding))
            {
                Assert.NotNull(log);
                Assert.NotNull(binding);
                server.Start();
                Assert.True(server.BoundPort > 0);
                server.Stop();
            }
        }

        [Fact]
        public void The_usage_text_names_every_verb_and_every_option()
        {
            foreach (string token in new[]
            {
                "install", "uninstall", "run", "status", "detect",
                "--queue", "--gateway", "--port", "--log-dir", "--retain-days"
            })
            {
                Assert.Contains(token, Program.Usage);
            }
        }

        [Fact]
        public void The_usage_text_is_ascii_only()
        {
            foreach (char ch in Program.Usage)
                Assert.True(ch < 128, "non-ASCII in usage text");
        }
    }
}
