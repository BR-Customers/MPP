// Configuration.
//
//   <beside the exe>\MesZebraBridge.conf    (ASCII, key=value, # comments)
//
// Location per spec 7 step 4 ("copy MesZebraBridge.exe AND ITS CONF FILE") and
// spec 10.1 ("lives in the conf file shipped beside the executable -- authored
// once for all 54 installs"). Format per spec open item 12.1, which leaves it
// unspecified; key=value is the assumption, chosen because a commissioner can read
// it over someone's shoulder and net48 has no first-class JSON reader.
//
// NOTHING DEPLOYMENT-SPECIFIC IS COMPILED IN (spec 10.1). There is deliberately no
// DefaultGatewayAddress and no default Queue. GatewayAddress defaults to null and
// `install` refuses rather than widening the firewall rule; Queue defaults to null
// and the bridge answers `ERR queue unconfigured` rather than guessing.
//
// An earlier revision of this plan compiled in 10.20.11.53 -- the DEVELOPMENT
// gateway on a laptop, correct on 2026-09-29 and stale that same evening when the
// machine changed networks. That is the whole argument.
//
// A typo must never stop 9100 listening: an unknown key or a bad number is a
// warning the startup log names, not a failure.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;

namespace BlueRidge.MesZebraBridge
{
    public sealed class BridgeConfig
    {
        public const int DefaultPort = 9100;
        public const int DefaultLogRetainDays = 14;
        public const string ConfFileName = "MesZebraBridge.conf";

        /// <summary>null = unconfigured. The bridge will answer ERR, never guess.</summary>
        public string Queue { get; set; }

        /// <summary>null = unconfigured. install refuses rather than widening the rule.</summary>
        public string GatewayAddress { get; set; }

        public int Port { get; set; }
        public string LogDirectory { get; set; }
        public int LogRetainDays { get; set; }

        /// <summary>Everything that was ignored and why. The startup log names each one.</summary>
        public IList<string> Warnings { get { return _warnings; } }

        private readonly List<string> _warnings = new List<string>();

        private BridgeConfig()
        {
            Queue = null;
            GatewayAddress = null;
            Port = DefaultPort;
            LogDirectory = DefaultLogDirectory;
            LogRetainDays = DefaultLogRetainDays;
        }

        /// <summary>Beside the executable -- it ships with it and is copied with it.</summary>
        public static string DefaultPath
        {
            get
            {
                string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                return Path.Combine(exeDir, ConfFileName);
            }
        }

