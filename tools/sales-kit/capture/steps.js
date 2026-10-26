// steps.js -- the capture steps for the sales kit, in capture order (see the plan's Task 5 table).
// Each: { name, terminal?, route?, actions?: [...], ready?: selector | 'text:...', viewport?, after? }
// Actions: {click:'Text'} {clickSel:'css'} {type:'abc', into?:'css'} {key:'Enter'} {wait:'text:...'} {sleep:ms}
module.exports = [
  { name: 'terminal-selector', route: '/shop-floor/terminal-selector', ready: 'text:Select your terminal' }
];
