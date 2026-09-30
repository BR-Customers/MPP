// The wire protocol, transliterated from zebraPrinter/usb_tcp_bridge.py's
// handle_request / _quote / _oneline. Pure apart from the two injected callables,
// so the whole protocol is testable with no printer attached.
//
// zebraPrinter/PROTOCOL.md is normative and frozen. Change it there first.

using System;

namespace BlueRidge.MesZebraBridge
{
    public static class Protocol
    {
        /// <summary>Reported by ?STATUS. Must match PROTOCOL.md's version heading.</summary>
        public const string BridgeVersion = "1.0.0";
    }
}
