// The SCM wrapper. Chosen over a session process because "no touch" is stronger
// than "possible" (spec section 3): a service starts before any logon, survives
// the kiosk session being cycled, and is restarted by the SCM when it dies.
//
// On 2026-09-29 the Python bridge exited on a queued Ctrl-C the instant an
// unrelated probe released accept(), consumed the print job it was mid-way through
// handling, and stayed dead. Across 54 unattended plant PCs that reaches us as
// "the printer is broken."

using System;
using System.ServiceProcess;

namespace BlueRidge.MesZebraBridge
{
    internal sealed class BridgeService : ServiceBase
    {
        private BridgeServer _server;
        private RollingLog _log;

        public BridgeService()
        {
            ServiceName = Installer.ServiceName;
            CanStop = true;
            CanShutdown = true;
            CanPauseAndContinue = false;
            AutoLog = true;   // start/stop go in the Windows Event Log as well
        }

        protected override void OnStart(string[] args)
        {
            try
            {
                // Always the conf beside the exe -- the SCM binary path carries no
                // arguments, so a --conf override is a console-only thing.
                BridgeConfig config = Host.LoadConfig(new string[] { "service" });
                _server = Host.StartUp(config, false, out _log);
            }
            catch (Exception ex)
            {
                // Let it throw: the SCM records a failed start and the recovery
                // actions set at install time restart us. Logging first means the
                // reason survives even though the process does not.
                if (_log != null) _log.Error("STARTUP FAILED: " + Protocol.OneLine(ex.Message));
                throw;
            }
        }

        protected override void OnStop()
        {
            try
            {
                if (_server != null) _server.Stop();
                if (_log != null) _log.Info("service stopped");
            }
            catch (Exception ex)
            {
                if (_log != null) _log.Error("stop failed: " + Protocol.OneLine(ex.Message));
            }
        }

        protected override void OnShutdown() { OnStop(); }
    }
}
