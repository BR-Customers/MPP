// Wrap the artifact body into a complete, self-contained .html document that
// survives being emailed: the Artifact host supplies <!doctype>, <head> and a
// small reset at publish time, so the published body alone is not a valid file.
import fs from 'node:fs';

const body = fs.readFileSync('book.html', 'utf8');

// Lift the <title> and the font <link> out of the body into a real <head>.
const title = (body.match(/<title>([\s\S]*?)<\/title>/) || [, 'Press Counter Review Book'])[1];
const links = [...body.matchAll(/<link\b[^>]*>/g)].map((m) => m[0]).join('\n  ');
const rest = body
  .replace(/<title>[\s\S]*?<\/title>\s*/, '')
  .replace(/<link\b[^>]*>\s*/g, '');

const head = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <meta name="author" content="Blue Ridge Automation">
  <meta name="description" content="Three die cast shifts driven end to end through the live MES terminal, showing how the press counter credits each basket when cavities roll mid-shift, when one cavity rolls ten times, and when nothing rolls at all.">
  <title>${title}</title>
  ${links}
  <style>
    /* The Artifact host normally supplies these; a standalone file must not
       rely on them. */
    html{color-scheme:light dark}
    body{margin:0}
    img{max-width:100%}
    [hidden]{display:none!important}

    /* Printing to PDF is how a document like this usually gets forwarded on,
       so keep the screenshots and their captions together and stop figures
       breaking across pages. */
    @media print{
      body{background:#fff}
      .wrap{max-width:none; padding:0 12mm 12mm}
      figure, .finding, .proves, .results, .setup{break-inside:avoid; page-break-inside:avoid}
      .scenario{break-before:page; page-break-before:always}
      .scenario:first-of-type{break-before:auto; page-break-before:auto}
      .shot img{min-width:0}
      .shot{overflow:visible}
      .tbl-scroll{overflow:visible}
      table{min-width:0}
      a{color:inherit; text-decoration:none}
      -webkit-print-color-adjust:exact; print-color-adjust:exact;
    }
    *{-webkit-print-color-adjust:exact; print-color-adjust:exact}
  </style>
</head>
<body>
`;

const out = head + rest.trim() + '\n</body>\n</html>\n';
fs.writeFileSync(process.env.OUT, out);
console.log('wrote', process.env.OUT, (out.length / 1048576).toFixed(2) + 'MB');
