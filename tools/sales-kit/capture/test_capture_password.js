// test_capture_password.js -- capture.js must never save what was typed into a password field.
// Run: node --test test_capture_password.js   (drives the installed Chrome headless; no gateway needed)
const test = require('node:test');
const assert = require('node:assert/strict');
const puppeteer = require('puppeteer-core');
const { snapshotHtml } = require('./capture.js');

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PAGE = 'data:text/html,' + encodeURIComponent('<html><body><input id="t"><input type="password" id="p"></body></html>');

test('a filled password field refuses the snapshot; an empty one is saved without a value', async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new' });
  try {
    const page = await browser.newPage();
    await page.goto(PAGE);
    await page.type('#t', 's3cret!');
    await page.type('#p', 'hunter2');
    await assert.rejects(snapshotHtml(page), /password field has a value/);
    await page.$eval('#p', el => { el.value = ''; });
    const html = await snapshotHtml(page);
    assert.match(html, /s3cret!/);
    assert.doesNotMatch(html, /hunter2/);
    assert.doesNotMatch(html, /type="password"[^>]*value=/);
  } finally {
    await browser.close();
  }
});
