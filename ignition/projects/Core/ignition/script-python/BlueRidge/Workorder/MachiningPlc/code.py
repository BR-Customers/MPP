"""BlueRidge.Workorder.MachiningPlc - RETIRED (terminal-mint spec 2026-07-07, §3.8/§5 B7).

   This module was the PLC-driven Machining OUT auto-complete + cell->cell auto-move
   watcher (FDS-06-008, CoupledDownstreamCellLocationId). The terminal-mint redesign
   retired cell-coupling: mints are line-resident, there is no cell->cell auto-move, and
   Workorder.MachiningOut_AutoComplete has been dropped. The watcher is therefore a
   no-op.

   Machining OUT is now a consume-MINT (Workorder.MachiningOut_Mint, via
   BlueRidge.Workorder.Machining.mint). If a PLC-triggered mint is ever commissioned,
   it is a NEW watcher that calls that mint -- a separate design/commissioning effort,
   not this auto-move. The gateway timer that invokes tickWatcher can be removed.
"""
import BlueRidge.Common.Util


def tickWatcher():
    """Retired no-op (cell-coupling auto-move removed). Kept only so any still-registered
       gateway timer invocation is harmless; safe to delete with its timer."""
    return
