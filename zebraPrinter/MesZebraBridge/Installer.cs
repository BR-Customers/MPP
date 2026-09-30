// Self-install: SCM registration, restart-on-failure recovery, and the service's
// own inbound firewall rule scoped to the Gateway (spec sections 3 and 7).
// Task 13 implements it; this is the shape the rest of the program compiles against.

using System;

namespace BlueRidge.MesZebraBridge
{
    public static class Installer
    {
        public const string ServiceName = "MesZebraBridge";

        public static int Install(string[] args)
        {
            Console.Error.WriteLine("install is not implemented yet");
            return 1;
        }

        public static int SetQueue(string[] args)
        {
            Console.Error.WriteLine("set-queue is not implemented yet");
            return 1;
        }

        public static int Uninstall()
        {
            Console.Error.WriteLine("uninstall is not implemented yet");
            return 1;
        }
    }
}
