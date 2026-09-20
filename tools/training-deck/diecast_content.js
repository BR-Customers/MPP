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
    // 4 lot_overview, 5 pin, 6 cell, 7 open, 8 open many, 9 release, 9b release buttons,
    // 10 void, 11 rec overview, 12 compute, 13 die-wide, 14 good + scrap, 15 variance,
    // 16 fix counter, 17 downtime, 18 hand-over -- added once their shots exist.
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
