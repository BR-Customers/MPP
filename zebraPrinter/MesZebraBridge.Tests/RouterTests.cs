// One request -> one response line, with the conf'd queue in between.
//
// Two things are pinned here. First, the ORDER: silence before the queue check,
// because validateEndpoint's bare connect must get zero bytes on a terminal that
// is not commissioned yet. Second, that a missing Queue= still listens and says
// so -- spec 6.3 reads `Connection refused` as "bridge is down", which would send
// somebody to the wrong machine.
//
// There is no detection here. QueueResolver is install-time only.

using System;
using System.Text;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class RouterTests
    {
        private static SpoolResult SpoolOk(string queue, byte[] data)
        {
            return new SpoolResult(41, data.Length);
        }

        private static QueueStatus StatusOk(string queue)
        {
            return new QueueStatus(queue, true, 0);
        }

        [Fact]
        public void The_configured_queue_is_used_verbatim_with_no_detection()
        {
            var binding = new QueueBinding("Zebra GX420d (RAW)");

            string queueSeen = null;
            string reply = Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding,
                (q, d) => { queueSeen = q; return new SpoolResult(41, d.Length); }, StatusOk);

            Assert.Equal("Zebra GX420d (RAW)", queueSeen);
            Assert.Equal("OK queue='Zebra GX420d (RAW)' job=41 bytes=6", reply);
        }

        [Fact]
        public void A_name_that_is_not_on_this_host_is_passed_through_so_the_spooler_can_name_it()
        {
            // PROTOCOL.md requires the wrong-queue-name mistake to be caught by the
            // spooler's own ERR, not pre-empted here -- that ERR is the one that
            // lists what IS visible, which is the useful half.
            var binding = new QueueBinding("Typo GX420d");

            string reply = Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding,
                (q, d) => { throw new SpoolException("queue not found: 'Typo GX420d'; visible: A, B"); },
                StatusOk);

            Assert.Equal("ERR queue not found: 'Typo GX420d'; visible: A, B", reply);
        }

        [Fact]
        public void An_unconfigured_queue_refuses_the_print_and_says_what_to_do()
        {
            var binding = new QueueBinding(null);

            string reply = Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding, SpoolOk, StatusOk);

            Assert.StartsWith("ERR queue unconfigured: ", reply);
            Assert.Contains("install", reply);       // the fix, named on the wire
            Assert.DoesNotContain("\n", reply);
        }

        [Fact]
        public void An_unconfigured_queue_also_refuses_STATUS_rather_than_inventing_a_queue()
        {
            var binding = new QueueBinding("");

            string reply = Router.Route(Encoding.ASCII.GetBytes("?STATUS"), binding, SpoolOk, StatusOk);

            Assert.StartsWith("ERR queue unconfigured: ", reply);
        }

        [Fact]
        public void An_unconfigured_queue_never_reaches_the_spooler()
        {
            var binding = new QueueBinding(null);

            Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding,
                (q, d) => { throw new InvalidOperationException("must not spool without a queue"); },
                StatusOk);
        }

        [Fact]
        public void An_empty_request_is_silent_even_when_the_queue_is_unconfigured()
        {
            // ORDERING MATTERS, AND THIS IS THE TEST THAT SAYS SO. validateEndpoint's
            // bare-connect probe must get zero bytes whatever state the bridge is in,
            // so the silence check runs before the queue check. Backwards, this breaks
            // reachability testing on every un-commissioned terminal.
            var binding = new QueueBinding(null);

            Assert.Null(Router.Route(new byte[0], binding, SpoolOk, StatusOk));
            Assert.Null(Router.Route(null, binding, SpoolOk, StatusOk));
        }

        [Fact]
        public void An_empty_request_is_silent_when_the_queue_is_configured_too()
        {
            var binding = new QueueBinding("Zebra GX420d (RAW)");

            Assert.Null(Router.Route(new byte[0], binding, SpoolOk, StatusOk));
        }

        [Fact]
        public void A_binding_reports_whether_it_is_configured_and_why_for_the_startup_log()
        {
            var bound = new QueueBinding("Zebra GX420d (RAW)");
            Assert.True(bound.IsConfigured);
            Assert.Equal("Zebra GX420d (RAW)", bound.Queue);
            Assert.Contains("Zebra GX420d (RAW)", bound.Diagnosis);

            var unbound = new QueueBinding(null);
            Assert.False(unbound.IsConfigured);
            Assert.Null(unbound.Queue);
            Assert.Contains("no Queue=", unbound.Diagnosis);
        }

        [Fact]
        public void A_blank_or_whitespace_queue_value_counts_as_unconfigured()
        {
            // A conf line left as `Queue=` must not become a queue named "".
            Assert.False(new QueueBinding("").IsConfigured);
            Assert.False(new QueueBinding("   ").IsConfigured);
            Assert.Null(new QueueBinding("  ").Queue);
        }

        [Fact]
        public void A_configured_name_is_trimmed_because_a_conf_file_is_hand_edited()
        {
            Assert.Equal("Zebra GX420d (RAW)", new QueueBinding("  Zebra GX420d (RAW)  ").Queue);
        }
    }
}
