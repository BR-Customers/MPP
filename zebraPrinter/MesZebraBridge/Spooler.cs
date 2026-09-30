// The Windows spooler, RAW datatype, so ZPL passes through untransformed.
// A transliteration of zebraPrinter/usb_tcp_bridge.py's send_raw and queue_status.
//
// StartDocPrinterW's return value IS the spooler job id: verified 2026-09-29 against
// the real ZDesigner GX420d driver, with Get-PrintJob independently reporting
// `Id 15, MES ZPL, 38 bytes` for the same exchange (PROTOCOL.md, "Verified").

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace BlueRidge.MesZebraBridge
{
    /// <summary>One local print queue, as EnumPrinters level 2 reports it.</summary>
    public struct PrinterEntry
    {
        public readonly string Name;
        public readonly string Driver;
        public readonly string Port;
        public readonly uint Attributes;
        public readonly uint Status;

        public PrinterEntry(string name, string driver, string port, uint attributes, uint status)
        {
            Name = name;
            Driver = driver;
            Port = port;
            Attributes = attributes;
            Status = status;
        }
    }

    public static class Spooler
    {
        /// <summary>
        /// PRINTER_STATUS_PAUSED | _ERROR | _OFFLINE | _NOT_AVAILABLE | _NO_TONER.
        /// The same mask usb_tcp_bridge.py uses, reproduced exactly so ?STATUS agrees
        /// between the two implementations. NO_TONER is meaningless on a thermal Zebra
        /// and is kept only for that parity.
        /// </summary>
        public const uint NotReadyStatusMask =
            0x00000001u | 0x00000002u | 0x00000080u | 0x00001000u | 0x00040000u;

        private const int ERROR_FILE_NOT_FOUND = 2;
        private const int ERROR_INVALID_NAME = 123;
        private const int ERROR_INVALID_PRINTER_NAME = 1801;

        /// <summary>Hand bytes to a Windows print queue as one RAW job.</summary>
        public static SpoolResult SpoolRaw(string queueName, byte[] data)
        {
            if (data == null) data = new byte[0];

            IntPtr h;
            if (!NativeMethods.OpenPrinter(queueName, out h, IntPtr.Zero))
                throw QueueOpenFailure(queueName, Marshal.GetLastWin32Error());
            try
            {
                var di = new NativeMethods.DOCINFOW
                {
                    pDocName = "MES ZPL",
                    pOutputFile = null,
                    pDatatype = "RAW"
                };

                int job = NativeMethods.StartDocPrinter(h, 1, ref di);
                if (job == 0) throw Win32Failure("StartDocPrinter", Marshal.GetLastWin32Error());
                try
                {
                    if (!NativeMethods.StartPagePrinter(h))
                        throw Win32Failure("StartPagePrinter", Marshal.GetLastWin32Error());

                    int written;
                    if (!NativeMethods.WritePrinter(h, data, data.Length, out written))
                        throw Win32Failure("WritePrinter", Marshal.GetLastWin32Error());

                    return new SpoolResult(job, written);
                }
                finally
                {
                    // Mirrors the Python finally: the job is closed out even on a
                    // partial write, so the spooler is never left holding an open doc.
                    NativeMethods.EndPagePrinter(h);
                    NativeMethods.EndDocPrinter(h);
                }
            }
            finally
            {
                NativeMethods.ClosePrinter(h);
            }
        }

        /// <summary>
        /// The queue's real state. ready = the queue opens and reports no
        /// error/offline/paused bit; jobs = its current job count. Never throws --
        /// an unopenable queue is a not-ready answer, which is the honest one, and
        /// is what PROTOCOL.md requires for a queue name that is not on the host.
        /// </summary>
        public static QueueStatus ReadQueueStatus(string queueName)
        {
            IntPtr h;
            if (!NativeMethods.OpenPrinter(queueName, out h, IntPtr.Zero))
                return new QueueStatus(queueName, false, 0);
            try
            {
                int needed;
                NativeMethods.GetPrinter(h, 2, IntPtr.Zero, 0, out needed);
                if (needed <= 0) return new QueueStatus(queueName, false, 0);

                IntPtr buf = Marshal.AllocHGlobal(needed);
                try
                {
                    int unused;
                    if (!NativeMethods.GetPrinter(h, 2, buf, needed, out unused))
                        return new QueueStatus(queueName, false, 0);

                    var info = (NativeMethods.PRINTER_INFO_2)Marshal.PtrToStructure(
                        buf, typeof(NativeMethods.PRINTER_INFO_2));

                    return new QueueStatus(queueName,
                        (info.Status & NotReadyStatusMask) == 0, (int)info.cJobs);
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                }
            }
            catch (Exception)
            {
                return new QueueStatus(queueName, false, 0);
            }
            finally
            {
                NativeMethods.ClosePrinter(h);
            }
        }

        /// <summary>
        /// Every local print queue with its driver, port and status.
        ///
        /// PRINTER_ENUM_LOCAL only, deliberately without PRINTER_ENUM_CONNECTIONS:
        /// a USB Zebra is a local queue, per-user printer connections are not visible
        /// to LocalSystem anyway, and including them would only widen the candidate
        /// list that Task 7's detection has to disambiguate.
        /// </summary>
        public static IList<PrinterEntry> EnumerateLocalQueues()
        {
            var list = new List<PrinterEntry>();

            uint needed, returned;
            NativeMethods.EnumPrinters(NativeMethods.PRINTER_ENUM_LOCAL, null, 2,
                IntPtr.Zero, 0, out needed, out returned);
            if (needed == 0) return list;

            IntPtr buf = Marshal.AllocHGlobal((int)needed);
            try
            {
                uint needed2;
                if (!NativeMethods.EnumPrinters(NativeMethods.PRINTER_ENUM_LOCAL, null, 2,
                        buf, needed, out needed2, out returned))
                    throw Win32Failure("EnumPrinters", Marshal.GetLastWin32Error());

                int stride = Marshal.SizeOf(typeof(NativeMethods.PRINTER_INFO_2));
                for (int i = 0; i < returned; i++)
                {
                    var info = (NativeMethods.PRINTER_INFO_2)Marshal.PtrToStructure(
                        new IntPtr(buf.ToInt64() + (long)i * stride),
                        typeof(NativeMethods.PRINTER_INFO_2));

                    list.Add(new PrinterEntry(info.pPrinterName, info.pDriverName,
                        info.pPortName, info.Attributes, info.Status));
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }

            return list;
        }

        /// <summary>
        /// The documented ERR shape for a queue that is not on this host
        /// (PROTOCOL.md, Print): names what was tried and lists what is visible,
        /// which is what makes spec 6.3's QueueRejected actionable at the machine.
        /// </summary>
        private static SpoolException QueueOpenFailure(string queueName, int err)
        {
            if (err == ERROR_INVALID_PRINTER_NAME || err == ERROR_INVALID_NAME || err == ERROR_FILE_NOT_FOUND)
            {
                var visible = new List<string>();
                try
                {
                    foreach (PrinterEntry q in EnumerateLocalQueues()) visible.Add(q.Name);
                }
                catch (Exception)
                {
                    // Naming what we tried is worth more than naming nothing.
                }

                return new SpoolException(string.Format("queue not found: {0}; visible: {1}",
                    Protocol.Quote(queueName),
                    visible.Count == 0 ? "(none)" : string.Join(", ", visible.ToArray())));
            }

            return new SpoolException(string.Format("OpenPrinter {0} failed: [{1}] {2}",
                Protocol.Quote(queueName), err,
                Protocol.OneLine(new Win32Exception(err).Message)));
        }

        private static SpoolException Win32Failure(string call, int err)
        {
            return new SpoolException(string.Format("{0} failed: [{1}] {2}",
                call, err, Protocol.OneLine(new Win32Exception(err).Message)));
        }
    }
}
