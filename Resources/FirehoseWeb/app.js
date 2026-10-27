(() => {
  'use strict';

  const $ = selector => document.querySelector(selector);
  const decoder = new TextDecoder();
  class EventHistory {
    constructor() { this.reset(); }
    reset() {
      this.events = [];
      this.start = 0;
      this.matched = 0;
      this.total = 0;
      this.live = true;
    }
    geometry(height) {
      const extent = Math.max(height, Math.min(8000000, this.matched * 31));
      return { extent, physical: extent - height, logical: Math.max(0, this.matched * 31 - height) };
    }
    offset(scrollTop, height) {
      const geometry = this.geometry(height);
      return geometry.physical ? scrollTop / geometry.physical * geometry.logical : 0;
    }
    scrollTop(offset, height) {
      const geometry = this.geometry(height);
      return geometry.logical ? offset / geometry.logical * geometry.physical : 0;
    }
    query(offset, height) {
      return new URLSearchParams({
        tail: String(this.live),
        start: String(Math.max(0, Math.floor(offset / 31) - 32)),
        count: String(Math.ceil(height / 31) + 64)
      });
    }
    accept(result) {
      const cleared = result.total < this.total;
      if (cleared) this.reset();
      this.matched = result.matched;
      this.total = result.total;
      this.events = result.events;
      this.start = result.start;
      return cleared;
    }
  }

  const state = {
    history: new EventHistory(),
    paused: false,
    filter: '',
    clauses: [],
    events: [],
    refreshing: false,
    selectedEventID: 0
  };

  const u16 = (view, offset) => view.getUint16(offset, true);
  const u32 = (view, offset) => view.getUint32(offset, true);
  const u64 = (view, offset) => Number(view.getBigUint64(offset, true));
  const f64 = (view, offset) => view.getFloat64(offset, true);
  const stringAt = (buffer, view, offset) => {
    const start = u32(view, offset);
    const length = u32(view, offset + 4);
    return start + length <= buffer.byteLength
      ? decoder.decode(new Uint8Array(buffer, start, length))
      : '';
  };

  function compactUI() {
    return innerWidth <= 760 || matchMedia('(hover: none) and (pointer: coarse)').matches;
  }

  function visibleCount(selector, rowHeight, minimum, maximum) {
    const height = $(selector)?.clientHeight || rowHeight * minimum;
    return Math.max(minimum, Math.min(maximum, Math.ceil(height / rowHeight) + 8));
  }

  function appendFilters(query) {
    const typed = state.filter.trim();
    const clauses = [...state.clauses];
    if ($('#container').value) clauses.push({ column: 'container', op: 'equals', value: $('#container').value });
    if (typed) clauses.push({ column: 'detail', op: 'contains', value: typed });
    query.set('filterCount', clauses.length);
    clauses.forEach((filter, index) => {
      query.set(`f${index}column`, filter.column);
      query.set(`f${index}op`, filter.op);
      query.set(`f${index}value`, filter.value);
    });
    return query;
  }

  function processQuery() {
    return appendFilters(new URLSearchParams({
      start: '0',
      count: String(visibleCount('.processes', 34, 20, 80))
    }));
  }

  function parseEvents(buffer) {
    const view = new DataView(buffer);
    if (u32(view, 0) !== 0x45435254 || u16(view, 4) !== 4) throw Error('Invalid event stream');
    const matched = u64(view, 8);
    const start = u64(view, 16);
    const count = u32(view, 24);
    const recordSize = u32(view, 28);
    const total = u64(view, 32);
    const flags = u32(view, 40);
    const events = [];
    for (let index = 0; index < count; index++) {
      const offset = 72 + index * recordSize;
      events.push({
        id: u64(view, offset),
        timestamp: f64(view, offset + 8),
        pid: u32(view, offset + 16),
        ppid: u32(view, offset + 20),
        time: stringAt(buffer, view, offset + 24),
        type: stringAt(buffer, view, offset + 32),
        process: stringAt(buffer, view, offset + 40),
        detail: stringAt(buffer, view, offset + 48),
        path: stringAt(buffer, view, offset + 56),
        container: stringAt(buffer, view, offset + 64),
        containerID: stringAt(buffer, view, offset + 72)
      });
    }
    return { matched, start, total, flags, events };
  }

  function updateCaptureStatus(result) {
    state.paused = Boolean(result.flags & 1);
    $('#capture').textContent = state.paused ? '▶' : 'Ⅱ';
    $('#capture').setAttribute('aria-label', state.paused ? 'Resume capture' : 'Pause capture');
    $('#summary').textContent = `${result.matched.toLocaleString()} matching of ${result.total.toLocaleString()} events (${result.total ? Math.round(result.matched / result.total * 100) : 100}%) — ${state.paused ? 'Tracing paused' : 'Tracing live'}`;
  }

  function renderEvents(result) {
    state.events = result.events;
    const picker = $('#container');
    for (const event of result.events) {
      if (![...picker.options].some(option => option.value === event.containerID)) picker.add(new Option(event.container, event.containerID));
    }
    updateCaptureStatus(result);

    const mobile = compactUI();
    $('#eventWindow').replaceChildren(...result.events.map((event, index) => {
      const row = document.createElement('div');
      row.className = 'event-row' + (event.id === state.selectedEventID ? ' selected' : '');
      row.dataset.eventId = String(event.id);
      row.classList.toggle('alternate', (result.start + index) % 2 === 1);
      row.innerHTML = '<span></span><span></span><span class="pid"></span><span></span><span></span>';
      const cells = row.children;
      cells[0].textContent = event.time;
      cells[1].textContent = event.type;
      cells[2].textContent = `${event.pid}  ${event.process} · ${event.container}`;
      cells[3].textContent = event.path;
      cells[4].textContent = event.detail;
      row.oncontextmenu = pointerEvent => showContext(pointerEvent, event);
      if (mobile) {
        row.tabIndex = 0;
        row.setAttribute('role', 'button');
        row.setAttribute('aria-label', `${event.type}, ${event.process}, ${event.path || event.detail}`);
        row.onclick = pointerEvent => showContext(pointerEvent, event, true);
        row.onkeydown = keyEvent => {
          if (keyEvent.key === 'Enter' || keyEvent.key === ' ') {
            keyEvent.preventDefault();
            showContext(keyEvent, event, true);
          }
        };
      }
      return row;
    }));
  }

  function parseProcesses(buffer) {
    const view = new DataView(buffer);
    if (u32(view, 0) !== 0x50435254) return null;
    const start = f64(view, 8);
    const end = f64(view, 16);
    const count = u32(view, 24);
    const recordSize = u32(view, 28);
    const dotCount = u32(view, 48);
    const dotSize = u32(view, 52);
    const bucketCount = u32(view, 56);
    const items = [];

    for (let index = 0; index < count; index++) {
      const offset = 64 + index * recordSize;
      items.push({
        pid: u32(view, offset),
        ppid: u32(view, offset + 4),
        first: f64(view, offset + 8),
        start: f64(view, offset + 16),
        end: f64(view, offset + 24),
        last: f64(view, offset + 32),
        count: u64(view, offset + 40),
        name: stringAt(buffer, view, offset + 52),
        level: u16(view, offset + 60),
        dots: []
      });
    }

    const dotOffset = 64 + count * recordSize;
    const byPID = new Map(items.map(item => [item.pid, item]));
    for (let index = 0; index < dotCount; index++) {
      const offset = dotOffset + index * dotSize;
      const item = byPID.get(u32(view, offset));
      if (item) item.dots.push(u32(view, offset + 4) / Math.max(1, bucketCount - 1));
    }
    return { start, end, items };
  }

  function renderProcesses(result) {
    if (!result) return;
    const duration = Math.max(.001, result.end - result.start);
    $('#processRows').replaceChildren(...result.items.map(process => {
      const row = document.createElement('div');
      row.className = 'process-row';
      const start = (process.start - result.start) / duration * 100;
      const end = (process.end - result.start) / duration * 100;
      row.innerHTML = '<span class="process-name"></span><span class="process-pid"></span><span class="process-count"></span><span class="timeline"></span>';
      row.children[0].textContent = process.name;
      row.children[1].textContent = process.pid;
      row.children[2].textContent = process.count;
      const timeline = row.lastChild;
      timeline.style.background = `linear-gradient(to right, transparent ${start}%, var(--accent) ${start}%, var(--accent) ${end}%, transparent ${end}%)`;
      for (const position of process.dots) {
        const dot = document.createElement('i');
        dot.className = 'dot';
        dot.style.left = position * 100 + '%';
        timeline.append(dot);
      }
      return row;
    }));
  }

  let eventController = null;
  let eventGeneration = 0;
  let logicalOffset = 0;
  let expectedScrollTop = null;
  let scrollFrame = 0;

  function updateEventNavigation() {
    const history = state.history;
    const first = Math.floor(logicalOffset / 31);
    const end = Math.min(history.matched, Math.ceil((logicalOffset + $('#eventRows').clientHeight) / 31));
    $('#older').disabled = $('#oldest').disabled = first === 0;
    $('#newer').disabled = end >= history.matched;
    $('#live').classList.toggle('active', history.live);
    $('#live').setAttribute('aria-pressed', String(history.live));
    $('#eventRange').textContent = history.matched
      ? `${(first + 1).toLocaleString()}–${end.toLocaleString()} of ${history.matched.toLocaleString()}`
      : 'No events';
  }

  function positionEvents() {
    const rows = $('#eventRows');
    const history = state.history;
    const geometry = history.geometry(rows.clientHeight);
    logicalOffset = history.live ? geometry.logical : Math.min(logicalOffset, geometry.logical);
    $('#eventExtent').style.height = geometry.extent + 'px';
    const top = history.scrollTop(logicalOffset, rows.clientHeight);
    expectedScrollTop = top;
    rows.scrollTop = top;
    $('#eventWindow').style.top = (top + history.start * 31 - logicalOffset) + 'px';
    updateEventNavigation();
  }

  async function loadEvents() {
    eventController?.abort();
    const controller = new AbortController();
    eventController = controller;
    const generation = eventGeneration;
    try {
      const query = state.history.query(logicalOffset, $('#eventRows').clientHeight);
      const response = await fetch('/api/events?' + appendFilters(query), { signal: controller.signal });
      if (!response.ok) throw Error(await response.text());
      const result = parseEvents(await response.arrayBuffer());
      if (controller.signal.aborted || generation !== eventGeneration) return;
      const cleared = state.history.accept(result);
      renderEvents(result);
      positionEvents();
      if (cleared) requestAnimationFrame(() => loadEvents());
    } catch (error) {
      if (!controller.signal.aborted && generation === eventGeneration) $('#summary').textContent = error.message;
    } finally {
      if (eventController === controller) eventController = null;
    }
  }

  function navigateEvents(mode) {
    state.history.live = mode === 'live';
    const height = $('#eventRows').clientHeight;
    if (mode === 'oldest') logicalOffset = 0;
    else if (mode === 'older') logicalOffset = Math.max(0, logicalOffset - height);
    else if (mode === 'newer') logicalOffset += height;
    $('#eventWindow').replaceChildren();
    positionEvents();
    loadEvents();
  }

  function resetEvents() {
    eventGeneration++;
    state.history.reset();
    state.events = [];
    logicalOffset = 0;
    $('#eventWindow').replaceChildren();
    positionEvents();
    loadEvents();
    refresh();
  }

  $('#oldest').onclick = () => navigateEvents('oldest');
  $('#older').onclick = () => navigateEvents('older');
  $('#newer').onclick = () => navigateEvents('newer');
  $('#live').onclick = () => navigateEvents('live');
  $('#eventRows').onscroll = () => {
    const rows = $('#eventRows');
    if (expectedScrollTop !== null && Math.abs(rows.scrollTop - expectedScrollTop) < 1) return;
    expectedScrollTop = null;
    logicalOffset = state.history.offset(rows.scrollTop, rows.clientHeight);
    state.history.live = rows.scrollHeight - rows.clientHeight - rows.scrollTop < 1;
    eventController?.abort();
    const first = Math.floor(logicalOffset / 31);
    const end = Math.ceil((logicalOffset + rows.clientHeight) / 31);
    const history = state.history;
    if (first < history.start || end > history.start + history.events.length) $('#eventWindow').replaceChildren();
    $('#eventWindow').style.top = (rows.scrollTop + history.start * 31 - logicalOffset) + 'px';
    updateEventNavigation();
    cancelAnimationFrame(scrollFrame);
    scrollFrame = requestAnimationFrame(() => loadEvents());
  };

  async function refresh() {
    if (!eventController) loadEvents();
    if (state.refreshing) return;
    state.refreshing = true;
    const generation = eventGeneration;
    try {
      const response = await fetch('/api/processes?' + processQuery());
      const buffer = await response.arrayBuffer();
      if (response.ok && generation === eventGeneration) renderProcesses(parseProcesses(buffer));
    } catch (error) {
      if (generation === eventGeneration) $('#summary').textContent = error.message;
    } finally {
      state.refreshing = false;
    }
  }

  function previewFor(event) {
    const preview = document.createElement('div');
    preview.className = 'context-preview';
    const title = document.createElement('strong');
    title.textContent = event.type;
    preview.append(title);
    for (const value of [
      `${event.time}   ${event.pid}  ${event.process}`,
      event.path,
      event.detail
    ]) {
      if (!value) continue;
      const line = document.createElement('span');
      line.textContent = value;
      preview.append(line);
    }
    return preview;
  }

  function showContext(pointerEvent, event, forceMobile = false) {
    pointerEvent?.preventDefault();
    state.selectedEventID = event.id;
    for (const row of document.querySelectorAll('.event-row.selected')) row.classList.remove('selected');
    document.querySelector(`.event-row[data-event-id="${event.id}"]`)?.classList.add('selected');

    const context = $('#context');
    const actions = [previewFor(event)];
    for (const [column, value] of [['process', event.process], ['type', event.type], ['path', event.path]]) {
      if (!value) continue;
      actions.push(actionButton(`Include ${column} “${value}”`, () => addFilter(column, 'contains', value)));
      actions.push(actionButton(`Exclude ${column} “${value}”`, () => addFilter(column, 'excludes', value)));
    }
    actions.push(actionButton('Copy row', () => {
      navigator.clipboard?.writeText([event.time, event.type, event.pid, event.process, event.path, event.detail].join('\t')).catch(() => {});
    }));
    actions.push(actionButton('Close', () => {}));
    context.replaceChildren(...actions);

    const mobile = forceMobile || compactUI();
    context.classList.toggle('mobile-sheet', mobile);
    context.hidden = false;
    $('#contextScrim').hidden = !mobile;
    if (mobile) {
      context.style.left = '';
      context.style.top = '';
    } else {
      context.style.left = Math.max(8, Math.min(pointerEvent.clientX, innerWidth - context.offsetWidth - 8)) + 'px';
      context.style.top = Math.max(8, Math.min(pointerEvent.clientY, innerHeight - context.offsetHeight - 8)) + 'px';
    }
  }

  function actionButton(label, action) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = label;
    button.onclick = () => {
      hideContext();
      action();
    };
    return button;
  }

  function hideContext() {
    $('#context').hidden = true;
    $('#contextScrim').hidden = true;
    state.selectedEventID = 0;
    for (const row of document.querySelectorAll('.event-row.selected')) row.classList.remove('selected');
  }

  function addFilter(column, op, value) {
    state.clauses.push({ column, op, value });
    $('#filter').placeholder = `${state.clauses.length} filter${state.clauses.length === 1 ? '' : 's'} active`;
    resetEvents();
  }

  $('#capture').onclick = async () => {
    await fetch('/api/capture?paused=' + (state.paused ? '0' : '1'));
    refresh();
  };

  $('#clear').onclick = async () => {
    if (!confirm('Clear all captured events?')) return;
    await fetch('/api/clear');
    state.clauses = [];
    hideContext();
    resetEvents();
  };

  $('#container').onchange = resetEvents;
  async function refreshContainers() {
    try {
      const response = await fetch('/api/containers');
      if (!response.ok) return;
      const buffer = await response.arrayBuffer(), view = new DataView(buffer);
      if (buffer.byteLength < 16 || u32(view, 0) !== 0x54585443 || u32(view, 4) !== 1 || u32(view, 8) !== buffer.byteLength) return;
      const count = u32(view, 12);
      if (count > (buffer.byteLength - 16) / 16) return;
      const picker = $('#container');
      for (let i = 0; i < count; i++) {
        const id = stringAt(buffer, view, 16 + i * 16), name = stringAt(buffer, view, 24 + i * 16);
        const option = [...picker.options].find(option => option.value === id);
        if (option) option.textContent = name;
        else picker.add(new Option(name, id));
      }
    } catch (error) { console.warn('Container discovery unavailable', error); }
  }
  refreshContainers();
  setInterval(refreshContainers, 5000);
  let filterTimer;
  $('#filter').oninput = event => {
    state.filter = event.target.value;
    clearTimeout(filterTimer);
    filterTimer = setTimeout(resetEvents, 180);
  };

  $('#contextScrim').onpointerdown = hideContext;
  document.addEventListener('pointerdown', event => {
    if (!event.target.closest('#context') && !event.target.closest('.event-row')) hideContext();
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') hideContext();
  });

  let resizeTimer;
  window.addEventListener('resize', () => {
    hideContext();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(refresh, 120);
  });

  refresh();
  setInterval(refresh, 700);
})();
