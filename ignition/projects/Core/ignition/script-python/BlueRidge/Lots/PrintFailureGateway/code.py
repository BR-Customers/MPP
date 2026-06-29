"""BlueRidge.Lots.PrintFailureGateway - shipping-label print-failure lifecycle (Arc 2 Phase 7; FDS-07-006b).

   - sweepTick() (every ~5 min): find stranded ShippingLabel rows (PrintedAt NULL AND
     PrintFailedAt NULL AND CreatedAt older than ~60s -- a Gateway restart between
     Container_Complete commit and print dispatch), re-fire ShippingDispatcher; mark
     PrintFailedAt on a second strand; supervisor + IT alarm when > 5 stranded at once.
   - broadcastTick() (every ~5 s): find failed prints (PrintFailedAt NOT NULL AND
     BannerAcknowledgedAt NULL) and broadcast 'print-failure-alert' to sessions; the
     PrintFailureBanner component filters by its terminal.

   SIM/SKELETON: the stranded-label read + the PrintedAt/PrintFailedAt mark procs are not
   yet built (hardware-gated -- no networked Zebra in dev), so both ticks are guarded
   no-ops here. Building Lots.ShippingLabel_GetStranded + _RecordDispatch and wiring the
   re-dispatch is the print-failure commissioning step. Fully guarded.
"""
import BlueRidge.Common.Util
import BlueRidge.Lots.ShippingDispatcher


def sweepTick():
    # SKELETON: requires Lots.ShippingLabel_GetStranded + a mark proc (deferred). When
    # built: for each stranded label -> ShippingDispatcher.dispatch(aimShipperId, terminal);
    # second strand -> mark PrintFailedAt; > 5 stranded -> supervisor/IT alarm.
    return


def broadcastTick():
    # SKELETON: requires a failed-print read (PrintFailedAt NOT NULL AND
    # BannerAcknowledgedAt NULL). When built: send 'print-failure-alert' per failed label,
    # scope session; the PrintFailureBanner filters by session.custom.terminal.
    return
