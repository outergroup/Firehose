const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../Resources/FirehoseWeb/app.js'), 'utf8');
const context = vm.createContext({ URLSearchParams });
vm.runInContext(source.slice(source.indexOf('  class EventHistory'), source.indexOf('\n  const state')) + '\nthis.EventHistory = EventHistory;', context);
const history = new context.EventHistory();
for (const matched of [0, 10, 10000, 100000000]) {
  history.matched = matched;
  const height = 400;
  const geometry = history.geometry(height);
  assert(geometry.extent <= 8000000);
  for (const fraction of [0, .1, .5, .999, 1]) {
    const offset = geometry.logical * fraction;
    assert(Math.abs(history.offset(history.scrollTop(offset, height), height) - offset) < .000001);
    history.live = false;
    const query = history.query(offset, height);
    assert.equal(query.get('tail'), 'false');
    assert.equal(Number(query.get('start')), Math.max(0, Math.floor(offset / 31) - 32));
    assert(Number(query.get('count')) < 100);
  }
}
history.live = false;
history.accept({matched:10000,total:10000,start:4968,events:[{id:4969}]});
const oldOffset = 5000 * 31;
const oldExtent = history.geometry(400).extent;
history.accept({matched:10000,total:10000,start:7000,events:[{id:7001}]});
assert.equal(history.geometry(400).extent, oldExtent);
history.accept({matched:11000,total:11000,start:4968,events:[{id:4969}]});
assert.equal(history.live, false);
assert.equal(history.offset(history.scrollTop(oldOffset,400),400), oldOffset);
assert(history.accept({matched:0,total:0,start:0,events:[]}));
assert.equal(history.live, true);
assert.equal(history.query(0,400).get('tail'), 'true');
console.log('PASS full-history extent, arbitrary seek, bounded windows, large captures, stable position on growth, clear reset');
