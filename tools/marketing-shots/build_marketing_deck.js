// build_marketing_deck.js -- marketing screenshots into a PowerPoint, grouped
// by feature. No markup on the screenshots: each fills its own 16:9 slide, the
// feature name goes on a divider slide before its group, and the screenshot's
// name lives in the speaker notes and alt text, not on the picture.
//
//   node tools/marketing-shots/build_marketing_deck.js
const fs = require('node:fs');
const path = require('node:path');
const pptxgen = require('pptxgenjs');

const ROOT = path.resolve(__dirname, '../..');
const SHOTS = path.join(ROOT, 'docs/marketing/shots');
const OUT = path.join(ROOT, 'docs/marketing/MPP_MES_Screenshots.pptx');
const NAVY = '12263F', AMBER = 'FFB400', FONT = 'Calibri';

const shots = JSON.parse(fs.readFileSync(path.join(SHOTS, 'shots.json'), 'utf8'))
  .filter((s) => fs.existsSync(path.join(SHOTS, s.file)));

const pres = new pptxgen();
pres.layout = 'LAYOUT_WIDE';            // 13.333 x 7.5, the same 16:9 as the 1920x1080 shots
pres.title = 'MPP MES - Screenshots';
pres.author = 'Blue Ridge Automation';

function divider(title, sub) {
  const s = pres.addSlide();
  s.background = { color: NAVY };
  s.addText(title, { x: 0.8, y: 2.8, w: 11.7, h: 1.1, fontFace: FONT, fontSize: 40, bold: true, color: 'FFFFFF', margin: 0, isTextBox: true });
  if (sub) s.addText(sub, { x: 0.8, y: 3.9, w: 11.7, h: 0.6, fontFace: FONT, fontSize: 20, color: AMBER, margin: 0, isTextBox: true });
}

divider('MPP Manufacturing Execution System', `Screenshots - ${new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' })}`);

let current = null;
for (const s of shots) {
  if (s.section !== current) {
    current = s.section;
    const [area, feature] = current.split(': ');
    divider(feature || area, feature ? area : null);
  }
  const slide = pres.addSlide();
  slide.addImage({ path: path.join(SHOTS, s.file), x: 0, y: 0, w: 13.333, h: 7.5, altText: s.title });
  slide.addNotes(`${s.section} - ${s.title}`);
}

pres.writeFile({ fileName: OUT }).then(() => console.log(`wrote ${OUT} (${shots.length} screenshots)`));
