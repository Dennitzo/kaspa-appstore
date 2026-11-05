const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
  '../../rusty-kaspa-bridge-dashboard/static/js/dashboard.js'), 'utf8');

for (const counts of [
  { shares: 42800, stale: 0, invalid: 1 },
  { shares: 1234, stale: 7, invalid: 3 },
  { shares: 0, stale: 0, invalid: 0 },
]) {
  test(`polling /api/stats renders accepted/stale/invalid ${JSON.stringify(counts)}`, async () => {
    const table = { innerHTML: '' };
    const requests = [];
    const payloads = {
      '/api/status': { kaspad_connected: true },
      '/api/stats': {
        totalShares: counts.shares, activeWorkers: 1, bridgeUptime: 138023,
        workers: [{ worker: 'KS0Ultra', wallet: 'kaspa:test', hashrate: 0.5,
          blocks: 0, ...counts }], blocks: [],
      },
      '/api/node-status': { status: 'running', network: 'mainnet' },
    };
    const context = {
      document: {
        addEventListener() {},
        getElementById(id) { return id === 'workersTableBody' ? table : null; },
      },
      fetch: async (url, options) => {
        const endpoint = url.split('?')[0];
        requests.push({ endpoint, options });
        assert.ok(Object.hasOwn(payloads, endpoint), `unexpected endpoint ${url}`);
        return { ok: true, headers: { get: () => 'application/json' },
          json: async () => payloads[endpoint] };
      },
      setTimeout() { return 1; }, clearTimeout() {},
    };
    vm.createContext(context);
    vm.runInContext(source + '\nthis.Dashboard = StratumBridgeDashboard;', context);
    const dashboard = Object.create(context.Dashboard.prototype);
    dashboard.hideWallets = true;
    await dashboard.fetchData();

    assert.ok(requests.some(({ endpoint, options }) =>
      endpoint === '/api/stats' && options.cache === 'no-store'));
    const cells = [...table.innerHTML.matchAll(/<td[^>]*>(.*?)<\/td>/g)].map(match => match[1]);
    assert.equal(cells.length, 7, table.innerHTML);
    for (const [index, field] of [[3, 'shares'], [4, 'stale'], [5, 'invalid']]) {
      assert.equal(cells[index].replace(/\D/g, ''), String(counts[field]), field);
    }
  });
}
