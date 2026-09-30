// Which queue this bridge is bound to. It is whatever the conf file said, and
// nothing else (Global Constraint 5): no enumeration, no heuristic, no retry.
//
// Detection lives in QueueResolver and runs only during `install` / `detect`,
// where a human is standing at the machine to confirm the name. Nothing on this
// path can guess.
//
// A name that is not actually on the host is NOT rejected here. PROTOCOL.md
// requires ?STATUS to answer ready=false while naming what it tried, and a print
// to answer `ERR queue not found: 'X'; visible: ...` -- the spooler's error is the
// one that lists what IS present, which is the half that helps.

using System;

namespace BlueRidge.MesZebraBridge
{
    public sealed class QueueBinding
    {
        /// <summary>The conf'd queue name, trimmed, or null when the conf named none.</summary>
        public string Queue { get; private set; }

        public bool IsConfigured { get { return Queue != null; } }

        /// <summary>One line for the startup log, the `status` verb, and the wire.</summary>
        public string Diagnosis { get; private set; }

        public QueueBinding(string configuredQueue)
        {
            string name = (configuredQueue ?? "").Trim();

            if (name.Length == 0)
            {
                Queue = null;
                Diagnosis = Protocol.Cap(
                    "no Queue= in the configuration. Nothing will print. Run "
                    + "'MesZebraBridge.exe install' at this machine (it detects the queue and "
                    + "writes it), or 'MesZebraBridge.exe set-queue \"<exact queue name>\"'.");
            }
            else
            {
                Queue = name;
                Diagnosis = Protocol.Cap("queue " + Protocol.Quote(name) + " from the configuration");
            }
        }
    }
}
