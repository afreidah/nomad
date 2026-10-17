// Drives the Nomad web UI jobs page in headless Chrome and reports every
// "Error fetching jobs" toast plus the shape of each error the jobs index
// controller logs. Paging and filtering abort the in-flight blocking queries,
// which is what surfaces the spurious "status undefined" toast.
//
// Usage: node ui-toast-check.js <nomad-addr> <chrome-binary> [rounds]
// Prints one JSON object on stdout: { toasts: [...], errors: [...] }.

const { chromium } = require('playwright-core');

const [addr, chrome, roundsArg] = process.argv.slice(2);
const rounds = Number(roundsArg || 3);
if (!addr || !chrome) {
  console.error('usage: node ui-toast-check.js <nomad-addr> <chrome> [rounds]');
  process.exit(2);
}

(async () => {
  const browser = await chromium.launch({ executablePath: chrome, headless: true });
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const toasts = [];
  const errors = [];

  // Record each critical toast as it renders; a later navigation would
  // otherwise clear it before it could be counted.
  await page.exposeFunction('__recordToast', (t) => toasts.push(t));
  await page.addInitScript(() => {
    const seen = new WeakSet();
    new MutationObserver(() => {
      document.querySelectorAll('.flash-message.alert-critical').forEach((el) => {
        if (seen.has(el)) return;
        seen.add(el);
        window.__recordToast(el.textContent.replace(/\s+/g, ' ').trim());
      });
    }).observe(document, { childList: true, subtree: true });
  });

  // The controller logs "error fetching job ids|allocs" with the error object
  // right before raising the toast; capture its name/message/status.
  page.on('console', async (msg) => {
    if (!msg.text().startsWith('error fetching')) return;
    const [label, err] = msg.args();
    const shape = err
      ? await err
          .evaluate((e) => ({
            name: e && e.name,
            message: e && String(e.message).split('\n')[0],
            status: e && e.errors && e.errors[0] && e.errors[0].status,
          }))
          .catch(() => null)
      : null;
    errors.push({ label: await label.jsonValue().catch(() => msg.text()), ...shape });
  });

  // Dispatch the click on the button itself: the sticky toast this script
  // looks for can sit on top of the pager and swallow a positional click.
  const pager = async (name) => {
    const btn = page.getByRole('button', { name, exact: true });
    if (await btn.isEnabled().catch(() => false)) {
      await btn.dispatchEvent('click');
      await page.waitForTimeout(2500);
    }
  };

  for (let r = 0; r < rounds; r++) {
    await page.goto(`${addr}/ui/jobs?pageSize=10`);
    await page.getByText('web-').first().waitFor({ timeout: 60000 });
    // Let the blocking queries get in flight before superseding them.
    await page.waitForTimeout(3000);
    for (const step of ['Next', 'Next', 'Previous', 'First', 'Last', 'First']) {
      await pager(step);
    }
    // A filter change requeries and aborts the in-flight long-poll too.
    await page.goto(`${addr}/ui/jobs?pageSize=10&filter=Name%20contains%20%22web-1%22`);
    await page.waitForTimeout(4000);
  }

  await browser.close();
  console.log(JSON.stringify({ toasts, errors }));
})().catch((e) => {
  console.error(e.stack || String(e));
  process.exit(1);
});
