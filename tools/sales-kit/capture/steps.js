// steps.js -- the capture steps for the sales kit, in capture order (see the plan's Task 5 table).
// Each: { name, terminal?: [tree path below the site], route?, actions?: [...], ready?, viewport?, after? }
// Actions: {click:'Text'} {clickSel:'css'} {type:'abc', into?:'css'} {typeNear:'LABEL', value:'x'}
//          {pin:'04218'} {key:'Enter'} {wait:'text:...'} {sleep:ms}
const DC = ['Die Cast', 'Terminal'];
const TRIM = ['Trim Shop', 'Terminal'];
const L1MIN = ['Machining & Assembly', 'Housing line', 'Machining In'];
const L1MOUT = ['Machining & Assembly', 'Housing line', 'Machining Out'];
const L1AOUT = ['Machining & Assembly', 'Housing line', 'Assembly Out'];
module.exports = [
  // core: the PIN pad (Track & Trace asks for an operator first), then sign in for later steps
  { name: 'core-pin-pad', terminal: DC, route: '/shop-floor/trace', actions: [{ wait: 'text:Enter your PIN' }, { pin: '042' }] },
  { name: 'm1-trace', terminal: DC, route: '/shop-floor/trace',
    actions: [{ sleep: 2000 }, { signIn: '04218' }, { typeNear: 'IDENTIFIER', value: '520100001' }, { click: 'Search' }, { sleep: 2000 }, { click: '520100001' }, { sleep: 3000 }] },
  { name: 'core-elevation', terminal: DC, route: '/shop-floor/die-cast/reconcile', ready: 'text:Authorize' },
  { name: 'core-supervisor', terminal: DC, route: '/shop-floor/supervisor' },
  // module 2
  { name: 'm2-diecast', terminal: DC, route: '/shop-floor/die-cast', actions: [{ sleep: 2000 }, { signIn: '04218' }, { click: 'Press 2' }, { click: 'Lot Management' }, { sleep: 1500 }] },
  { name: 'm2-reconcile', terminal: DC, route: '/shop-floor/die-cast',
    actions: [{ sleep: 2000 }, { signIn: '04218' }, { click: 'Press 2' }, { click: 'Reconcile Shift' }, { click: 'Select a shift' }, { click: 'First Shift', startsWith: true }, { typeNear: 'PRESS COUNTER', value: '105' }, { click: 'Compute' }, { sleep: 2000 }] },
  { name: 'm2-trim', terminal: TRIM, route: '/shop-floor/trim' },
  // module 1
  { name: 'm1-lot-search', terminal: DC, route: '/shop-floor/lot-search' },
  { name: 'm1-lot-detail', terminal: DC, route: '/shop-floor/lot-detail/28', actions: [{ click: 'History' }, { sleep: 1500 }] },
  { name: 'm1-lot-genealogy-tab', terminal: DC, route: '/shop-floor/lot-detail/28', actions: [{ click: 'Genealogy' }, { sleep: 1500 }] },
  { name: 'm1-casting-detail', terminal: DC, route: '/shop-floor/lot-detail/1', actions: [{ click: 'History' }, { sleep: 1500 }] },
  { name: 'm1-genealogy', terminal: DC, route: '/shop-floor/genealogy',
    actions: [{ typeNear: 'LOTNAME', value: 'MESL3000003' }, { click: 'Walk Tree' }, { sleep: 2500 }] },
  // module 3
  { name: 'm3-machining-in', terminal: L1MIN, route: '/shop-floor/machining-in' },
  { name: 'm3-machining-out', terminal: L1MOUT, route: '/shop-floor/machining-out', actions: [{ typeNear: 'PIECES', value: '16' }] },
  { name: 'm3-assembly', terminal: L1AOUT, route: '/shop-floor/assembly-nonserialized', actions: [{ click: 'Acknowledge' }, { sleep: 1000 }] },
  // the station after the last seal kits are used: its low-inventory lock
  { name: 'm3-assembly-locked', terminal: L1AOUT, route: '/shop-floor/assembly-nonserialized',
    actions: [{ sleep: 3000 }] }   // seal kits used up beforehand through the real procs (see the capture notes)
];
