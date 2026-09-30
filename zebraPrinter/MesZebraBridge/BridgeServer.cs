// The socket. One request per connection: read until the peer half-closes, write
// one line, close.
//
// SO_EXCLUSIVEADDRUSE, not SO_REUSEADDR (spec section 3). On Windows SO_REUSEADDR
// permits a SECOND LIVE PROCESS to bind the same port, with delivery between them
// undefined -- unlike POSIX, where it only permits rebinding a TIME_WAIT port. For
// a print bridge that means labels disappearing into whichever process wins.
//
// Connections are served on the thread pool so one client holding a socket open
// cannot stall the next dispatch for the whole read timeout, which is what the
// Python bridge's serial accept loop does. The SPOOLER is serialised instead:
// job ordering at the queue is the thing that would otherwise be arbitrary.

using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace BlueRidge.MesZebraBridge
{
    public sealed class BridgeServer : IDisposable
    {
        private readonly IPAddress _bind;
        private readonly int _requestedPort;
        private readonly QueueBinding _binding;
        private readonly RollingLog _log;
        private readonly Func<string, byte[], SpoolResult> _spool;
        private readonly Func<string, QueueStatus> _status;
        private readonly object _spoolGate = new object();
        private readonly object _lifecycleGate = new object();

        private Socket _listener;
        private Thread _acceptThread;
        private volatile bool _stopping;

        /// <summary>
        /// PROTOCOL.md: without the client's half-close the server waits this long
        /// before answering. Settable so tests do not pay 2s each.
        /// </summary>
        public int ReadTimeoutMs { get; set; }

        /// <summary>The port actually bound. Differs from the request only when 0 was asked for.</summary>
        public int BoundPort { get; private set; }

        public BridgeServer(IPAddress bind, int port, QueueBinding binding, RollingLog log,
                            Func<string, byte[], SpoolResult> spool,
                            Func<string, QueueStatus> status)
        {
            if (bind == null) throw new ArgumentNullException("bind");
            if (binding == null) throw new ArgumentNullException("binding");
            if (log == null) throw new ArgumentNullException("log");
            if (spool == null) throw new ArgumentNullException("spool");
            if (status == null) throw new ArgumentNullException("status");

            _bind = bind;
            _requestedPort = port;
            _binding = binding;
            _log = log;
            _spool = spool;
            _status = status;
            ReadTimeoutMs = 2000;
        }

        /// <summary>
        /// Bind and start accepting. Throws on a bind failure -- deliberately, so the
        /// SCM records a failed start and the recovery actions fire. An UNRESOLVED
        /// QUEUE is not a bind failure and does not stop the listener (spec 3 vs 6.3).
        /// </summary>
        public void Start()
        {
            lock (_lifecycleGate)
            {
                if (_listener != null) throw new InvalidOperationException("already started");

                var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);

                // MUST be set before Bind; setting it afterwards throws.
                socket.ExclusiveAddressUse = true;

                socket.Bind(new IPEndPoint(_bind, _requestedPort));
                socket.Listen(16);

                _listener = socket;
                BoundPort = ((IPEndPoint)socket.LocalEndPoint).Port;
                _stopping = false;

                _acceptThread = new Thread(AcceptLoop);
                _acceptThread.IsBackground = true;
                _acceptThread.Name = "MesZebraBridge.Accept";
                _acceptThread.Start();

                _log.Info(string.Format("listening on {0}:{1}", _bind, BoundPort));
            }
        }

        public void Stop()
        {
            Thread accept;
            lock (_lifecycleGate)
            {
                _stopping = true;

                Socket socket = _listener;
                _listener = null;
                accept = _acceptThread;
                _acceptThread = null;

                // Closing the listener is what unblocks the blocking Accept below.
                if (socket != null)
                {
                    try { socket.Close(); } catch (Exception) { }
                    _log.Info("stopped listening on port " + BoundPort);
                }
            }

            if (accept != null) accept.Join(5000);
        }

        public void Dispose() { Stop(); }

        private void AcceptLoop()
        {
            while (!_stopping)
            {
                Socket conn;
                try
                {
                    conn = _listener.Accept();
                }
                catch (ObjectDisposedException)
                {
                    return;                       // Stop() closed the listener
                }
                catch (NullReferenceException)
                {
                    return;                       // Stop() nulled it mid-call
                }
                catch (SocketException ex)
                {
                    if (_stopping) return;
                    _log.Error("accept failed: " + ex.Message);
                    continue;
                }

                ThreadPool.QueueUserWorkItem(ServeOne, conn);
            }
        }

        private void ServeOne(object state)
        {
            var conn = (Socket)state;
            try
            {
                string peer = "?";
                try { peer = ((IPEndPoint)conn.RemoteEndPoint).Address.ToString(); }
                catch (Exception) { }

                conn.ReceiveTimeout = ReadTimeoutMs;
                conn.SendTimeout = ReadTimeoutMs;

                byte[] data = ReadRequest(conn, ReadTimeoutMs);

                // Log the source so a dispatch self-documents its origin: a
                // Gateway-scope print shows the Gateway's IP, a Script Console test
                // shows the local machine.
                _log.Info(string.Format("connection from {0} ({1} bytes)", peer, data.Length));

                string reply = Router.Route(data, _binding, SpoolSerialized, _status);
                if (reply != null)
                {
                    conn.Send(Encoding.ASCII.GetBytes(reply + "\n"));
                    _log.Info("  " + reply);
                }
            }
            catch (Exception ex)
            {
                _log.Error("handler error: " + ex.Message);
            }
            finally
            {
                try { conn.Shutdown(SocketShutdown.Both); } catch (Exception) { }
                try { conn.Close(); } catch (Exception) { }
            }
        }

        private SpoolResult SpoolSerialized(string queue, byte[] data)
        {
            lock (_spoolGate) { return _spool(queue, data); }
        }

        /// <summary>
        /// Read until the peer half-closes, the idle timeout, or the size cap.
        ///
        /// A FIN surfaces as Receive returning 0. A client that connects and HOLDS
        /// the socket open instead trips the receive timeout, which in .NET is a
        /// SocketException rather than a clean 0 -- unlike Python's socket.timeout
        /// sitting outside the loop. That asymmetry is the easy way to get this wrong.
        /// </summary>
        internal static byte[] ReadRequest(Socket conn, int timeoutMs)
        {
            conn.ReceiveTimeout = timeoutMs;
            var buffer = new byte[4096];

            using (var received = new MemoryStream())
            {
                while (received.Length < Protocol.MaxRequestBytes)
                {
                    int n;
                    try
                    {
                        n = conn.Receive(buffer);
                    }
                    catch (SocketException ex)
                    {
                        if (ex.SocketErrorCode == SocketError.TimedOut
                            || ex.SocketErrorCode == SocketError.ConnectionReset)
                            break;
                        throw;
                    }

                    if (n == 0) break;            // FIN: the half-close that ends the read
                    received.Write(buffer, 0, n);
                }

                byte[] all = received.ToArray();
                if (all.Length <= Protocol.MaxRequestBytes) return all;

                // The loop checks its cap after appending, so it can overshoot by up
                // to one buffer. Truncate to exactly the limit, so the `bytes=` in the
                // ACK is a number the Gateway can trust (PROTOCOL.md "Framing").
                var capped = new byte[Protocol.MaxRequestBytes];
                Array.Copy(all, capped, Protocol.MaxRequestBytes);
                return capped;
            }
        }
    }
}
