// winspool.drv, declared to match zebraPrinter/usb_tcp_bridge.py's ctypes block
// argument for argument. The W entry points are named explicitly rather than left
// to CharSet auto-mapping, so there is no ambiguity about which one is bound.

using System;
using System.Runtime.InteropServices;

namespace BlueRidge.MesZebraBridge
{
    internal static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct DOCINFOW
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
            [MarshalAs(UnmanagedType.LPWStr)] public string pDatatype;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct PRINTER_INFO_2
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string pServerName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pPrinterName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pShareName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pPortName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pDriverName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pComment;
            [MarshalAs(UnmanagedType.LPWStr)] public string pLocation;
            public IntPtr pDevMode;
            [MarshalAs(UnmanagedType.LPWStr)] public string pSepFile;
            [MarshalAs(UnmanagedType.LPWStr)] public string pPrintProcessor;
            [MarshalAs(UnmanagedType.LPWStr)] public string pDatatype;
            [MarshalAs(UnmanagedType.LPWStr)] public string pParameters;
            public IntPtr pSecurityDescriptor;
            public uint Attributes;
            public uint Priority;
            public uint DefaultPriority;
            public uint StartTime;
            public uint UntilTime;
            public uint Status;
            public uint cJobs;
            public uint AveragePPM;
        }

        internal const uint PRINTER_ENUM_LOCAL = 0x00000002;

        [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);

        [DllImport("winspool.drv", EntryPoint = "ClosePrinter", SetLastError = true)]
        internal static extern bool ClosePrinter(IntPtr hPrinter);

        /// <summary>Returns the spooler JOB ID, or 0 on failure. Verified 2026-09-29.</summary>
        [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern int StartDocPrinter(IntPtr hPrinter, int level, ref DOCINFOW pDocInfo);

        [DllImport("winspool.drv", EntryPoint = "EndDocPrinter", SetLastError = true)]
        internal static extern bool EndDocPrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "StartPagePrinter", SetLastError = true)]
        internal static extern bool StartPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "EndPagePrinter", SetLastError = true)]
        internal static extern bool EndPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "WritePrinter", SetLastError = true)]
        internal static extern bool WritePrinter(IntPtr hPrinter, byte[] pBytes, int dwCount, out int dwWritten);

        [DllImport("winspool.drv", EntryPoint = "GetPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool GetPrinter(IntPtr hPrinter, int level, IntPtr pPrinter, int cbBuf, out int pcbNeeded);

        [DllImport("winspool.drv", EntryPoint = "EnumPrintersW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool EnumPrinters(uint flags, string name, uint level,
            IntPtr pPrinterEnum, uint cbBuf, out uint pcbNeeded, out uint pcReturned);
    }
}
