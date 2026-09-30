// Self-install (spec sections 3, 7 and 10.1). Registers the service, sets
// restart-on-failure recovery, writes the conf, adds its own inbound firewall rule
// scoped to the Gateway, starts, and REPORTS THE QUEUE IT BOUND so the commissioner
// can check it against the Get-Printer from spec section 7 step 1.
//
// IDEMPOTENT. Printers get swapped in service and spec section 7 calls
// re-commissioning "the case that needs care, not first commissioning", so running
// install again reconfigures and restarts rather than failing. `set-queue` is the
// narrow verb for the same job; both share WriteConf and RestartService so a first
// install and a swap cannot diverge.
//
// DETECTION DECIDES NOTHING ON ITS OWN (Global Constraint 5). Exactly one live
// candidate and the name goes in the conf; zero or several and install stops and
// requires --queue. An unbound service that silently picked wrong is worse than one
// more command typed by someone who can see both names.
//
// A MISSING GatewayAddress IS A HARD REFUSAL, never a widened rule (spec 10.1).
//
// SCM work goes through advapi32 rather than sc.exe, for real error codes and no
// output parsing. The firewall rule goes through netsh advfirewall, called by
// ABSOLUTE PATH from System32 so nothing on PATH can be substituted into an
// elevated run -- and because the command is one line the operator can read,
// re-run and verify, which matters for a rule whose absence presented on
// 2026-09-29 as `DispatchFailed / "Connect timed out"`.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceProcess;

namespace BlueRidge.MesZebraBridge
{
    public static class Installer
    {
        public const string ServiceName = "MesZebraBridge";
        public const string DisplayName = "MES Zebra Bridge";

        public const string Description =
            "Accepts ZPL on TCP 9100 from the Ignition Gateway and spools it to the local "
            + "Zebra print queue using the RAW datatype. Blue Ridge Automation.";

        public const string FirewallRuleName = "MES Zebra Bridge (TCP 9100 inbound)";

        private const string FirewallRuleDescription =
            "Inbound raw-print from the Ignition Gateway only. Added by MesZebraBridge.exe install.";

        // --- SCM ---------------------------------------------------------------

        private const uint SC_MANAGER_ALL_ACCESS = 0x000F003F;
        private const uint SERVICE_ALL_ACCESS = 0x000F01FF;
        private const uint SERVICE_WIN32_OWN_PROCESS = 0x00000010;
        private const uint SERVICE_AUTO_START = 0x00000002;
        private const uint SERVICE_ERROR_NORMAL = 0x00000001;

        private const int SERVICE_CONFIG_DESCRIPTION = 1;
        private const int SERVICE_CONFIG_FAILURE_ACTIONS = 2;
        private const int SC_ACTION_RESTART = 1;

