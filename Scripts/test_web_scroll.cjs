const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../Resources/FirehoseWeb/app.js'), 'utf8');
let top = 259600, writes = 0;
const rows = {clientHeight:400,scrollHeight:260000,get scrollTop(){return top;},set scrollTop(value){writes++;top=value;}};
const extent = {style:{}}, window = {style:{}};
const context = vm.createContext({URLSearchParams, $: selector => ({'#eventRows':rows,'#eventExtent':extent,'#eventWindow':window})[selector]});
vm.runInContext(source.slice(source.indexOf('  class EventHistory'), source.indexOf('\n  const state')) + `
const state = {history: new EventHistory()};
state.history.matched = 10000;
let logicalOffset = 259600, expectedScrollTop = null;
function updateEventNavigation() {}
` + source.slice(source.indexOf('  function positionEvents()'),source.indexOf('  async function loadEvents()')) + source.slice(source.indexOf('  function readScrollPosition()'),source.indexOf("  $('#eventRows').onscroll")),context);
vm.runInContext('positionEvents(); positionEvents();',context);
assert.equal(writes,0,'polls must not write scrollTop when already positioned');
top=259650;
assert.equal(vm.runInContext('readScrollPosition()',context),false,'bottom rubber band is not navigation');
top=259400;
assert.equal(vm.runInContext('readScrollPosition()',context),true);
assert.equal(vm.runInContext('state.history.live',context),false);
vm.runInContext('positionEvents()',context);
assert.equal(writes,0,'response must not interrupt native scrolling');
assert.equal(top,259400);
console.log('PASS unchanged position never written, overscroll ignored, native scroll preserved');
