// INSTALL-TIME queue detection. NOT on the runtime path -- the service reads
// Queue= from its conf file and enumerates nothing (Global Constraint 5).
//
// This exists so `install` can offer the commissioner a name to confirm against
// the Get-Printer they ran in spec section 7 step 1, and so that when it cannot
// offer one it names everything it saw and asks for --queue.
//
// The rule is Zebra/ZDesigner driver + live port + EXACTLY ONE, or nothing.
//
// Why "exactly one, or nothing" and not a cleverer rule: one real printer host
// carried `ZDesigner GX420d (Copy 1)` on USB001, `ZDesigner GX420d` on LPT1:
// (stale), and `Zebra GX420d (RAW)` on USB001 (the one actually in use). Dead-port
// filtering removes the LPT1: row and leaves TWO LIVE CANDIDATES ON THE SAME PORT.
// No status bit separates those, so there is no rule that picks correctly -- only
// rules that pick quietly. The wrong side of that coin flip is a terminal spooling
// to a queue nobody watches.
//
// IsLivePort is kept because it settles the single-Zebra-plus-stale-LPT1: case,
// and because the `detect` listing uses it to label that row for a human.

using System;
using System.Collections.Generic;

namespace BlueRidge.MesZebraBridge
{
    public sealed class QueueResolution
    {
        /// <summary>The detected queue name, or null when detection would have to guess.</summary>
        public string Queue { get; internal set; }

        /// <summary>Always populated, always one line: what was found and what was chosen.</summary>
        public string Diagnosis { get; internal set; }

        public bool Resolved { get { return Queue != null; } }
    }

    public static class QueueResolver
    {
        /// <summary>
        /// Ports a queue can be bound to while having no hardware behind it. Matched
        /// as a case-insensitive prefix, because a port name may or may not carry its
        /// trailing colon depending on how the queue was created.
        /// </summary>
        private static readonly string[] DeadPortPrefixes =
        {
            "LPT", "COM", "FILE:", "PORTPROMPT:", "NUL", "XPSPORT:", "SHRFAX:",
            "MICROSOFT.OFFICE.", "ONENOTE"
        };

        public static bool IsZebraDriver(string driver)
        {
            if (string.IsNullOrEmpty(driver)) return false;
            return driver.IndexOf("ZDesigner", StringComparison.OrdinalIgnoreCase) >= 0
                || driver.IndexOf("Zebra", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        public static bool IsLivePort(string port)
        {
            if (string.IsNullOrEmpty(port)) return false;
            foreach (string dead in DeadPortPrefixes)
                if (port.StartsWith(dead, StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }

        public static QueueResolution Select(IEnumerable<PrinterEntry> queues)
        {
            var all = new List<PrinterEntry>(queues ?? new PrinterEntry[0]);
            var zebra = new List<PrinterEntry>();
            var live = new List<PrinterEntry>();

            foreach (PrinterEntry q in all)
            {
                if (!IsZebraDriver(q.Driver)) continue;
                zebra.Add(q);
                if (IsLivePort(q.Port)) live.Add(q);
            }

            // Exactly one, or nothing. No tie-breaker.
            if (live.Count == 1)
            {
                string line = string.Format(
                    "{0} on port {1} (driver {2}); {3} Zebra candidate(s) among {4} local queue(s)",
                    Protocol.Quote(live[0].Name), live[0].Port, Protocol.Quote(live[0].Driver),
                    zebra.Count, all.Count);
                return new QueueResolution
                {
                    Queue = live[0].Name,
                    Diagnosis = Protocol.Cap(Protocol.OneLine(line))
                };
            }

            return new QueueResolution { Queue = null, Diagnosis = Describe(all, zebra, live) };
        }

        private static string Describe(List<PrinterEntry> all, List<PrinterEntry> zebra, List<PrinterEntry> live)
        {
            if (zebra.Count == 0)
                return Protocol.Cap(Protocol.OneLine(string.Format(
                    "no Zebra/ZDesigner driver among {0} local queue(s): {1}. "
                    + "Install the driver, or name the queue with --queue \"<name>\".",
                    all.Count, JoinNames(all))));

            var parts = new List<string>();
            foreach (PrinterEntry q in zebra)
                parts.Add(string.Format("{0} port={1} {2}",
                    Protocol.Quote(q.Name),
                    string.IsNullOrEmpty(q.Port) ? "(none)" : q.Port,
                    IsLivePort(q.Port) ? "live-port" : "dead-port"));

            return Protocol.Cap(Protocol.OneLine(string.Format(
                "cannot choose between {0} Zebra candidate(s), {1} on a live port -- {2}. "
                + "Name the one you want with --queue \"<name>\".",
                zebra.Count, live.Count, string.Join(", ", parts.ToArray()))));
        }

        private static string JoinNames(List<PrinterEntry> queues)
        {
            if (queues.Count == 0) return "(none)";
            var names = new List<string>();
            foreach (PrinterEntry q in queues) names.Add(Protocol.Quote(q.Name));
            return string.Join(", ", names.ToArray());
        }
    }
}
