// One request -> one response line, with the conf'd queue in between.
//
// The silence check comes FIRST and is not negotiable: validateEndpoint connects
// and closes without sending, and that bare-connect probe must get zero bytes back
// whatever state the bridge is in -- including on a terminal that has no Queue= yet.

using System;

namespace BlueRidge.MesZebraBridge
{
    public static class Router
    {
        public static string Route(byte[] data, QueueBinding binding,
                                   Func<string, byte[], SpoolResult> spool,
                                   Func<string, QueueStatus> status)
        {
            if (data == null || data.Length == 0) return null;

            if (!binding.IsConfigured)
                return Protocol.Cap("ERR queue unconfigured: " + Protocol.OneLine(binding.Diagnosis));

            string queue = binding.Queue;
            return Protocol.HandleRequest(data, queue,
                d => spool(queue, d),
                () => status(queue));
        }
    }
}
