// Renders tools/og/og.html to site/og.png at 1200x630.
// Needs playwright-core with an installed Chromium: NODE_PATH=<dir holding playwright-core> node tools/og/render.cjs
const path = require('path');
const { chromium } = require('playwright-core');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto('file://' + path.join(__dirname, 'og.html'));
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: path.join(__dirname, '..', '..', 'site', 'og.png') });
  await browser.close();
})();