        private const int ERROR_SERVICE_EXISTS = 1073;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SERVICE_DESCRIPTION
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string lpDescription;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SC_ACTION
        {
            public int Type;
            public uint Delay;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SERVICE_FAILURE_ACTIONS
        {
            public uint dwResetPeriod;
            public IntPtr lpRebootMsg;
            public IntPtr lpCommand;
            public uint cActions;
            public IntPtr lpsaActions;
        }

        [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenSCManager(string machineName, string databaseName, uint access);

        [DllImport("advapi32.dll", EntryPoint = "CreateServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateService(IntPtr scManager, string serviceName, string displayName,
            uint access, uint serviceType, uint startType, uint errorControl, string binaryPath,
            string loadOrderGroup, IntPtr tagId, string dependencies, string serviceStartName, string password);

        [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenService(IntPtr scManager, string serviceName, uint access);

        [DllImport("advapi32.dll", EntryPoint = "ChangeServiceConfig2W", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ChangeServiceConfig2(IntPtr service, int infoLevel, IntPtr info);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DeleteService(IntPtr service);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool CloseServiceHandle(IntPtr handle);

        // --- helpers -----------------------------------------------------------

        public static string NetshPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System), "netsh.exe");
            }
        }

        public static string ExecutablePath
        {
            get { return Assembly.GetExecutingAssembly().Location; }
        }

        public static bool IsElevated()
        {
            try
            {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                    return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch (Exception)
            {
                return false;
            }
        }

        public static string QuoteArg(string value)
        {
            return "\"" + (value ?? "").Replace("\"", "\\\"") + "\"";
        }

        public static string BuildFirewallAddArgs(string gatewayAddress, int port)
        {
            string address = (gatewayAddress ?? "").Trim();
            if (address.Length == 0 || address.Equals("any", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException(
                    "a scoped Gateway address is required -- an unscoped rule would leave an "
                    + "unauthenticated raw-print listener open to the plant", "gatewayAddress");

            return string.Format(
                "advfirewall firewall add rule name={0} dir=in action=allow protocol=TCP "
                + "localport={1} remoteip={2} profile=any enable=yes description={3}",
                QuoteArg(FirewallRuleName), port, QuoteArg(address), QuoteArg(FirewallRuleDescription));
        }

        public static string BuildFirewallDeleteArgs()
        {
            return "advfirewall firewall delete rule name=" + QuoteArg(FirewallRuleName);
        }

        private static int Netsh(string arguments)
        {
            var psi = new ProcessStartInfo(NetshPath, arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using (Process p = Process.Start(psi))
            {
                string stdout = p.StandardOutput.ReadToEnd();
                string stderr = p.StandardError.ReadToEnd();
                p.WaitForExit();

                string text = (stdout + " " + stderr).Trim();
                if (text.Length > 0) Console.WriteLine("  netsh: " + Protocol.OneLine(text));
                return p.ExitCode;
            }
        }

        /// <summary>
        /// Decide the queue name for an install. Returns false when the operator has
        /// to name it, with `message` explaining exactly what was seen.
        ///
        /// An already-configured name (conf or --queue) is kept and detection is not
        /// consulted: re-running install on a commissioned machine must not silently
        /// move the binding, and --queue is how the ambiguous host gets resolved.
        /// </summary>
        public static bool ResolveQueueForInstall(BridgeConfig config,
                                                  IList<PrinterEntry> queues,
                                                  out string message)
        {
            if (!string.IsNullOrEmpty(config.Queue))
            {
                message = "queue " + Protocol.Quote(config.Queue)
                    + " from the configuration / --queue; detection skipped";
                return true;
            }

            QueueResolution r = QueueResolver.Select(queues);
            if (r.Resolved)
            {
                config.SetQueue(r.Queue);
                message = "detected " + r.Diagnosis;
                return true;
            }

            message = r.Diagnosis;
            return false;
        }

        // --- verbs -------------------------------------------------------------

        public static int Install(string[] args)
        {
            if (!IsElevated())
            {
                Console.Error.WriteLine(
                    "install needs an elevated prompt. Right-click Command Prompt or PowerShell, "
                    + "choose 'Run as administrator', and run it again.");
                return 3;
            }

            string confPath = BridgeConfig.ConfPathFromCommandLine(args);
            BridgeConfig config = BridgeConfig.Load(confPath);
            config.ApplyCommandLine(args);
            foreach (string w in config.Warnings) Console.WriteLine("CONFIG WARNING " + w);

            Console.WriteLine("MesZebraBridge {0} install", Protocol.BridgeVersion);
            Console.WriteLine("  binary   {0}", ExecutablePath);
            Console.WriteLine("  conf     {0}", confPath);
            Console.WriteLine("  account  LocalSystem");
            Console.WriteLine("  port     {0}", config.Port);
            Console.WriteLine();

            // 1. The Gateway address. A hard refusal, never a widened rule (spec 10.1).
            if (string.IsNullOrEmpty(config.GatewayAddress))
            {
                Console.Error.WriteLine(
                    "REFUSING: no GatewayAddress. Nothing is compiled into this binary, so the "
                    + "inbound firewall rule has no source to scope to, and an unscoped rule "
                    + "would leave an unauthenticated raw-print listener open to the plant.");
                Console.Error.WriteLine();
                Console.Error.WriteLine("Fix either way:");
                Console.Error.WriteLine("  * add   GatewayAddress=172.17.10.161   to {0}", confPath);
                Console.Error.WriteLine("    (that is the conf file that ships beside the exe -- check it was copied)");
                Console.Error.WriteLine("  * or run  MesZebraBridge.exe install --gateway 172.17.10.161");
                return 4;
            }
            Console.WriteLine("  gateway  {0}   <-- the ONLY source the firewall rule will admit",
                config.GatewayAddress);
            Console.WriteLine();

            // 2. The queue. Detection offers a name; it never decides alone.
            IList<PrinterEntry> queues;
            try
            {
                queues = Spooler.EnumerateLocalQueues();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("could not enumerate local print queues: "
                                        + Protocol.OneLine(ex.Message));
                return 1;
            }

            string queueMessage;
            if (!ResolveQueueForInstall(config, queues, out queueMessage))
            {
                Console.Error.WriteLine("REFUSING: " + queueMessage);
                Console.Error.WriteLine();
                Host.PrintDetection();
                Console.Error.WriteLine();
                Console.Error.WriteLine(
                    "Nothing was installed. Pick the queue from the list above -- it is the one "
                    + "'Get-Printer' showed you in step 1 -- and run:");
                Console.Error.WriteLine("  MesZebraBridge.exe install --queue \"<exact queue name>\"");
                return 5;
            }
            Console.WriteLine("queue    {0}", queueMessage);
            Console.WriteLine();

            // 3. Write the conf, so `status` reads back exactly what this install decided.
            if (!WriteConf(config, confPath)) return 1;

            // 4. Register, or reconfigure if it is already there (idempotent).
            if (!RegisterService(ExecutablePath)) return 1;

            // 5. The inbound rule. Delete first so re-running install prunes the old
            //    scoping instead of accumulating rules (spec 10.1).
            Netsh(BuildFirewallDeleteArgs());
            int rc = Netsh(BuildFirewallAddArgs(config.GatewayAddress, config.Port));
            if (rc != 0)
            {
                Console.Error.WriteLine("netsh add rule failed with exit code " + rc
                    + " -- the service is installed but the Gateway will see 'Connect timed out'.");
                return 1;
            }
            Console.WriteLine("firewall rule {0} -> allow TCP {1} inbound from {2}",
                FirewallRuleName, config.Port, config.GatewayAddress);

            // 6. Start, or restart if it was already running with the old conf.
            if (!RestartService()) return 1;

            Console.WriteLine();
            Console.WriteLine("BOUND QUEUE: {0}", config.Queue);
            Console.WriteLine("Check that against the 'Get-Printer' from step 1, then verify from");
            Console.WriteLine("the Gateway with a ?STATUS probe (spec section 9) and one real label.");
            Console.WriteLine("'MesZebraBridge.exe status' reports state here.");
            return 0;
        }

        /// <summary>
        /// The printer-swap verb. Same conf write and same restart as install, no SCM
        /// or firewall work -- so a swap cannot drift from a first install.
        /// </summary>
        public static int SetQueue(string[] args)
        {
            if (!IsElevated())
            {
                Console.Error.WriteLine("set-queue needs an elevated prompt (it restarts the service).");
                return 3;
            }

            string name = null;
            for (int i = 1; i < args.Length; i++)
            {
                if (args[i].StartsWith("--")) { i++; continue; }   // skip --conf <path> etc.
                name = args[i];
                break;
            }

            if (string.IsNullOrEmpty((name ?? "").Trim()))
            {
                Console.Error.WriteLine("usage: MesZebraBridge.exe set-queue \"<exact queue name>\"");
                Console.Error.WriteLine();
                Console.Error.WriteLine("Run 'MesZebraBridge.exe detect' to list this machine's queues.");
                return 2;
            }

            string confPath = BridgeConfig.ConfPathFromCommandLine(args);
            BridgeConfig config = BridgeConfig.Load(confPath);
            foreach (string w in config.Warnings) Console.WriteLine("CONFIG WARNING " + w);

            string previous = config.Queue == null ? "(none)" : config.Queue;
            config.SetQueue(name);

            if (!WriteConf(config, confPath)) return 1;
            Console.WriteLine("queue {0} -> {1}", previous, config.Queue);

            if (!RestartService()) return 1;

            Console.WriteLine();
            Console.WriteLine("BOUND QUEUE: {0}", config.Queue);
            Console.WriteLine("Probe it with ?STATUS to confirm the new binding.");
            Console.WriteLine();
            Console.WriteLine("If this terminal already has an operator session running, restart the");
            Console.WriteLine("workstation session too: session.custom.printer resolved once at its");
            Console.WriteLine("startup and will keep printing to the old endpoint (spec section 7).");
            return 0;
        }

        private static bool WriteConf(BridgeConfig config, string confPath)
        {
            try
            {
                config.Save(confPath);
                Console.WriteLine("wrote {0}", confPath);
                return true;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("could not write " + confPath + ": " + Protocol.OneLine(ex.Message));
                return false;
            }
        }

        /// <summary>Start it, or stop-then-start so a new conf is actually picked up.</summary>
        private static bool RestartService()
        {
            try
            {
                using (var sc = new ServiceController(ServiceName))
                {
                    if (sc.Status != ServiceControllerStatus.Stopped)
                    {
                        sc.Stop();
                        sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
                    }
                    sc.Start();
                    sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
                    Console.WriteLine("service {0} is {1}", ServiceName, sc.Status);
                }
                return true;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("the service did not come back up: " + Protocol.OneLine(ex.Message));
                Console.Error.WriteLine("check the log directory and the Windows Event Log.");
                return false;
            }
        }

        private static bool RegisterService(string exePath)
        {
            IntPtr scm = OpenSCManager(null, null, SC_MANAGER_ALL_ACCESS);
            if (scm == IntPtr.Zero)
            {
                Console.Error.WriteLine("OpenSCManager failed: " + Win32Text(Marshal.GetLastWin32Error()));
                return false;
            }

            IntPtr service = IntPtr.Zero;
            try
            {
                service = CreateService(scm, ServiceName, DisplayName, SERVICE_ALL_ACCESS,
                    SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                    QuoteArg(exePath),
                    null, IntPtr.Zero, null,
                    null,    // lpServiceStartName = null -> LocalSystem (spec open item 12.3)
                    null);

                if (service == IntPtr.Zero)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err != ERROR_SERVICE_EXISTS)
                    {
                        Console.Error.WriteLine("CreateService failed: " + Win32Text(err));
                        return false;
                    }

                    // Idempotent: a re-install reconfigures rather than failing.
                    Console.WriteLine("service {0} already exists -- reconfiguring it", ServiceName);
                    service = OpenService(scm, ServiceName, SERVICE_ALL_ACCESS);
                    if (service == IntPtr.Zero)
                    {
                        Console.Error.WriteLine("OpenService failed: " + Win32Text(Marshal.GetLastWin32Error()));
                        return false;
                    }
                }
                else
                {
                    Console.WriteLine("registered service {0} ({1}), start=auto, account=LocalSystem",
                        ServiceName, DisplayName);
                }

                SetDescription(service);
                SetFailureActions(service);
                return true;
            }
            finally
            {
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                CloseServiceHandle(scm);
            }
        }

        private static void SetDescription(IntPtr service)
        {
            var desc = new SERVICE_DESCRIPTION { lpDescription = Description };
            IntPtr block = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SERVICE_DESCRIPTION)));
            try
            {
                Marshal.StructureToPtr(desc, block, false);
                if (!ChangeServiceConfig2(service, SERVICE_CONFIG_DESCRIPTION, block))
                    Console.Error.WriteLine("could not set the service description: "
                        + Win32Text(Marshal.GetLastWin32Error()));
            }
            finally
            {
                Marshal.FreeHGlobal(block);
            }
        }

        /// <summary>
        /// Restart on failure (spec section 3). On 2026-09-29 the Python bridge died
        /// mid-job and stayed dead; across 54 unattended PCs that reaches us as
        /// "the printer is broken." 5s, 5s, then 60s, with the failure count
        /// resetting after a day.
        /// </summary>
        private static void SetFailureActions(IntPtr service)
        {
            var actions = new[]
            {
                new SC_ACTION { Type = SC_ACTION_RESTART, Delay = 5000 },
                new SC_ACTION { Type = SC_ACTION_RESTART, Delay = 5000 },
                new SC_ACTION { Type = SC_ACTION_RESTART, Delay = 60000 }
            };

            int actionSize = Marshal.SizeOf(typeof(SC_ACTION));
            IntPtr actionArray = Marshal.AllocHGlobal(actionSize * actions.Length);
            IntPtr block = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SERVICE_FAILURE_ACTIONS)));
            try
            {
                for (int i = 0; i < actions.Length; i++)
                    Marshal.StructureToPtr(actions[i], new IntPtr(actionArray.ToInt64() + i * actionSize), false);

                var failure = new SERVICE_FAILURE_ACTIONS
                {
                    dwResetPeriod = 86400,
                    lpRebootMsg = IntPtr.Zero,
                    lpCommand = IntPtr.Zero,
                    cActions = (uint)actions.Length,
                    lpsaActions = actionArray
                };

                Marshal.StructureToPtr(failure, block, false);
                if (ChangeServiceConfig2(service, SERVICE_CONFIG_FAILURE_ACTIONS, block))
                    Console.WriteLine("recovery: restart after 5s, 5s, then 60s; count resets after 24h");
                else
                    Console.Error.WriteLine("could not set recovery actions: "
                        + Win32Text(Marshal.GetLastWin32Error()));
            }
            finally
            {
                Marshal.FreeHGlobal(block);
                Marshal.FreeHGlobal(actionArray);
            }
        }

        public static int Uninstall()
        {
            if (!IsElevated())
            {
                Console.Error.WriteLine("uninstall needs an elevated prompt.");
                return 3;
            }

            try
            {
                using (var sc = new ServiceController(ServiceName))
                {
                    if (sc.Status != ServiceControllerStatus.Stopped)
                    {
                        sc.Stop();
                        sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
                    }
                    Console.WriteLine("service {0} is {1}", ServiceName, sc.Status);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("could not stop the service (continuing): " + Protocol.OneLine(ex.Message));
            }

            IntPtr scm = OpenSCManager(null, null, SC_MANAGER_ALL_ACCESS);
            if (scm == IntPtr.Zero)
            {
                Console.Error.WriteLine("OpenSCManager failed: " + Win32Text(Marshal.GetLastWin32Error()));
                return 1;
            }
            try
            {
                IntPtr service = OpenService(scm, ServiceName, SERVICE_ALL_ACCESS);
                if (service == IntPtr.Zero)
                {
                    Console.WriteLine("service {0} is not installed", ServiceName);
                }
                else
                {
                    try
                    {
                        if (DeleteService(service)) Console.WriteLine("removed service " + ServiceName);
                        else Console.Error.WriteLine("DeleteService failed: "
                            + Win32Text(Marshal.GetLastWin32Error()));
                    }
                    finally
                    {
                        CloseServiceHandle(service);
                    }
                }
            }
            finally
            {
                CloseServiceHandle(scm);
            }

            // Prune the rule rather than leaving it behind (spec 10.1).
            Netsh(BuildFirewallDeleteArgs());
            Console.WriteLine("removed firewall rule {0}", FirewallRuleName);
            Console.WriteLine();
            Console.WriteLine("The conf file and {0} were left in place.",
                BridgeConfig.DefaultLogDirectory);
            return 0;
        }

        private static string Win32Text(int err)
        {
            return string.Format("[{0}] {1}", err, Protocol.OneLine(new Win32Exception(err).Message));
        }
    }
}
