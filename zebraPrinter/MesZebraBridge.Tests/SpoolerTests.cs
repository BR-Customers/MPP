// The winspool.drv shim. These touch the REAL local spooler but never a real
// printer: the failure paths use a queue name that cannot exist, and the
// enumeration is only checked for shape.

using System.Collections.Generic;
using System.Text;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class SpoolerTests
    {
        // Long enough that no host has it, and deliberately ASCII.
        private const string NoSuchQueue = "MesZebraBridge NoSuchQueue 8f3a1c47";

        [Fact]
        public void The_not_ready_mask_is_the_one_the_python_bridge_uses()
        {
            // PRINTER_STATUS_PAUSED | _ERROR | _OFFLINE | _NOT_AVAILABLE | _NO_TONER.
            // Reproduced exactly so ?STATUS agrees between the two implementations.
            Assert.Equal(0x00041083u, Spooler.NotReadyStatusMask);
        }

        [Fact]
        public void Reading_the_status_of_a_queue_that_does_not_exist_is_not_ready_and_never_throws()
        {
            QueueStatus s = Spooler.ReadQueueStatus(NoSuchQueue);
            Assert.Equal(NoSuchQueue, s.Queue);
            Assert.False(s.Ready);
            Assert.Equal(0, s.Jobs);
        }

        [Fact]
        public void Spooling_to_a_queue_that_does_not_exist_names_it_and_lists_what_is_visible()
        {
            // PROTOCOL.md's documented ERR shape, and spec 6.3's QueueRejected.
            var ex = Assert.Throws<SpoolException>(
                () => Spooler.SpoolRaw(NoSuchQueue, Encoding.ASCII.GetBytes("^XA^XZ")));

            Assert.StartsWith("queue not found: ", ex.Message);
            Assert.Contains(NoSuchQueue, ex.Message);
            Assert.Contains("; visible: ", ex.Message);
            Assert.DoesNotContain("\n", ex.Message);
        }

        [Fact]
        public void Enumerating_local_queues_returns_a_shaped_list_and_does_not_throw()
        {
            IList<PrinterEntry> queues = Spooler.EnumerateLocalQueues();
            Assert.NotNull(queues);
            foreach (PrinterEntry q in queues)
            {
                // A queue with no name would break both detection and the ACK.
                Assert.False(string.IsNullOrEmpty(q.Name));
            }
        }

        [Fact]
        public void A_printer_entry_carries_what_detection_needs_to_decide()
        {
            var e = new PrinterEntry("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002", 0x40u, 0u);
            Assert.Equal("Zebra GX420d (RAW)", e.Name);
            Assert.Equal("ZDesigner GX420d", e.Driver);
            Assert.Equal("USB002", e.Port);
            Assert.Equal(0x40u, e.Attributes);
            Assert.Equal(0u, e.Status);
        }
    }
}
