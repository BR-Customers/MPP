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
    }
}
