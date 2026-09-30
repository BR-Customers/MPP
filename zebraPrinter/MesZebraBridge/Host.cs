// One bootstrap, shared by the installed service and the `run` console verb, so
// the two cannot drift apart. Also the `detect` and `status` verbs, which are the
// commissioning tools at the machine.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.ServiceProcess;
using System.Threading;

namespace BlueRidge.MesZebraBridge
{
    public static class Host
    {
        /// <summary>
        /// 0.0.0.0, carried over from the Python bridge (spec section 3): the Gateway
        /// is on another machine. The scoped inbound firewall rule Task 13 adds is
        /// what keeps binding every interface from being wide open.
        /// </summary>
        public static IPAddress BindAddress { get { return IPAddress.Any; } }

        /// <summary>Read the conf beside the exe (or --conf), then apply CLI overrides.</summary>
        public static BridgeConfig LoadConfig(string[] args)
        {
            BridgeConfig config = BridgeConfig.Load(BridgeConfig.ConfPathFromCommandLine(args));
            config.ApplyCommandLine(args);
            return config;
        }

        public static IList<string> StartupBanner(BridgeConfig config, string diagnosis)
        {
            var lines = new List<string>
            {
                string.Format(CultureInfo.InvariantCulture,
                    "MesZebraBridge {0} starting -- wire protocol PROTOCOL.md v{0}", Protocol.BridgeVersion),
                string.Format(CultureInfo.InvariantCulture,
                    "listen        {0}:{1}", BindAddress, config.Port),
                string.Format(CultureInfo.InvariantCulture,
                    "queue         {0}", config.Queue == null ? "(none)" : config.Queue),
                string.Format(CultureInfo.InvariantCulture,
                    "binding       {0}", diagnosis),
                string.Format(CultureInfo.InvariantCulture,
                    "gateway       {0} (the only source the firewall rule admits)",
                    config.GatewayAddress == null ? "(none)" : config.GatewayAddress),
                string.Format(CultureInfo.InvariantCulture,
                    "conf          {0}", BridgeConfig.DefaultPath),
                string.Format(CultureInfo.InvariantCulture,
                    "log           {0} (keeping {1} day(s))", config.LogDirectory, config.LogRetainDays)
            };

            foreach (string w in config.Warnings) lines.Add("CONFIG WARNING " + w);
            return lines;
        }

        /// <summary>
        /// Build the server, the log and the binding from a config. Does not Start().
        ///
        /// The binding is the conf'd queue name and nothing else -- no enumeration
        /// on this path (Global Constraint 5). Detection is install-time only.
        /// </summary>
        public static BridgeServer Build(BridgeConfig config, bool echoToConsole,
                                         out RollingLog log, out QueueBinding binding)
        {
            log = new RollingLog(config.LogDirectory, config.LogRetainDays, echoToConsole);
            binding = new QueueBinding(config.Queue);

            return new BridgeServer(BindAddress, config.Port, binding, log,
                (queue, data) => Spooler.SpoolRaw(queue, data),
                queue => Spooler.ReadQueueStatus(queue));
        }

        /// <summary>
        /// Start, log the banner, and hand back the running server. Shared by
        /// BridgeService.OnStart and the `run` verb.
        ///
        /// An UNCONFIGURED QUEUE is logged as an error and does NOT stop the listener
        /// (Global Constraint 6): a service that refuses to start looks to the
        /// Gateway like `Connection refused`, which spec 6.3 reads as "bridge is
        /// down" -- the wrong machine to go and look at. A BIND failure does throw,
        /// so the SCM records a failed start and the recovery actions fire.
        /// </summary>
        public static BridgeServer StartUp(BridgeConfig config, bool echoToConsole, out RollingLog log)
        {
            QueueBinding binding;
            BridgeServer server = Build(config, echoToConsole, out log, out binding);

            foreach (string line in StartupBanner(config, binding.Diagnosis)) log.Info(line);

            if (!binding.IsConfigured)
                log.Error("NO QUEUE CONFIGURED -- listening, but every request will be refused "
                          + "with 'ERR queue unconfigured'. Nothing is guessed and nothing will "
                          + "print. " + binding.Diagnosis);

            server.Start();
            return server;
        }

