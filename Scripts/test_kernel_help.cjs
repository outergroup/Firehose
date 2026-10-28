const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../Resources/FirehoseWeb/app.js'), 'utf8');
const message = Buffer.from('Linux tracepoints are unavailable. Open the setup guide.');
const bytes = Buffer.alloc(48 + message.length);
bytes.write('TRSC'); bytes.writeUInt16LE(1, 4); bytes.writeUInt16LE(48, 6);
bytes.writeUInt32LE(8, 8); bytes.writeUInt32LE(48, 40); bytes.writeUInt32LE(message.length, 44); message.copy(bytes, 48);
const nodes = Object.fromEntries(['capture', 'captureHelp', 'captureHelpMessage', 'kernelGuide', 'summary'].map(id => ['#' + id, { hidden: true, classList: { toggle() {} }, setAttribute() {} }]));
const state = {};
let valid = true;
const context = vm.createContext({ state, DataView, console: { warn() {} },
  location: { pathname: '/targets/apple.container:test/' },
  $: id => nodes[id],
  u32: (v, o) => v.getUint32(o, true), u16: (v, o) => v.getUint16(o, true),
  stringAt: (b, v, o) => new TextDecoder().decode(new Uint8Array(b, v.getUint32(o, true), v.getUint32(o + 4, true))),
  appFetch: async () => ({ ok: valid, text: async () => 'unavailable', arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length) })
});
vm.runInContext(source.slice(source.indexOf('  function updateCaptureStatus'), source.indexOf('  function renderEvents')), context);
(async () => {
  await context.refreshCaptureHelp();
  assert.equal(nodes['#captureHelp'].hidden, false);
  assert.equal(nodes['#kernelGuide'].hidden, false);
  assert.equal(nodes['#captureHelpMessage'].textContent, message.toString());
  context.updateCaptureStatus({ flags: 8, matched: 0, total: 0 });
  assert.equal(nodes['#capture'].disabled, true);
  context.updateCaptureStatus({ flags: 0, matched: 1, total: 1 });
  assert.equal(nodes['#captureHelp'].hidden, true);
  assert.equal(nodes['#capture'].disabled, false);
  valid = false;
  await context.refreshCaptureHelp();
  assert.equal(state.captureHelpLoaded, false);
  console.log('PASS actionable kernel help, unavailable capture control, recovery, and retry');
})().catch(error => { console.error(error); process.exitCode = 1; });
