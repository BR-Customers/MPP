// INSTALL-TIME queue detection. Nothing here is on the runtime path: the service
// reads Queue= from its conf file and does not enumerate anything.
//
// Detection exists so `install` can offer the commissioner a name to confirm
// against the Get-Printer they just ran (spec section 7 step 1), and so that when
// it cannot offer one it says exactly what it saw.
//
// The headline case is the REAL observed host: three candidates, one stale on
// LPT1: and TWO LIVE ONES ON USB001. It must come back UNRESOLVED. An earlier
// revision of this plan picked one of those two with a heuristic; the wrong side
// of that coin flip is a terminal spooling to a queue nobody watches.

using System.Collections.Generic;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class QueueResolverTests
    {
        private static PrinterEntry Q(string name, string driver, string port)
        {
            return new PrinterEntry(name, driver, port, 0, 0);
        }

        private static readonly PrinterEntry[] NonZebraNoise =
        {
            Q("Microsoft Print to PDF", "Microsoft Print To PDF", "PORTPROMPT:"),
            Q("Microsoft XPS Document Writer", "Microsoft XPS Document Writer", "PORTPROMPT:"),
            Q("Fax", "Microsoft Shared Fax Driver", "SHRFAX:"),
            Q("OneNote (Desktop)", "Send To Microsoft OneNote 16 Driver", "nul:")
        };

        private static List<PrinterEntry> WithNoise(params PrinterEntry[] zebras)
        {
            var all = new List<PrinterEntry>(NonZebraNoise);
            all.AddRange(zebras);
            return all;
        }

        [Fact]
        public void The_real_observed_host_is_UNRESOLVED_because_two_live_queues_share_a_port()
        {
            // THE case this task exists for. Two live candidates on USB001 plus one
            // stale on LPT1:. Dead-port filtering leaves two, nothing separates them,
            // so install must stop and ask rather than pick.
            QueueResolution r = QueueResolver.Select(WithNoise(
                Q("ZDesigner GX420d (Copy 1)", "ZDesigner GX420d", "USB001"),
                Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:"),
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB001")));

            Assert.False(r.Resolved);
            Assert.Null(r.Queue);

            // Every candidate named, with its port, so the commissioner can pick.
            Assert.Contains("ZDesigner GX420d (Copy 1)", r.Diagnosis);
            Assert.Contains("Zebra GX420d (RAW)", r.Diagnosis);
            Assert.Contains("USB001", r.Diagnosis);
            Assert.Contains("LPT1:", r.Diagnosis);
            Assert.Contains("dead-port", r.Diagnosis);
            Assert.Contains("--queue", r.Diagnosis);   // tells them what to do about it
            Assert.DoesNotContain("\n", r.Diagnosis);
        }

        [Fact]
        public void A_zebra_driver_is_recognised_by_either_vendor_spelling()
        {
            Assert.True(QueueResolver.IsZebraDriver("ZDesigner GX420d"));
            Assert.True(QueueResolver.IsZebraDriver("Zebra GX420d"));
            Assert.True(QueueResolver.IsZebraDriver("zdesigner zt411-203dpi ZPL"));
            Assert.False(QueueResolver.IsZebraDriver("Microsoft Print To PDF"));
            Assert.False(QueueResolver.IsZebraDriver(""));
            Assert.False(QueueResolver.IsZebraDriver(null));
        }

        [Fact]
        public void A_legacy_hardware_port_is_dead_and_a_usb_port_is_live()
        {
            // LPT1: is the exact stale binding on the observed host.
            Assert.False(QueueResolver.IsLivePort("LPT1:"));
            Assert.False(QueueResolver.IsLivePort("COM3:"));
            Assert.False(QueueResolver.IsLivePort("PORTPROMPT:"));
            Assert.False(QueueResolver.IsLivePort("FILE:"));
            Assert.False(QueueResolver.IsLivePort("nul:"));
            Assert.False(QueueResolver.IsLivePort(""));
            Assert.False(QueueResolver.IsLivePort(null));

            Assert.True(QueueResolver.IsLivePort("USB001"));
            Assert.True(QueueResolver.IsLivePort("USB002"));
            Assert.True(QueueResolver.IsLivePort("DOT4_001"));
            Assert.True(QueueResolver.IsLivePort("IP_10.20.11.157"));
            Assert.True(QueueResolver.IsLivePort(@"\\host\ZebraShare"));
        }

        [Fact]
        public void One_live_zebra_resolves_and_the_diagnosis_names_the_queue_and_its_port()
        {
            // install prints this line, and spec section 7 step 4 wants it checked
            // against the Get-Printer from step 1 -- so the port and driver are in it.
            QueueResolution r = QueueResolver.Select(
                WithNoise(Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002")));

            Assert.True(r.Resolved);
            Assert.Equal("Zebra GX420d (RAW)", r.Queue);
            Assert.Contains("USB002", r.Diagnosis);
            Assert.Contains("ZDesigner GX420d", r.Diagnosis);
            Assert.DoesNotContain("\n", r.Diagnosis);
        }

        [Fact]
        public void One_live_zebra_beside_a_stale_one_on_a_dead_port_still_resolves()
        {
            // The case dead-port filtering DOES settle, and the only reason
            // IsLivePort is still here rather than deleted.
            QueueResolution r = QueueResolver.Select(WithNoise(
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002"),
                Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:")));

            Assert.True(r.Resolved);
            Assert.Equal("Zebra GX420d (RAW)", r.Queue);
        }

        [Fact]
        public void Two_live_zebras_on_different_ports_are_also_unresolved()
        {
            // Two printers on one PC is out of scope (spec 11.1) -- but guessing
            // between them is worse than saying so.
            QueueResolution r = QueueResolver.Select(WithNoise(
                Q("Zebra One", "ZDesigner GX420d", "USB002"),
                Q("Zebra Two", "ZDesigner GX420d", "USB003")));

            Assert.False(r.Resolved);
            Assert.Contains("Zebra One", r.Diagnosis);
            Assert.Contains("Zebra Two", r.Diagnosis);
        }

        [Fact]
        public void An_offline_status_bit_never_decides_anything()
        {
            // No tie-breaker: an earlier revision used printer status to separate
            // two live candidates. It cannot separate the observed host's pair, and
            // a rule that only sometimes applies is a rule that surprises people.
            const uint workOffline = 0x00000400;
            const uint statusOffline = 0x00000080;

            QueueResolution ambiguous = QueueResolver.Select(WithNoise(
                new PrinterEntry("Zebra Stale", "ZDesigner GX420d", "USB001", workOffline, 0),
                new PrinterEntry("Zebra Real", "ZDesigner GX420d", "USB001", 0, 0)));
            Assert.False(ambiguous.Resolved);

            // And the converse: a lone Zebra that is merely switched off still resolves.
            QueueResolution lone = QueueResolver.Select(WithNoise(
                new PrinterEntry("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002", 0, statusOffline)));
            Assert.True(lone.Resolved);
            Assert.Equal("Zebra GX420d (RAW)", lone.Queue);
        }

        [Fact]
        public void No_zebra_at_all_is_unresolved_and_says_how_many_queues_it_looked_at()
        {
            QueueResolution r = QueueResolver.Select(WithNoise());

            Assert.False(r.Resolved);
            Assert.Null(r.Queue);
            Assert.Contains("no Zebra", r.Diagnosis);
            Assert.Contains("4 local queue", r.Diagnosis);
        }

        [Fact]
        public void A_zebra_only_on_a_dead_port_is_refused_and_named()
        {
            // "the queue exists but is bound to LPT1:" is a different fix from
            // "no driver is installed", so the two must not read the same.
            QueueResolution r = QueueResolver.Select(
                WithNoise(Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:")));

            Assert.False(r.Resolved);
            Assert.Contains("ZDesigner GX420d", r.Diagnosis);
            Assert.Contains("LPT1:", r.Diagnosis);
            Assert.Contains("dead-port", r.Diagnosis);
        }

        [Fact]
        public void An_empty_or_null_enumeration_is_unresolved_and_does_not_throw()
        {
            QueueResolution empty = QueueResolver.Select(new PrinterEntry[0]);
            Assert.False(empty.Resolved);
            Assert.Contains("0 local queue", empty.Diagnosis);

            QueueResolution nothing = QueueResolver.Select(null);
            Assert.False(nothing.Resolved);
            Assert.NotNull(nothing.Diagnosis);
        }

        [Fact]
        public void The_diagnosis_is_always_one_capped_line()
        {
            var many = new List<PrinterEntry>();
            for (int i = 0; i < 60; i++)
                many.Add(Q("Zebra With A Fairly Long Name Number " + i, "ZDesigner GX420d", "USB" + i));

            QueueResolution r = QueueResolver.Select(many);

            Assert.False(r.Resolved);
            Assert.DoesNotContain("\n", r.Diagnosis);
            Assert.True(r.Diagnosis.Length <= Protocol.MaxResponseBytes);
        }
    }
}
