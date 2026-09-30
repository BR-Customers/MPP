// Wire-protocol guard for the MES Zebra bridge, C# side.
//
// zebraPrinter/PROTOCOL.md is the contract three workstreams build against -- this
// service, LabelTransport's ACK read, and the Config Tool's test button. Every case
// in zebraPrinter/tests/test_bridge_protocol.py has a counterpart here, so the two
// implementations cannot drift apart silently.
//
// The spooler and the queue-status reader are injected, so nothing here needs a
// printer, a driver, or Windows print services.
//
// Run: dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj

using System.Text;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class ProtocolTests
    {
        [Fact]
        public void Bridge_version_is_the_one_PROTOCOL_md_publishes()
        {
            // PROTOCOL.md's verified exchange reads `OK bridge=1.0.0 ...`. A bump here
            // is a protocol change and needs the document changed first.
            Assert.Equal("1.0.0", Protocol.BridgeVersion);
        }

        private static SpoolResult SpoolOk(byte[] data)
        {
            return new SpoolResult(41, data.Length);
        }

        private static QueueStatus StatusOk()
        {
            return new QueueStatus("Zebra GX420d (RAW)", true, 0);
        }

        [Fact]
        public void An_empty_request_gets_no_reply()
        {
            // validateEndpoint connects and closes without sending. Replying to that
            // would be a protocol change; staying silent is the contract.
            Assert.Null(Protocol.HandleRequest(new byte[0], "Q", SpoolOk, StatusOk));
        }

        [Fact]
        public void A_null_request_gets_no_reply()
        {
            Assert.Null(Protocol.HandleRequest(null, "Q", SpoolOk, StatusOk));
        }

        [Fact]
        public void A_quoted_value_doubles_an_embedded_quote()
        {
            Assert.Equal("'Bob''s Zebra'", Protocol.Quote("Bob's Zebra"));
            Assert.Equal("'Zebra GX420d (RAW)'", Protocol.Quote("Zebra GX420d (RAW)"));
            Assert.Equal("''", Protocol.Quote(null));
        }

        [Fact]
        public void Oneline_collapses_every_whitespace_run_to_a_single_space()
        {
            // One-line framing is not negotiable, and Win32 messages are multi-line.
            Assert.Equal("a b c", Protocol.OneLine("a\r\n  b\t\tc\n"));
            Assert.Equal("", Protocol.OneLine("   "));
            Assert.Equal("", Protocol.OneLine(null));
        }

        [Fact]
        public void A_response_longer_than_the_cap_is_truncated_with_an_ellipsis()
        {
            string line = "ERR " + new string('x', 4000);
            string capped = Protocol.Cap(line);
            Assert.Equal(Protocol.MaxResponseBytes, capped.Length);
            Assert.EndsWith("...", capped);
            Assert.StartsWith("ERR xxx", capped);
            Assert.Equal("ERR short", Protocol.Cap("ERR short"));
        }

        [Fact]
        public void Status_reports_version_queue_and_readiness()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "Zebra GX420d (RAW)", SpoolOk, StatusOk);
            Assert.Equal("OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0", reply);
        }

        [Fact]
        public void Status_is_case_insensitive()
        {
            string lower = Protocol.HandleRequest(Encoding.ASCII.GetBytes("?status"), "Q", SpoolOk, StatusOk);
            string upper = Protocol.HandleRequest(Encoding.ASCII.GetBytes("?STATUS"), "Q", SpoolOk, StatusOk);
            // Assert the CONTENT too, not just that the two agree -- comparing them
            // alone passes against any stub that returns one constant for both.
            Assert.Equal(upper, lower);
            Assert.StartsWith("OK bridge=", lower);
        }

        [Fact]
        public void Status_tolerates_a_trailing_newline_from_a_line_oriented_client()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS\r\n"), "Q", SpoolOk, StatusOk);
            Assert.StartsWith("OK bridge=", reply);
        }

        [Fact]
        public void Status_reports_a_not_ready_queue()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "Q", SpoolOk, () => new QueueStatus("Q", false, 3));
            Assert.Contains("ready=false", reply);
            Assert.Contains("jobs=3", reply);
        }

        [Fact]
        public void A_quote_in_a_queue_name_is_doubled_on_the_wire()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "Q", SpoolOk,
                () => new QueueStatus("Bob's Zebra", true, 0));
            Assert.Contains("queue='Bob''s Zebra'", reply);
        }

        [Fact]
        public void An_unknown_command_is_refused_not_ignored()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?WAT"), "Q", SpoolOk, StatusOk);
            Assert.StartsWith("ERR unknown command", reply);
            Assert.Contains("?WAT", reply);
        }
    }
}
