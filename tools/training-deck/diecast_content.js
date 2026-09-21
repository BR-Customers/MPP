// Every word on the die cast training slides.
//
// Voice: grade 7-8. Short sentences. One idea each. Say what to press, in the
// order you press it. Screen labels are written **like this**, spelled exactly
// as the screen spells them -- the build strips them before scoring the reading
// level, because an operator reads them off the screen instead of decoding them.
//
// Shapes (checked by lib/checks.js):
//   steps    { id, kind, kicker, title, shot, steps[], markers[{n,target}], tip?, notes }
//   overview { id, kind, kicker, title, shot, zones[{letter,target,color,label}], notes }
//   title | divider | concept | glossary | summary -- no shot.
const ZONE = {
  blue: '2E86DE', orange: 'E67E22', purple: '8E44AD',
  teal: '16A085', red: 'C0392B', gold: 'B7950B',
};

module.exports = {
  meta: {
    title: 'Die Cast Terminal Training',
    subtitle: 'For operators and team leads',
    date: 'September 2026',
  },
  slides: [
    {
      id: 'title', kind: 'title',
      notes: 'Welcome. Today we learn the die cast screen at the press. It keeps track of every basket we make. '
        + 'Part 1 is for everyone. Part 2 is for team leads.',
    },
    {
      id: 'why', kind: 'concept', kicker: 'Why we do this', title: 'The ticket follows the parts',
      bullets: [
        'Every basket gets a ticket with a barcode.',
        'You scan that ticket into the screen when the basket starts.',
        'Honda can ask where one part came from. The ticket is how we answer.',
      ],
      notes: 'We are a Honda supplier. They can ask us to trace one part back to the press, the die and the shift that made it. '
        + 'The old paper sheets did this job. The screen does it now. A basket with no ticket scanned is a gap we cannot fill later.',
    },
    {
      id: 'words', kind: 'glossary', kicker: 'Before we start', title: 'Words you will see',
      terms: [
        { term: 'Die', meaning: 'The mold in the press.' },
        { term: 'Cavity', meaning: 'One spot in the die. Each one makes a part.' },
        { term: 'Basket', meaning: 'The bin the parts drop into.' },
        { term: 'Ticket (LTT)', meaning: 'The barcode tag on the basket.' },
        { term: 'Press counter', meaning: 'The shot number on the press.' },
        { term: 'Shift', meaning: 'Your work time, such as Second Shift.' },
        { term: 'Scrap', meaning: 'Parts we cannot use.' },
        { term: 'Reconcile', meaning: 'Settle up the numbers at the end of the shift.' },
      ],
      notes: 'Point at a real die and a real basket while you go through these. Most people know the things, not the words on the screen.',
    },
    {
      id: 'lot-overview', kind: 'overview', kicker: 'Screen tour', title: 'The Lot Management screen', shot: 'lot_overview',
      zones: [
        { letter: 'A', target: 'header', color: ZONE.blue, label: 'Top bar: shift, who is signed in, **Downtime**' },
        { letter: 'B', target: 'cell', color: ZONE.orange, label: 'Your machine' },
        { letter: 'C', target: 'tabs', color: ZONE.purple, label: 'The two tabs' },
        { letter: 'D', target: 'die', color: ZONE.teal, label: 'The die in this machine' },
        { letter: 'E', target: 'rows', color: ZONE.red, label: 'One row for each cavity' },
        { letter: 'F', target: 'footer', color: ZONE.gold, label: 'Open many baskets at once' },
      ],
      notes: 'This is the screen you use most. Each row is one cavity of the die. Rows are grouped by the part they make. '
        + 'Orange words mean the cavity has no basket yet.',
    },
    {
      id: 'pin', kind: 'steps', kicker: 'Start of shift', title: 'Sign in with your PIN', shot: 'pin_pad',
      steps: [
        'No number pad? Tap your name here.',
        'Type your five-digit PIN.',
        'Check the number shows here.',
      ],
      markers: [{ n: 1, target: 'chip' }, { n: 2, target: 'keypad' }, { n: 3, target: 'display' }],
      tip: 'Does your PIN start with 0? Type the 0. It counts.',
      notes: 'The PIN tells the screen who is working. It is not a password. '
        + 'Everything you do is saved under your name until someone else signs in.',
    },
    {
      id: 'pin-unknown', kind: 'steps', kicker: 'Start of shift', title: 'PIN not recognized', shot: 'pin_unknown',
      steps: [
        'Most of the time it is a typo. Tap **Re-type PIN**.',
        'New here? Tap **Register New User**. Add your initials and name.',
      ],
      markers: [{ n: 1, target: 'retype' }, { n: 2, target: 'register' }],
      notes: 'Re-type is the big button on purpose. One wrong digit would make a second copy of you. '
        + 'Only register if you are new, or you were given a new PIN.',
    },
    {
      id: 'cell', kind: 'steps', kicker: 'Start of shift', title: 'Pick your machine and check the die', shot: 'cell_pick',
      steps: [
        'Tap the machine box. Pick your machine.',
        'Check the die name. It must match the die in the press.',
      ],
      markers: [{ n: 1, target: 'cell' }, { n: 2, target: 'die' }],
      tip: 'Wrong die on the screen? Stop and call your team lead.',
      notes: 'One terminal can run more than one machine. The screen remembers the last machine used, so always check it. '
        + 'If the die is wrong, every basket goes against the wrong die.',
    },
    {
      id: 'open', kind: 'steps', kicker: 'Baskets', title: 'Open a basket', shot: 'open_scan',
      steps: [
        'Find the cavity that says **no basket**.',
        'Tap **Scan LTT**. Scan the ticket on the basket.',
        'Tap **Open 1 basket(s)**.',
      ],
      markers: [{ n: 1, target: 'row' }, { n: 2, target: 'scan' }, { n: 3, target: 'openBtn' }],
      tip: 'Scanning alone does not open it. You must tap the button.',
      notes: 'After the tap, the row shows the ticket number, and a green line says Basket opened. '
        + 'Scanned the wrong ticket? Tap Clear to empty the boxes and start again.',
    },
    {
      id: 'open-many', kind: 'steps', kicker: 'Changeover', title: 'Start many baskets at once', shot: 'open_many',
      steps: [
        'Scan a ticket into each empty row.',
        'Tap the **Open** button. It counts your scans.',
      ],
      markers: [{ n: 1, target: 'scans' }, { n: 2, target: 'openBtn' }],
      notes: 'Use this after a die change, when every cavity is empty. Scan every ticket first. Then open them all with one tap.',
    },
    {
      id: 'release', kind: 'steps', kicker: 'Baskets', title: 'Release a full basket', shot: 'release_top',
      steps: [
        'Tap **Release** on the full basket.',
        'Type the number on the press counter.',
        'Check the three boxes. They add up for you.',
        'Scrap in this basket? Tap **Add scrap reason**.',
      ],
      markers: [{ n: 1, target: 'rowRelease' }, { n: 2, target: 'counter' }, { n: 3, target: 'boxes' }, { n: 4, target: 'scrap' }],
      notes: 'The counter number fills in the piece count by itself. You never subtract anything. The screen does it. '
        + 'Did you swap the basket earlier? Use the number you wrote down then, not the number now. '
        + 'If your line counts pieces, type the count in the top box instead.',
    },
    {
      id: 'release-2', kind: 'steps', kicker: 'Baskets', title: 'Release a full basket (continued)', shot: 'release_bottom',
      steps: [
        'Scroll down in the box. Tap **Release basket**.',
        'Counter was reset? Tap **Counter reset / wrong total?** here.',
      ],
      markers: [{ n: 1, target: 'releaseBtn' }, { n: 2, target: 'fixCounter' }],
      notes: 'The buttons are at the bottom of the box, so scroll down to reach them. '
        + 'If you type no number, the screen warns you. The basket then closes at the count it already has.',
    },
    {
      id: 'void', kind: 'steps', kicker: 'Baskets', title: 'Void an empty basket', shot: 'void_dialog',
      steps: [
        'Tap **Void** on the basket.',
        'Check the ticket number. Tap **Void** to confirm.',
      ],
      markers: [{ n: 1, target: 'rowVoid' }, { n: 2, target: 'voidBtn' }],
      tip: 'Only for a basket with nothing in it. It cannot be undone.',
      notes: 'Use this when a ticket was opened by mistake and no parts went in. The ticket is scrapped and the cavity is free again.',
    },
    {
      id: 'rec-overview', kind: 'overview', kicker: 'Screen tour', title: 'The Reconcile Shift screen', shot: 'rec_overview',
      zones: [
        { letter: 'A', target: 'entry', color: ZONE.blue, label: 'Your shift and the press counter' },
        { letter: 'B', target: 'diewide', color: ZONE.orange, label: 'Shots lost on the whole die' },
        { letter: 'C', target: 'percavity', color: ZONE.purple, label: 'Each cavity, after **Compute**' },
        { letter: 'D', target: 'totals', color: ZONE.teal, label: 'The totals, and the button to send' },
      ],
      notes: 'Do this at the end of your shift, before you hand over. It settles the numbers for your die.',
    },
    {
      id: 'compute', kind: 'steps', kicker: 'End of shift', title: 'Start the shift entry', shot: 'rec_compute',
      steps: [
        'Pick your shift.',
        'Type the number on the press counter.',
        'Tap **Compute**.',
      ],
      markers: [{ n: 1, target: 'shift' }, { n: 2, target: 'counter' }, { n: 3, target: 'compute' }],
      tip: 'Shift just ended? The list shows the last three shifts.',
      notes: 'The list shows the current shift and the two before it, so you can still enter a shift that just ended. '
        + 'Compute fills in the table below.',
    },
    {
      id: 'die-wide', kind: 'steps', kicker: 'End of shift', title: 'Warm-up and test shots', shot: 'rec_diewide',
      steps: [
        'Type the warm-up shots.',
        'Type the quality test shots.',
        'Other shots lost on the whole die? Tap **Add die-wide scrap**.',
      ],
      markers: [{ n: 1, target: 'warmup' }, { n: 2, target: 'qtest' }, { n: 3, target: 'addDw' }],
      tip: 'Type shots, not pieces. The screen does the math.',
      notes: 'One lost shot costs one part on every cavity. So type the number of shots. '
        + 'The screen multiplies by the cavities for you.',
    },
    {
      id: 'good', kind: 'steps', kicker: 'End of shift', title: 'Check Good on each cavity', shot: 'rec_table',
      steps: [
        'Check the **Good** number. Change it if your count is different.',
        'Scrap on this cavity? Tap the number under **Cavity scrap**.',
      ],
      markers: [{ n: 1, target: 'goodBox' }, { n: 2, target: 'scrapBtn' }],
      notes: 'Good starts from the press counter, minus scrap. Once you type your own number, it stays. '
        + 'Lines that count baskets type a number here. Lines that read the counter can leave it.',
    },
    {
      id: 'scrap', kind: 'steps', kicker: 'End of shift', title: 'Add scrap on a cavity', shot: 'rec_scrap',
      steps: [
        'Pick the scrap reason.',
        'Type how many.',
        'More than one reason? Tap **Add scrap reason**.',
      ],
      markers: [{ n: 1, target: 'reason' }, { n: 2, target: 'qty' }, { n: 3, target: 'addReason' }],
      notes: 'The scrap button shows the total. The number in brackets is how many reasons you added.',
    },
    {
      id: 'variance', kind: 'steps', kicker: 'End of shift', title: 'An amber number needs a reason', shot: 'rec_variance',
      steps: [
        'This cavity does not add up. The number turns amber.',
        'The screen names the cavity that needs a reason.',
        '**Submit shift entry** stays grey until each amber number has a reason.',
      ],
      markers: [{ n: 1, target: 'varianceChip' }, { n: 2, target: 'needsReason' }, { n: 3, target: 'submit' }],
      notes: 'Amber means shots, good and scrap do not add up. That is not an error. It just needs a reason.',
    },
    {
      id: 'variance-reason', kind: 'steps', kicker: 'End of shift', title: 'Give a reason, then send', shot: 'rec_variance_reason',
      steps: [
        'Tap the amber number.',
        'Pick a reason. Not sure? Pick **Unknown** and add a short note.',
        'Tap **Submit shift entry**.',
      ],
      markers: [{ n: 1, target: 'varianceChip' }, { n: 2, target: 'reasonDd' }, { n: 3, target: 'submit' }],
      tip: 'Unknown is an honest answer. Do not guess a defect.',
      notes: 'Some reasons ask for a note. A short note, like found the cavity empty at 2:40, helps a lot later. '
        + 'Once you send it, the entry cannot be changed at the terminal. If you made a mistake, call your team lead.',
    },
    {
      id: 'fix-counter', kind: 'steps', kicker: 'When it looks wrong', title: 'The counter was reset', shot: 'fix_counter',
      steps: [
        'Tap **Fix counter**. Type what the counter shows now.',
        'Pick why it moved.',
        'Add a short note if you can.',
        'Tap **Record this reading**.',
      ],
      markers: [{ n: 1, target: 'reads' }, { n: 2, target: 'why' }, { n: 3, target: 'note' }, { n: 4, target: 'record' }],
      tip: 'Counter was set to zero? Type 0.',
      notes: 'Use this when the counter was zeroed, or a wrong number went in earlier. '
        + 'Pieces already in the baskets do not change.',
    },
    {
      id: 'downtime', kind: 'steps', kicker: 'When it looks wrong', title: 'When the machine stops', shot: 'downtime',
      steps: [
        'Tap **Downtime**.',
        'Check the machine and the shift.',
        'Machine down now? Tap **Start Downtime**.',
        'Forgot to log a stop? Tap **Add Past Event**.',
      ],
      markers: [{ n: 1, target: 'dtButton' }, { n: 2, target: 'scope' }, { n: 3, target: 'start' }, { n: 4, target: 'past' }],
      notes: 'Every stop needs a reason. The list shows the stops for this shift. Log them as soon as you can.',
    },
    {
      id: 'handover', kind: 'steps', kicker: 'End of shift', title: 'Hand over to the next operator', shot: 'pin_pad',
      steps: [
        'The next operator taps the name here.',
        'They type their own PIN.',
      ],
      markers: [{ n: 1, target: 'chip' }, { n: 2, target: 'keypad' }],
      notes: 'Never keep working under someone else\'s PIN. The screen saves every basket under the person signed in.',
    },
    {
      id: 'quickref', kind: 'summary', kicker: 'Keep this one', title: 'Quick reference',
      columns: [
        {
          heading: 'Every basket',
          items: [
            'Scan the ticket into the empty row.',
            'Press **Open 1 basket(s)**.',
            'When the basket is full, press **Release**.',
            'Type the press counter number.',
            'Press **Release basket**.',
          ],
        },
        {
          heading: 'End of shift',
          items: [
            'Open **Reconcile Shift**.',
            'Pick your shift.',
            'Type the press counter number.',
            'Press **Compute**.',
            'Add warm-up and test shots.',
            'Add scrap on each cavity.',
            'Give a reason for every amber number.',
            'Press **Submit shift entry**.',
          ],
        },
        {
          heading: 'When it looks wrong',
          items: [
            'Counter was reset? Press **Fix counter**.',
            'Machine stopped? Press **Downtime**.',
            'Die is wrong on screen? Call your team lead.',
            'Already sent the shift entry? Call your team lead.',
          ],
        },
      ],
      notes: 'Print this one slide and keep it at the press. It is the whole day on one page.',
    },
    {
      id: 'divider', kind: 'divider', title: 'Part 2', subtitle: 'For team leads',
      notes: 'Operators can stay for this part, but these jobs need a team lead sign-in.',
    },
    // Team lead screens: placeholders until the supervisor sign-in capture is
    // done with Jacques at the keyboard. They say only what is verified.
    {
      id: 'sup-access', kind: 'placeholder', kicker: 'Team lead', title: 'Supervisor Access',
      bullets: [
        'Some jobs need a team lead to sign in with their own account.',
        'The sign-in lasts five minutes.',
        'While it lasts, everything done here is saved under your name.',
      ],
      notes: 'Your sign-in covers the protected job you are doing. After five minutes it ends by itself.',
    },
    {
      id: 'die-mount', kind: 'placeholder', kicker: 'Team lead', title: 'Die Mount',
      bullets: [
        'Use it when a die is changed on a press.',
        'The screen must always show the die that is really in the press.',
      ],
      notes: 'If the screen shows the wrong die, every basket is saved against the wrong die.',
    },
    {
      id: 'reset-terminal', kind: 'placeholder', kicker: 'Team lead', title: 'Reset Terminal',
      bullets: [
        'Use it when the screen is stuck or shows the wrong place.',
      ],
      notes: 'The steps, and when not to use it, are added with the screen pictures.',
    },
    {
      id: 'dashboard', kind: 'placeholder', kicker: 'Team lead', title: 'The Die Cast Production screen',
      bullets: [
        'Shows good parts for this shift and the last shift.',
        'Pick one area, or leave it on all of die cast.',
        'One row for each press, with its die and part.',
      ],
      notes: 'This screen only reads numbers. It never changes anything. Good parts come from the shift entries operators send.',
    },
    {
      id: 'checklist', kind: 'summary', kicker: 'Team lead', title: 'Every shift',
      columns: [
        {
          heading: 'Start of shift',
          items: [
            'Check each press shows the right die.',
            'Check the presses that are running have baskets open.',
            'Fix a wrong die with **Die Mount**.',
          ],
        },
        {
          heading: 'During the shift',
          items: [
            'Watch the **Die Cast Production** screen.',
            'Help with any amber number nobody can explain.',
            'Check downtime has a reason on it.',
          ],
        },
        {
          heading: 'End of shift',
          items: [
            'Check every press sent its shift entry.',
            'Compare this shift with the last one.',
            'Pass on anything odd to the next team lead.',
          ],
        },
      ],
      notes: 'A shift entry that was never sent is the one to catch. The numbers cannot be fixed at the terminal afterwards.',
    },
  ],
};