        public static int RunConsole(string[] args)
        {
            BridgeConfig config = LoadConfig(args);
            RollingLog log;

            using (BridgeServer server = StartUp(config, true, out log))
            {
                Console.WriteLine();
                Console.WriteLine("Ctrl-C to stop.");

                var stop = new ManualResetEventSlim(false);
                Console.CancelKeyPress += (s, e) => { e.Cancel = true; stop.Set(); };
                stop.Wait();

                Console.WriteLine("stopping...");
                server.Stop();
            }

            return 0;
        }

        /// <summary>
        /// Every local queue with its driver, its port, and the detection verdict.
        /// INSTALL-TIME ONLY -- the running service never calls this.
        ///
        /// This is what turns the ambiguous three-candidate host into a sentence a
        /// commissioner can act on, and `install` prints it when it has to ask for
        /// --queue. Exit code 1 for unresolved so a script can branch on it.
        /// </summary>
        public static int PrintDetection()
        {
            IList<PrinterEntry> queues;
            try
            {
                queues = Spooler.EnumerateLocalQueues();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("could not enumerate local print queues: " + Protocol.OneLine(ex.Message));
                return 1;
            }

            Console.WriteLine("Local print queues ({0}):", queues.Count);
            foreach (PrinterEntry q in queues)
            {
                Console.WriteLine("  {0,-40} driver={1,-32} port={2,-16} {3}{4}",
                    q.Name, q.Driver, q.Port,
                    QueueResolver.IsZebraDriver(q.Driver) ? "ZEBRA " : "",
                    QueueResolver.IsZebraDriver(q.Driver)
                        ? (QueueResolver.IsLivePort(q.Port) ? "live-port" : "DEAD-PORT")
                        : "");
            }

            QueueResolution r = QueueResolver.Select(queues);
            Console.WriteLine();
            if (r.Resolved)
            {
                Console.WriteLine("ONE CANDIDATE: " + r.Diagnosis);
                Console.WriteLine("'install' would write that name into the conf file.");
                return 0;
            }
            Console.WriteLine("CANNOT CHOOSE: " + r.Diagnosis);
            return 1;
        }

        /// <summary>
        /// Configuration, binding and service state, for commissioning. Reads the
        /// conf -- it does not detect, so it reports what the service will actually do.
        /// </summary>
        public static int PrintStatus(string[] args)
        {
            BridgeConfig config = LoadConfig(args);
            var binding = new QueueBinding(config.Queue);

            foreach (string line in StartupBanner(config, binding.Diagnosis)) Console.WriteLine(line);

            Console.WriteLine();
            try
            {
                using (var sc = new ServiceController(Installer.ServiceName))
                    Console.WriteLine("service       {0} is {1}", Installer.ServiceName, sc.Status);
            }
            catch (Exception)
            {
                Console.WriteLine("service       {0} is NOT INSTALLED (run: MesZebraBridge.exe install)",
                    Installer.ServiceName);
            }

            // The queue is a name from a text file, so say whether the spooler
            // actually has it -- that is the mistyped-conf case, and PROTOCOL.md
            // requires ?STATUS to report it as ready=false rather than an error.
            if (binding.IsConfigured)
            {
                QueueStatus s = Spooler.ReadQueueStatus(binding.Queue);
                Console.WriteLine("spooler       queue {0} ready={1} jobs={2}",
                    Protocol.Quote(binding.Queue), s.Ready ? "true" : "false", s.Jobs);
                if (!s.Ready)
                    Console.WriteLine("              not ready -- is the name exactly right, and is the "
                                      + "printer on? 'detect' lists this machine's queues.");
            }

            return 0;
        }
    }
}
