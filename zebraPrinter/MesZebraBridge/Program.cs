// Verb dispatch.
//
// No arguments under the SCM means "be the service". No arguments at an interactive
// prompt means the human double-clicked it, so print usage instead of the SCM's
// baffling "cannot be started from the command line" dialog.

using System;
using System.ServiceProcess;

namespace BlueRidge.MesZebraBridge
{
    public static class Program
    {
        public const string Usage =
@"MES Zebra Bridge " + Protocol.BridgeVersion + @" -- Blue Ridge Automation
Accepts ZPL on TCP 9100 and spools it to the local Zebra queue (RAW).
Wire protocol: zebraPrinter/PROTOCOL.md v" + Protocol.BridgeVersion + @"

  MesZebraBridge.exe install             register the service, set SCM restart-on-failure
                                         recovery, write the conf, add the inbound firewall
                                         rule, start, and report the queue it bound.
                                         Safe to re-run: it reconfigures and restarts.
  MesZebraBridge.exe set-queue ""<name>""   point the bridge at a different print queue
                                         after a printer swap, and restart
  MesZebraBridge.exe uninstall           stop, remove the service, remove the firewall rule
  MesZebraBridge.exe run                 run in this console instead of as a service
  MesZebraBridge.exe status              configuration, bound queue, and service state
  MesZebraBridge.exe detect              list every local print queue and say whether one
                                         Zebra candidate can be picked out

Options (install / set-queue / run / status):
  --conf <path>         use this conf file instead of MesZebraBridge.conf beside the exe.
  --queue <name>        the exact Windows print queue name to bind. Required when
                        this machine has zero or several Zebra candidates.
  --gateway <address>   the only source address the firewall rule admits. Normally
                        already in the shipped conf file; install refuses without it.
  --port <n>            TCP port to listen on. Default 9100.
  --log-dir <path>      where the daily bridge-YYYYMMDD.log files go.
  --retain-days <n>     how many days of log files to keep. Default 14.

There is no runtime queue detection: the bridge spools to the queue named in its
conf file, and answers 'ERR queue unconfigured' when there is none.

install, set-queue and uninstall require an elevated (Administrator) prompt.
";

        public static int Main(string[] args)
        {
            if (args == null || args.Length == 0)
            {
                if (!Environment.UserInteractive)
                {
                    ServiceBase.Run(new BridgeService());
                    return 0;
                }
                Console.Error.Write(Usage);
                return 2;
            }

            switch (args[0].ToLowerInvariant())
            {
                case "install":   return Installer.Install(args);
                case "set-queue": return Installer.SetQueue(args);
                case "uninstall": return Installer.Uninstall();
                case "run":       return Host.RunConsole(args);
                case "status":    return Host.PrintStatus(args);
                case "detect":    return Host.PrintDetection();
                default:
                    Console.Error.WriteLine("unknown verb: " + args[0]);
                    Console.Error.WriteLine();
                    Console.Error.Write(Usage);
                    return 2;
            }
        }
    }
}
