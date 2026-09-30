// The local log file (spec section 3). A service has no console, so this is the
// only record at the machine, and on 2026-09-29 the Python bridge's equivalent
// survived only because someone happened to redirect stdout.
//
// Timestamps are LOCAL time with the UTC offset. CLAUDE.md's UTC-store/ET-display
// rule governs the database; this file is read by a person standing at the terminal,
// and the offset makes it unambiguous anyway.
//
// Nothing here throws. A print must never fail because logging did.

using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace BlueRidge.MesZebraBridge
{
    public sealed class RollingLog
    {
        private const string FilePrefix = "bridge-";
        private const string FileSuffix = ".log";
        private const string StampFormat = "yyyyMMdd";

        private readonly string _directory;
        private readonly int _retainDays;
        private readonly bool _echoToConsole;
        private readonly object _gate = new object();

        private string _lastPath;

        public RollingLog(string directory, int retainDays, bool echoToConsole)
        {
            _directory = directory;
            _retainDays = retainDays < 1 ? 1 : retainDays;
            _echoToConsole = echoToConsole;
        }

        /// <summary>Today's file. The name carries the date, so the log rolls daily.</summary>
        public string CurrentPath
        {
            get
            {
                return Path.Combine(_directory,
                    FilePrefix + DateTime.Now.ToString(StampFormat, CultureInfo.InvariantCulture) + FileSuffix);
            }
        }

        public void Info(string message) { Write("INFO", message); }

        public void Error(string message) { Write("ERROR", message); }

        public void Write(string level, string message)
        {
            string line = string.Format(CultureInfo.InvariantCulture, "{0} {1} {2}",
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff K", CultureInfo.InvariantCulture),
                level, Protocol.OneLine(message));

            lock (_gate)
            {
                try
                {
                    Directory.CreateDirectory(_directory);
                    string path = CurrentPath;
                    if (path != _lastPath)
                    {
                        _lastPath = path;
                        Prune();
                    }
                    File.AppendAllText(path, line + Environment.NewLine, Encoding.ASCII);
                }
                catch (Exception)
                {
                    // Swallowed on purpose: a lost log line is not worth a lost label.
                }
            }

            if (_echoToConsole)
            {
                try { Console.WriteLine(line); }
                catch (Exception) { }
            }
        }

        /// <summary>
        /// Delete our own day files older than the retention window. Only files
        /// matching our exact name shape are considered, so nothing else in the
        /// directory is ever touched.
        /// </summary>
        private void Prune()
        {
            try
            {
                DateTime cutoff = DateTime.Now.Date.AddDays(-_retainDays);
                foreach (string file in Directory.GetFiles(_directory, FilePrefix + "????????" + FileSuffix))
                {
                    string stamp = Path.GetFileNameWithoutExtension(file).Substring(FilePrefix.Length);
                    DateTime day;
                    if (DateTime.TryParseExact(stamp, StampFormat, CultureInfo.InvariantCulture,
                            DateTimeStyles.None, out day) && day < cutoff)
                        File.Delete(file);
                }
            }
            catch (Exception)
            {
            }
        }
    }
}
