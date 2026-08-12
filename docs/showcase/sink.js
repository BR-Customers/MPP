// Local sink: receives {name, dataUrl} POSTs from the in-app browser and writes
// the decoded image to docs/showcase/screenshots/<name>. CORS-open (localhost only).
const http = require('http');
const fs = require('fs');
const path = require('path');
const OUT = path.join(__dirname, 'screenshots');
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};
http.createServer((req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  if (req.method === 'POST') {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      try {
        const { name, dataUrl } = JSON.parse(body);
        const b64 = dataUrl.replace(/^data:image\/\w+;base64,/, '');
        fs.writeFileSync(path.join(OUT, name), Buffer.from(b64, 'base64'));
        res.writeHead(200, cors); res.end('ok ' + name);
        console.log('saved', name, Math.round(b64.length / 1024) + 'KB');
      } catch (e) { res.writeHead(500, cors); res.end('err ' + e.message); }
    });
    return;
  }
  res.writeHead(404, cors); res.end();
}).listen(9977, '127.0.0.1', () => console.log('sink on http://127.0.0.1:9977'));
