// The socket. Binds 127.0.0.1:0 (ephemeral) everywhere -- nothing here touches
// 9100, which other work is using.
//
// The two exclusive-address tests are a pair on purpose: one shows the bridge
// refusing a second binder, the other shows what Windows does WITHOUT the option,
// so the option is demonstrably the thing doing the work.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class BridgeServerTests : IDisposable
    {
        private readonly List<BridgeServer> _servers = new List<BridgeServer>();
        private readonly string _logDir;

        public BridgeServerTests()
        {
            _logDir = Path.Combine(Path.GetTempPath(), "MesZebraBridgeSrv_" + Guid.NewGuid().ToString("N"));
        }

        public void Dispose()
        {
            foreach (BridgeServer s in _servers) { try { s.Dispose(); } catch (Exception) { } }
            try { if (Directory.Exists(_logDir)) Directory.Delete(_logDir, true); } catch (Exception) { }
        }

        private const string ConfiguredQueue = "Zebra GX420d (RAW)";

        private BridgeServer Serve(Func<string, byte[], SpoolResult> spool = null,
                                   Func<string, QueueStatus> status = null,
                                   string queue = ConfiguredQueue)
        {
            // The queue comes from the conf file and nothing else -- pass null to
            // model a terminal that has not been commissioned yet.
            var binding = new QueueBinding(queue);

            var server = new BridgeServer(IPAddress.Loopback, 0, binding,
                new RollingLog(_logDir, 14, false),
                spool ?? ((q, d) => new SpoolResult(7, d.Length)),
                status ?? (q => new QueueStatus(q, true, 0)));

            server.ReadTimeoutMs = 400;   // keep the suite quick; 2000 in production
            server.Start();
            _servers.Add(server);
            return server;
        }

        /// <summary>Write, half-close, read one line. Exactly what the Gateway does.</summary>
        private static string Exchange(int port, byte[] request)
        {
            using (var client = new TcpClient())
            {
                client.Connect(IPAddress.Loopback, port);
                client.ReceiveTimeout = 5000;
                NetworkStream stream = client.GetStream();
                if (request.Length > 0) stream.Write(request, 0, request.Length);
                stream.Flush();
                client.Client.Shutdown(SocketShutdown.Send);
                return new StreamReader(stream, Encoding.ASCII).ReadLine();
            }
        }

        [Fact]
        public void Half_close_then_read_the_ack_over_a_real_socket()
        {
            BridgeServer s = Serve();
            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));
            Assert.Equal("OK queue='Zebra GX420d (RAW)' job=7 bytes=6", line);
        }

        [Fact]
        public void The_reply_is_terminated_with_exactly_one_newline_and_nothing_follows()
        {
            BridgeServer s = Serve();
            using (var client = new TcpClient())
            {
                client.Connect(IPAddress.Loopback, s.BoundPort);
                client.ReceiveTimeout = 5000;
                NetworkStream stream = client.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("^XA^XZ");
                stream.Write(req, 0, req.Length);
                stream.Flush();
                client.Client.Shutdown(SocketShutdown.Send);

                var all = new MemoryStream();
                var buf = new byte[256];
                int n;
                while ((n = stream.Read(buf, 0, buf.Length)) > 0) all.Write(buf, 0, n);

                string text = Encoding.ASCII.GetString(all.ToArray());
                Assert.Equal("OK queue='Zebra GX420d (RAW)' job=7 bytes=6\n", text);
            }
        }

        [Fact]
        public void A_bare_connect_gets_no_bytes_and_no_hang()
        {
            // The reachability probe: connect, send nothing, close. Must not print
            // and must not leave the client waiting. This is validateEndpoint.
            BridgeServer s = Serve(spool: (q, d) =>
                throw new InvalidOperationException("a bare connect must never spool"));

            Assert.Null(Exchange(s.BoundPort, new byte[0]));
        }

        [Fact]
        public void Status_answers_over_the_socket()
        {
            BridgeServer s = Serve(status: q => new QueueStatus(q, true, 0));
            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("?STATUS"));
            Assert.Equal("OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0", line);
        }

        [Fact]
        public void A_client_that_sends_then_holds_the_socket_open_still_gets_its_ack_after_the_timeout()
        {
            // No half-close. PROTOCOL.md: the server waits out the idle timeout and
            // answers anyway -- slower, but never a dropped label.
            BridgeServer s = Serve();
            using (var client = new TcpClient())
            {
                client.Connect(IPAddress.Loopback, s.BoundPort);
                client.ReceiveTimeout = 5000;
                NetworkStream stream = client.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("^XA^XZ");
                stream.Write(req, 0, req.Length);
                stream.Flush();
                // deliberately NO Shutdown(Send)
                string line = new StreamReader(stream, Encoding.ASCII).ReadLine();
                Assert.Equal("OK queue='Zebra GX420d (RAW)' job=7 bytes=6", line);
            }
        }

        [Fact]
        public void An_unconfigured_queue_answers_over_the_socket_rather_than_refusing_the_connection()
        {
            // Spec 6.3 maps `Connection refused` to "bridge is down". A conf file
            // with no Queue= is a different fault needing a different fix, so it
            // must not present that way.
            BridgeServer s = Serve(queue: null);

            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));

            Assert.StartsWith("ERR queue unconfigured: ", line);
        }

        [Fact]
        public void An_unconfigured_bridge_still_answers_a_bare_connect_with_silence()
        {
            // Both halves at once, over a real socket: the un-commissioned terminal
            // is exactly where validateEndpoint's probe gets used.
            BridgeServer s = Serve(queue: null);

            Assert.Null(Exchange(s.BoundPort, new byte[0]));
        }

        [Fact]
        public void A_spooler_failure_comes_back_as_one_ERR_line()
        {
            BridgeServer s = Serve(spool: (q, d) =>
                throw new SpoolException("queue not found: 'X'; visible: A, B"));

            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));

            Assert.Equal("ERR queue not found: 'X'; visible: A, B", line);
        }

        [Fact]
        public void Two_requests_are_served_concurrently()
        {
            // A status callback that will not return until BOTH connections are
            // inside it. A serial accept loop deadlocks here and the test fails on
            // the assertion rather than hanging forever.
            var arrived = new CountdownEvent(2);
            BridgeServer s = Serve(status: q =>
            {
                arrived.Signal();
                bool both = arrived.Wait(TimeSpan.FromSeconds(5));
                return new QueueStatus(q, both, 0);
            });

            string a = null, b = null;
            var t1 = new Thread(() => a = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("?STATUS")));
            var t2 = new Thread(() => b = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("?STATUS")));
            t1.Start(); t2.Start();
            Assert.True(t1.Join(TimeSpan.FromSeconds(15)));
            Assert.True(t2.Join(TimeSpan.FromSeconds(15)));

            Assert.Contains("ready=true", a);
            Assert.Contains("ready=true", b);
        }

        [Fact]
        public void The_spooler_is_serialised_so_job_order_at_the_queue_is_not_arbitrary()
        {
            int concurrent = 0;
            int maxConcurrent = 0;
            var gate = new object();

            BridgeServer s = Serve(spool: (q, d) =>
            {
                lock (gate) { concurrent++; if (concurrent > maxConcurrent) maxConcurrent = concurrent; }
                Thread.Sleep(50);
                lock (gate) { concurrent--; }
                return new SpoolResult(1, d.Length);
            });

            var threads = new List<Thread>();
            for (int i = 0; i < 4; i++)
            {
                var t = new Thread(() => Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ")));
                threads.Add(t);
                t.Start();
            }
            foreach (Thread t in threads) Assert.True(t.Join(TimeSpan.FromSeconds(15)));

            Assert.Equal(1, maxConcurrent);
        }

        [Fact]
        public void A_request_over_one_mebibyte_is_truncated_to_exactly_the_limit()
        {
            int spooledBytes = -1;
            BridgeServer s = Serve(spool: (q, d) => { spooledBytes = d.Length; return new SpoolResult(1, d.Length); });

            var oversized = new byte[Protocol.MaxRequestBytes + 50000];
            for (int i = 0; i < oversized.Length; i++) oversized[i] = (byte)'x';

            string line = Exchange(s.BoundPort, oversized);

            Assert.Equal(Protocol.MaxRequestBytes, spooledBytes);
            Assert.Equal("OK queue='Zebra GX420d (RAW)' job=1 bytes=1048576", line);
        }

        [Fact]
        public void The_bridge_refuses_a_second_binder_on_its_port()
        {
            // SO_EXCLUSIVEADDRUSE. The intruder asks for SO_REUSEADDR, which on a
            // plain listener WOULD succeed (see the next test) -- so this assertion
            // is specifically about the option, not merely about the port being busy.
            BridgeServer s = Serve();

            var intruder = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                intruder.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                var ex = Assert.Throws<SocketException>(
                    () => intruder.Bind(new IPEndPoint(IPAddress.Loopback, s.BoundPort)));

                // AccessDenied (WSAEACCES), NOT AddressAlreadyInUse. The refusal code
                // is decided by the INTRUDER's SO_REUSEADDR request, not by the
                // holder's exclusive-use flag -- a denied reuse is WSAEACCES. Measured
                // on this machine, holder option x intruder option:
                //
                //   holder EXCLUSIVE  + intruder REUSEADDR -> AccessDenied       (refused)
                //   holder EXCLUSIVE  + intruder plain     -> AddressAlreadyInUse (refused)
                //   holder REUSEADDR  + intruder REUSEADDR -> BINDS (the steal, next test)
                //   holder plain      + intruder REUSEADDR -> AccessDenied       (refused)
                //
                // The plan predicted AddressAlreadyInUse here, which is what a plain
                // intruder gets. What matters is that the bind is REFUSED at all; the
                // next test is what shows the option is the thing doing the refusing.
                Assert.Equal(SocketError.AccessDenied, ex.SocketErrorCode);
            }
            finally
            {
                intruder.Close();
            }
        }

        [Fact]
        public void Without_exclusive_use_windows_lets_a_second_live_socket_steal_the_port()
        {
            // Why SO_EXCLUSIVEADDRUSE is not optional on Windows, pinned so nobody
            // "simplifies" BridgeServer.Start back to the default. Unlike POSIX,
            // SO_REUSEADDR here admits a second LIVE socket, with delivery between
            // the two undefined -- which for a print bridge means labels vanishing
            // into whichever process happens to win.
            var first = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            var second = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                first.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                first.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                first.Listen(1);
                int port = ((IPEndPoint)first.LocalEndPoint).Port;

                second.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                second.Bind(new IPEndPoint(IPAddress.Loopback, port));

                Assert.Equal(port, ((IPEndPoint)second.LocalEndPoint).Port);
            }
            finally
            {
                first.Close();
                second.Close();
            }
        }

        [Fact]
        public void Stop_releases_the_port_and_is_idempotent()
        {
            BridgeServer s = Serve();
            int port = s.BoundPort;

            s.Stop();
            s.Stop();   // must not throw

            var rebind = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                rebind.ExclusiveAddressUse = true;
                rebind.Bind(new IPEndPoint(IPAddress.Loopback, port));
                rebind.Listen(1);
            }
            finally
            {
                rebind.Close();
            }
        }

        [Fact]
        public void A_dispatch_is_logged_with_its_source_address_and_the_reply()
        {
            // Spec section 1: diagnosing 2026-09-29's label needed three uncorrelated
            // sources, one of them a human reading a console. The log is the machine's
            // own copy, and it self-documents where a print came from.
            BridgeServer s = Serve();
            var log = new RollingLog(_logDir, 14, false);

            Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));
            Thread.Sleep(200);   // the handler logs after the send, on a pool thread

            string text = File.ReadAllText(log.CurrentPath);
            Assert.Contains("connection from 127.0.0.1", text);
            Assert.Contains("OK queue='Zebra GX420d (RAW)' job=7 bytes=6", text);
        }
    }
}
