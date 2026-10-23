// Рисует картинки для README из scenes.html (макеты интерфейса с условными данными).
// Запуск: node scripts/promo/render.js  → PNG в scripts/promo/out/, затем сжать в docs/images/*.jpg.
const { chromium } = require('playwright');
const path = require('path');

(async () => {
  const dir = __dirname;
  const out = path.join(dir, 'out');
  require('fs').mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 1500, height: 900 } });
  await page.goto('file://' + path.join(dir, 'scenes.html'));
  for (const id of ['hero', 'island', 'tabs', 'menubar']) {
    await page.locator('#' + id).screenshot({ path: path.join(out, id + '.png') });
  }
  const icon = await browser.newPage({ deviceScaleFactor: 1, viewport: { width: 600, height: 600 } });
  await icon.goto('file://' + path.join(dir, 'scenes.html'));
  await icon.evaluate(() => { document.body.style.background = 'transparent'; });
  await icon.locator('#icon').screenshot({ path: path.join(out, 'icon.png'), omitBackground: true });
  await browser.close();
})();