        /// <summary>
        /// Machine state, not shipped configuration -- so under ProgramData rather
        /// than beside the exe, which keeps the deployment directory two files.
        /// </summary>
        public static string DefaultLogDirectory
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    Path.Combine("BlueRidge", Path.Combine("MesZebraBridge", "logs")));
            }
        }

        /// <summary>--conf &lt;path&gt;, else the file beside the exe.</summary>
        public static string ConfPathFromCommandLine(string[] args)
        {
            if (args != null)
            {
                for (int i = 1; i < args.Length - 1; i++)
                    if (string.Equals(args[i], "--conf", StringComparison.OrdinalIgnoreCase))
                        return args[i + 1];
            }
            return DefaultPath;
        }

        public static BridgeConfig Load(string path)
        {
            try
            {
                if (!File.Exists(path)) return new BridgeConfig();
                return Parse(File.ReadAllLines(path));
            }
            catch (Exception ex)
            {
                var c = new BridgeConfig();
                c._warnings.Add("could not read " + path + ": " + Protocol.OneLine(ex.Message));
                return c;
            }
        }

        public static BridgeConfig Parse(IEnumerable<string> lines)
        {
            var c = new BridgeConfig();
            if (lines == null) return c;

            foreach (string raw in lines)
            {
                string line = (raw ?? "").Trim();
                if (line.Length == 0 || line[0] == '#') continue;

                int eq = line.IndexOf('=');
                if (eq < 1)
                {
                    c._warnings.Add("ignored conf line (no key=value): " + line);
                    continue;
                }

                string key = line.Substring(0, eq).Trim();
                string value = line.Substring(eq + 1).Trim();

                switch (key.ToUpperInvariant())
                {
                    case "QUEUE":
                        c.Queue = value.Length == 0 ? null : value;
                        break;
                    case "GATEWAYADDRESS":
                        c.GatewayAddress = value.Length == 0 ? null : value;
                        break;
                    case "LOGDIRECTORY":
                        if (value.Length > 0) c.LogDirectory = value;
                        break;
                    case "PORT":
                        c.Port = c.ReadInt(key, value, 1, 65535, DefaultPort);
                        break;
                    case "LOGRETAINDAYS":
                        c.LogRetainDays = c.ReadInt(key, value, 1, 3650, DefaultLogRetainDays);
                        break;
                    default:
                        c._warnings.Add("ignored unknown conf key: " + key);
                        break;
                }
            }

            return c;
        }

        private int ReadInt(string key, string value, int min, int max, int fallback)
        {
            int parsed;
            if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
                && parsed >= min && parsed <= max)
                return parsed;

            _warnings.Add(string.Format("{0}={1} is not an integer in [{2}, {3}]; using {4}",
                key, value, min, max, fallback));
            return fallback;
        }

        /// <summary>
        /// Apply --queue / --gateway / --port / --log-dir / --retain-days, which win
        /// over the file. args[0] is the verb and is skipped; --conf is consumed by
        /// ConfPathFromCommandLine and ignored here.
        /// </summary>
        public void ApplyCommandLine(string[] args)
        {
            if (args == null) return;

            for (int i = 1; i < args.Length; i++)
            {
                string opt = (args[i] ?? "").ToLowerInvariant();
                if (!opt.StartsWith("--"))
                {
                    _warnings.Add("ignored unexpected argument: " + args[i]);
                    continue;
                }

                if (i + 1 >= args.Length)
                {
                    _warnings.Add("ignored " + args[i] + ": it takes a value and none followed");
                    return;
                }

                string value = args[++i];
                switch (opt)
                {
                    case "--conf": break;                          // handled separately
                    case "--queue": SetQueue(value); break;
                    case "--gateway": GatewayAddress = value.Length == 0 ? null : value; break;
                    case "--log-dir": LogDirectory = value; break;
                    case "--port": Port = ReadInt("--port", value, 1, 65535, Port); break;
                    case "--retain-days": LogRetainDays = ReadInt("--retain-days", value, 1, 3650, LogRetainDays); break;
                    default:
                        _warnings.Add("ignored unknown option: " + args[i - 1]);
                        break;
                }
            }
        }

        /// <summary>
        /// The one place a queue name is recorded. install and set-queue both go
        /// through it, so a first install and a printer swap cannot diverge.
        /// </summary>
        public void SetQueue(string name)
        {
            string trimmed = (name ?? "").Trim();
            Queue = trimmed.Length == 0 ? null : trimmed;
        }

        public IList<string> ToConfLines()
        {
            var lines = new List<string>
            {
                "# MES Zebra Bridge configuration",
                "# Sits beside MesZebraBridge.exe and is copied with it (spec section 7 step 4).",
                "# Wire protocol: zebraPrinter/PROTOCOL.md v1.0.0.",
                "#",
                "# GatewayAddress  the ONLY source address the inbound firewall rule admits.",
                "#                 Authored once for all 54 installs; never typed per machine",
                "#                 and never compiled into the binary (spec section 10.1).",
                "#                 install refuses to run without it rather than widening",
                "#                 the rule to any source.",
                "# Queue           the exact Windows print queue name to spool to. Written by",
                "#                 'install' when detection finds exactly one candidate, or by",
                "#                 'set-queue \"<name>\"' after a printer swap. There is no",
                "#                 runtime detection: an absent Queue means nothing prints and",
                "#                 the bridge answers 'ERR queue unconfigured'.",
                "# Port            TCP port to listen on. 9100 unless something else owns it.",
                "# LogDirectory    where the daily bridge-YYYYMMDD.log files go.",
                "# LogRetainDays   how many days of those files to keep.",
                ""
            };

            lines.Add(GatewayAddress == null
                ? "# GatewayAddress=172.17.10.161"
                : "GatewayAddress=" + GatewayAddress);

            lines.Add(Queue == null
                ? "# Queue="
                : "Queue=" + Queue);

            lines.Add("Port=" + Port.ToString(CultureInfo.InvariantCulture));
            lines.Add("LogDirectory=" + LogDirectory);
            lines.Add("LogRetainDays=" + LogRetainDays.ToString(CultureInfo.InvariantCulture));

            return lines;
        }

        public void Save(string path)
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            // ASCII, same rule as every other MPP-authored data file: a stray
            // em-dash read back in the Windows codepage becomes mojibake.
            var sb = new StringBuilder();
            foreach (string line in ToConfLines()) sb.Append(line).Append(Environment.NewLine);
            File.WriteAllText(path, sb.ToString(), Encoding.ASCII);
        }
    }
}
