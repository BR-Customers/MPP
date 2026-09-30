// The wire protocol, transliterated from zebraPrinter/usb_tcp_bridge.py's
// handle_request / _quote / _oneline. Pure apart from the two injected callables,
// so the whole protocol is testable with no printer attached.
//
// zebraPrinter/PROTOCOL.md is normative and frozen. Change it there first.

using System;
using System.Text;

namespace BlueRidge.MesZebraBridge
{
    /// <summary>What the Windows spooler gave back: the job id and the bytes it took.</summary>
    public struct SpoolResult
    {
        public readonly int JobId;
        public readonly int BytesWritten;

        public SpoolResult(int jobId, int bytesWritten)
        {
            JobId = jobId;
            BytesWritten = bytesWritten;
        }
    }

    /// <summary>A queue's current state, as ?STATUS reports it.</summary>
    public struct QueueStatus
    {
        public readonly string Queue;
        public readonly bool Ready;
        public readonly int Jobs;

        public QueueStatus(string queue, bool ready, int jobs)
        {
            Queue = queue;
            Ready = ready;
            Jobs = jobs;
        }
    }

    public static class Protocol
    {
        /// <summary>Reported by ?STATUS. Must match PROTOCOL.md's version heading.</summary>
        public const string BridgeVersion = "1.0.0";

        /// <summary>PROTOCOL.md "Framing": a larger request is truncated at this limit.</summary>
        public const int MaxRequestBytes = 1048576;

        /// <summary>
        /// PROTOCOL.md caps the request but not the response. A "queue not found"
        /// error names every visible queue, which on a host with thirty of them would
        /// be a very long line, so it is capped here. The wire is ASCII, so one char
        /// is one byte and Length is the byte count.
        /// </summary>
        public const int MaxResponseBytes = 1024;

        private static readonly char[] Whitespace = { ' ', '\t', '\n', '\r', '\f', '\v' };

        /// <summary>Single-quote a wire value, doubling any embedded quote (PROTOCOL.md).</summary>
        public static string Quote(string value)
        {
            return "'" + (value ?? "").Replace("'", "''") + "'";
        }

        /// <summary>Collapse whitespace so an error can never break the one-line framing.</summary>
        public static string OneLine(string text)
        {
            if (text == null) return "";
            return string.Join(" ", text.Split(Whitespace, StringSplitOptions.RemoveEmptyEntries));
        }

        /// <summary>Hold a response inside MaxResponseBytes, marking the truncation.</summary>
        public static string Cap(string line)
        {
            if (line == null) return "";
            if (line.Length <= MaxResponseBytes) return line;
            return line.Substring(0, MaxResponseBytes - 3) + "...";
        }

        /// <summary>
        /// Map one request's bytes to one response line WITHOUT its trailing newline,
        /// or null when the protocol says stay silent.
        ///
        /// spool(data)  -> SpoolResult, throws on failure
        /// status()     -> QueueStatus
        /// </summary>
        public static string HandleRequest(byte[] data, string queueName,
                                           Func<byte[], SpoolResult> spool,
                                           Func<QueueStatus> status)
        {
            if (data == null || data.Length == 0) return null;
            return Cap("ERR not implemented");
        }
    }
}
