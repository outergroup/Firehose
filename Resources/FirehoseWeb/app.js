(() => {
  'use strict';

  const appFetch = (path, options) => window.fetch((location.pathname.match(/^\/targets\/[^/]+/)?.[0] || '') + path, options);

  const $ = selector => document.querySelector(selector);
  const decoder = new TextDecoder();
  class EventHistory {
    static rowHeight = 26;
    constructor() { this.reset(); }
    reset() {
      this.events = [];
      this.start = 0;
      this.matched = 0;
      this.total = 0;
      this.live = true;
    }
    geometry(height) {
      const extent = Math.max(height, Math.min(8000000, this.matched * EventHistory.rowHeight));
      return { extent, physical: extent - height, logical: Math.max(0, this.matched * EventHistory.rowHeight - height) };
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
        start: String(Math.max(0, Math.floor(offset / EventHistory.rowHeight) - 32)),
        count: String(Math.ceil(height / EventHistory.rowHeight) + 64)
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

  function processWindow(scrollTop, height, total) {
    const logical = Math.max(0, total * 22 - height);
    const extent = Math.max(height, Math.min(8000000, total * 22));
    const physical = extent - height;
    const offset = physical ? Math.max(0, Math.min(physical, scrollTop)) / physical * logical : 0;
    return { extent, logical, physical, offset, start: Math.max(0, Math.floor(offset / 22) - 24), count: Math.ceil(height / 22) + 48 };
  }

  let processTotal = 0;
  let processStart = 0;
  let processCount = 0;
  let processFrame = 0;

  function processQuery() {
    const rows = $('.processes');
    const window = processWindow(rows.scrollTop, rows.clientHeight, processTotal);
    return appendFilters(new URLSearchParams({ start: String(window.start), count: String(window.count) }));
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
        tid: u32(view, offset + 16),
        pid: u32(view, offset + 88),
        ppid: u32(view, offset + 20),
        time: stringAt(buffer, view, offset + 24),
        type: stringAt(buffer, view, offset + 32),
        thread: stringAt(buffer, view, offset + 40),
        process: stringAt(buffer, view, offset + 96),
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
    const unsupported = Boolean(result.flags & 8);
    $('#capture').disabled = unsupported;
    if (unsupported && !state.captureHelpLoaded) refreshCaptureHelp();
    if (!unsupported) { $('#captureHelp').hidden = true; state.captureHelpLoaded = false; }
    $('#capture').classList.toggle('paused', state.paused);
    $('#capture').setAttribute('aria-label', state.paused ? 'Resume capture' : 'Pause capture');
    $('#summary').textContent = `${result.matched.toLocaleString()} matching of ${result.total.toLocaleString()} events (${result.total ? Math.round(result.matched / result.total * 100) : 100}%) — ${state.paused ? 'Tracing paused' : 'Tracing live'}`;
  }

  async function refreshCaptureHelp() {
    state.captureHelpLoaded = true;
    try {
      const response = await appFetch('/api/capture');
      if (!response.ok) throw Error(await response.text());
      const buffer = await response.arrayBuffer(), view = new DataView(buffer);
      if (buffer.byteLength < 48 || u32(view, 0) !== 0x43535254 || u16(view, 4) !== 1) throw Error('Invalid capture status');
      if (!(u32(view, 8) & 8)) return;
      $('#captureHelpMessage').textContent = stringAt(buffer, view, 40) || 'Event capture is unavailable.';
      $('#kernelGuide').hidden = !location.pathname.startsWith('/targets/apple.container:');
      $('#captureHelp').hidden = false;
    } catch (error) {
      state.captureHelpLoaded = false;
      console.warn('Capture setup information unavailable', error);
    }
  }

  function renderEvents(result) {
    const unchanged = state.events.length === result.events.length && state.events.every((event, index) => event.id === result.events[index].id && event.pid === result.events[index].pid && event.process === result.events[index].process);
    state.events = result.events;
    if (unchanged && state.renderedCompact === compactUI() && $('#eventWindow').children.length === result.events.length) {
      updateCaptureStatus(result);
      for (const row of $('#eventWindow').children) row.classList.toggle('selected', Number(row.dataset.eventId) === state.selectedEventID);
      return;
    }
    const picker = $('#container');
    for (const event of result.events) {
      if (![...picker.options].some(option => option.value === event.containerID)) picker.add(new Option(event.container, event.containerID));
    }
    updateCaptureStatus(result);

    const mobile = compactUI();
    state.renderedCompact = mobile;
    $('#eventWindow').replaceChildren(...result.events.map(event => {
      const row = document.createElement('div');
      row.className = 'event-row' + (event.id === state.selectedEventID ? ' selected' : '');
      row.dataset.eventId = String(event.id);
      row.innerHTML = '<span></span><span></span><span class="event-pid"></span><span></span><span class="event-tid"></span><span class="event-thread"></span><span class="event-path"></span><span class="event-detail"></span>';
      const cells = row.children;
      cells[0].textContent = event.time;
      cells[1].textContent = event.type;
      cells[2].textContent = event.pid || '—';
      cells[2].title = event.pid ? `Process ID: ${event.pid}` : 'Process ID unavailable';
      cells[3].textContent = event.process || (event.tid ? 'Unknown' : 'Firehose');
      if (event.containerID !== 'host' && !$('#container').value) {
        const container = document.createElement('span');
        container.className = 'event-container';
        container.textContent = ` · ${event.container}`;
        cells[3].append(container);
      }
      cells[4].textContent = event.tid || '—';
      cells[5].textContent = event.thread;
      cells[6].textContent = event.path;
      cells[7].textContent = event.detail;
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
      if (item) item.dots.push({
        position: u32(view, offset + 4) / Math.max(1, bucketCount - 1),
        count: u32(view, offset + 8),
        eventIndex: u64(view, offset + 20)
      });
    }
    return { start, end, items, total: u64(view, 40) };
  }

  function renderProcesses(result, requestedStart) {
    if (!result) return;
    const viewport = $('.processes');
    const oldWindow = processWindow(viewport.scrollTop, viewport.clientHeight, processTotal);
    processTotal = result.total;
    processStart = Math.min(requestedStart, processTotal);
    processCount = result.items.length;
    const window = processWindow(viewport.scrollTop, viewport.clientHeight, processTotal);
    const offset = Math.min(oldWindow.offset, window.logical);
    const top = window.logical ? offset / window.logical * window.physical : 0;
    $('#processExtent').style.height = window.extent + 'px';
    if (Math.abs(viewport.scrollTop - top) > 1) viewport.scrollTop = top;
    $('#processRows').style.top = (top + processStart * 22 - offset) + 'px';
    const duration = Math.max(.001, result.end - result.start);
    $('#processRows').replaceChildren(...result.items.map(process => {
      const row = document.createElement('div');
      row.className = 'process-row';
      row.dataset.pid = String(process.pid);
      const start = (process.start - result.start) / duration * 100;
      const end = (process.end - result.start) / duration * 100;
      row.innerHTML = '<span class="process-name"></span><span class="process-pid"></span><span class="process-count"></span><span class="timeline"></span>';
      row.children[0].textContent = process.name;
      row.children[1].textContent = process.pid;
      row.children[1].title = `Process ID: ${process.pid}`;
      row.children[2].textContent = process.count;
      const timeline = row.lastChild;
      timeline.style.background = `linear-gradient(to right, transparent ${start}%, var(--accent) ${start}%, var(--accent) ${end}%, transparent ${end}%)`;
      for (const activity of process.dots) {
        const dot = document.createElement('button');
        dot.type = 'button';
        dot.className = 'dot';
        dot.style.left = activity.position * 100 + '%';
        dot.title = `${process.name} (PID ${process.pid}): ${activity.count} events — show in event log`;
        dot.setAttribute('aria-label', dot.title);
        dot.onclick = () => revealEvent(activity.eventIndex);
        timeline.append(dot);
      }
      return row;
    }));
  }

  let pendingEventIndex = null;
  let eventController = null;
  let eventGeneration = 0;
  let logicalOffset = 0;
  let expectedScrollTop = null;
  let scrollFrame = 0;

  function updateEventNavigation() {
    const history = state.history;
    const first = Math.floor(logicalOffset / EventHistory.rowHeight);
    const end = Math.min(history.matched, Math.ceil((logicalOffset + $('#eventRows').clientHeight) / EventHistory.rowHeight));
    $('#eventScrollbar').setAttribute('aria-valuetext', history.matched
      ? `${(first + 1).toLocaleString()}–${end.toLocaleString()} of ${history.matched.toLocaleString()}`
      : 'No events');
    updateScrollbar();
  }

  function scrollbarMetrics() {
    const height = $('#eventScrollbar').clientHeight;
    const viewport = $('#eventRows').clientHeight;
    const maximum = state.history.geometry(viewport).logical;
    const thumb = Math.min(height, Math.max(44, height * viewport / Math.max(viewport, state.history.matched * EventHistory.rowHeight)));
    return { height, thumb, travel: height - thumb, maximum };
  }

  function updateScrollbar() {
    const bar = $('#eventScrollbar');
    const metrics = scrollbarMetrics();
    $('#eventThumb').style.height = metrics.thumb + 'px';
    $('#eventThumb').style.top = (metrics.maximum ? logicalOffset / metrics.maximum * metrics.travel : 0) + 'px';
    bar.setAttribute('aria-valuemax', String(Math.round(metrics.maximum)));
    bar.setAttribute('aria-valuenow', String(Math.round(logicalOffset)));
    bar.setAttribute('aria-disabled', String(!metrics.maximum));
  }

  let scrollbarDrag = null;
  let scrollbarTimer = null;

  function seekScrollbar(offset) {
    pendingEventIndex = null;
    logicalOffset = Math.max(0, Math.min(scrollbarMetrics().maximum, offset));
    state.history.live = logicalOffset >= scrollbarMetrics().maximum;
    positionEvents();
    if (scrollbarTimer === null) scrollbarTimer = setTimeout(() => {
      scrollbarTimer = null;
      loadEvents();
    }, 40);
  }

  $('#eventScrollbar').onpointerdown = event => {
    if (event.button !== 0 || scrollbarDrag) return;
    const metrics = scrollbarMetrics();
    if (!metrics.maximum || !metrics.travel) return;
    event.preventDefault();
    const bar = event.currentTarget;
    const y = event.clientY - bar.getBoundingClientRect().top;
    const thumbTop = logicalOffset / metrics.maximum * metrics.travel;
    scrollbarDrag = { pointer: event.pointerId, grab: y >= thumbTop && y <= thumbTop + metrics.thumb ? y - thumbTop : metrics.thumb / 2 };
    bar.setPointerCapture(event.pointerId);
    bar.classList.add('dragging');
    seekScrollbar((y - scrollbarDrag.grab) / metrics.travel * metrics.maximum);
  };
  $('#eventScrollbar').onpointermove = event => {
    if (scrollbarDrag?.pointer !== event.pointerId) return;
    const metrics = scrollbarMetrics();
    const y = event.clientY - event.currentTarget.getBoundingClientRect().top;
    if (metrics.travel) seekScrollbar((y - scrollbarDrag.grab) / metrics.travel * metrics.maximum);
  };
  function finishScrollbarDrag(event) {
    if (scrollbarDrag?.pointer !== event.pointerId) return;
    scrollbarDrag = null;
    event.currentTarget.classList.remove('dragging');
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    clearTimeout(scrollbarTimer);
    scrollbarTimer = null;
    loadEvents();
  }
  $('#eventScrollbar').onpointerup = finishScrollbarDrag;
  $('#eventScrollbar').onpointercancel = finishScrollbarDrag;
  $('#eventScrollbar').onlostpointercapture = finishScrollbarDrag;
  $('#eventScrollbar').onkeydown = event => {
    const page = $('#eventRows').clientHeight;
    const targets = { ArrowUp: logicalOffset - EventHistory.rowHeight, ArrowDown: logicalOffset + EventHistory.rowHeight,
      PageUp: logicalOffset - page, PageDown: logicalOffset + page, Home: 0, End: scrollbarMetrics().maximum };
    if (!(event.key in targets)) return;
    event.preventDefault();
    seekScrollbar(targets[event.key]);
  };

  function positionEvents() {
    const rows = $('#eventRows');
    const history = state.history;
    const geometry = history.geometry(rows.clientHeight);
    logicalOffset = history.live ? geometry.logical : Math.min(logicalOffset, geometry.logical);
    $('#eventExtent').style.height = geometry.extent + 'px';
    const top = history.scrollTop(logicalOffset, rows.clientHeight);
    if (Math.abs(rows.scrollTop - top) > 1) {
      expectedScrollTop = top;
      rows.scrollTop = top;
    }
    $('#eventWindow').style.top = (top + history.start * EventHistory.rowHeight - logicalOffset) + 'px';
    updateEventNavigation();
  }

  async function loadEvents() {
    eventController?.abort();
    const controller = new AbortController();
    eventController = controller;
    const generation = eventGeneration;
    try {
      const query = state.history.query(logicalOffset, $('#eventRows').clientHeight);
      const response = await appFetch('/api/events?' + appendFilters(query), { signal: controller.signal });
      if (!response.ok) throw Error(await response.text());
      const result = parseEvents(await response.arrayBuffer());
      if (controller.signal.aborted || generation !== eventGeneration) return;
      if (pendingEventIndex === null) readScrollPosition();
      const cleared = state.history.accept(result);
      if (cleared) pendingEventIndex = null;
      if (pendingEventIndex !== null) {
        const event = result.events[pendingEventIndex - result.start];
        if (event) {
          state.selectedEventID = event.id;
          pendingEventIndex = null;
        }
      }
      renderEvents(result);
      positionEvents();
      const first = Math.floor(logicalOffset / EventHistory.rowHeight);
      const end = Math.min(result.matched, Math.ceil((logicalOffset + $('#eventRows').clientHeight) / EventHistory.rowHeight));
      if (cleared || first < result.start || end > result.start + result.events.length) requestAnimationFrame(() => loadEvents());
    } catch (error) {
      if (!controller.signal.aborted && generation === eventGeneration) $('#summary').textContent = error.message;
    } finally {
      if (eventController === controller) eventController = null;
    }
  }

  function revealEvent(index) {
    hideContext();
    pendingEventIndex = index;
    state.history.live = false;
    logicalOffset = Math.max(0, index * EventHistory.rowHeight - ($('#eventRows').clientHeight - EventHistory.rowHeight) / 2);
    $('#eventWindow').replaceChildren();
    updateEventNavigation();
    loadEvents();
  }

  function resetEvents() {
    eventGeneration++;
    pendingEventIndex = null;
    hideContext();
    $('#processRows').replaceChildren();
    processTotal = processStart = processCount = 0;
    $('#processExtent').style.height = '0px';
    $('.processes').scrollTop = 0;
    state.history.reset();
    state.events = [];
    logicalOffset = 0;
    $('#eventWindow').replaceChildren();
    positionEvents();
    loadEvents();
    refresh();
  }

  function readScrollPosition() {
    const rows = $('#eventRows');
    const top = Math.max(0, Math.min(rows.scrollTop, rows.scrollHeight - rows.clientHeight));
    if (expectedScrollTop !== null && Math.abs(top - expectedScrollTop) < 1) return false;
    expectedScrollTop = null;
    const offset = state.history.offset(top, rows.clientHeight);
    if (Math.abs(offset - logicalOffset) < 1) return false;
    logicalOffset = offset;
    state.history.live = rows.scrollHeight - rows.clientHeight - top < 1;
    return true;
  }

  $('#eventRows').onscroll = () => {
    if (!readScrollPosition()) return;
    pendingEventIndex = null;
    const rows = $('#eventRows');
    const history = state.history;
    const first = Math.floor(logicalOffset / EventHistory.rowHeight);
    const end = Math.ceil((logicalOffset + rows.clientHeight) / EventHistory.rowHeight);
    const top = history.scrollTop(logicalOffset, rows.clientHeight);
    $('#eventWindow').style.top = (top + history.start * EventHistory.rowHeight - logicalOffset) + 'px';
    updateEventNavigation();
    const nearStart = first < history.start + 12 && history.start > 0;
    const nearEnd = end > history.start + history.events.length - 12 && history.start + history.events.length < history.matched;
    if (nearStart || nearEnd) {
      cancelAnimationFrame(scrollFrame);
      scrollFrame = requestAnimationFrame(() => loadEvents());
    }
  };

  $('.processes').onscroll = () => {
    const viewport = $('.processes');
    const window = processWindow(viewport.scrollTop, viewport.clientHeight, processTotal);
    const top = Math.max(0, Math.min(window.physical, viewport.scrollTop));
    $('#processRows').style.top = (top + processStart * 22 - window.offset) + 'px';
    const first = Math.floor(window.offset / 22);
    const end = Math.ceil((window.offset + viewport.clientHeight) / 22);
    if ((first < processStart + 8 && processStart > 0) ||
        (end > processStart + processCount - 8 && processStart + processCount < processTotal)) {
      cancelAnimationFrame(processFrame);
      processFrame = requestAnimationFrame(refresh);
    }
  };

  async function refresh() {
    if (!eventController) loadEvents();
    if (state.refreshing) return;
    state.refreshing = true;
    const generation = eventGeneration;
    try {
      const query = processQuery();
      const response = await appFetch('/api/processes?' + query);
      const buffer = await response.arrayBuffer();
      if (response.ok && generation === eventGeneration) {
        renderProcesses(parseProcesses(buffer), Number(query.get('start')));
        const viewport = $('.processes');
        const window = processWindow(viewport.scrollTop, viewport.clientHeight, processTotal);
        const first = Math.floor(window.offset / 22);
        const end = Math.min(processTotal, Math.ceil((window.offset + viewport.clientHeight) / 22));
        if (first < processStart || end > processStart + processCount) {
          cancelAnimationFrame(processFrame);
          processFrame = requestAnimationFrame(refresh);
        }
      }
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
      `${event.time}   PID ${event.pid || "unavailable"}  ${event.process || "Unknown process"}`,
      `TID ${event.tid || "—"}  ${event.thread}`,
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
    for (const [column, value] of [['owner', event.process], ['process', event.thread], ['type', event.type], ['path', event.path]]) {
      if (!value) continue;
      const label = column === 'owner' ? 'process' : column === 'process' ? 'thread' : column;
      actions.push(actionButton(`Include ${label} “${value}”`, () => addFilter(column, 'contains', value)));
      actions.push(actionButton(`Exclude ${label} “${value}”`, () => addFilter(column, 'excludes', value)));
    }
    actions.push(actionButton('Copy row', () => {
      navigator.clipboard?.writeText([event.time, event.type, event.pid, event.process, event.tid, event.thread, event.path, event.detail].join('\t')).catch(() => {});
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
    await appFetch('/api/capture?paused=' + (state.paused ? '0' : '1'));
    refresh();
  };

  $('#clear').onclick = async () => {
    if (!confirm('Clear all captured events?')) return;
    await appFetch('/api/clear');
    state.clauses = [];
    hideContext();
    resetEvents();
  };

  $('#container').onchange = resetEvents;
  async function refreshContainers() {
    try {
      const response = await appFetch('/api/containers');
      if (!response.ok) return;
      const buffer = await response.arrayBuffer(), view = new DataView(buffer);
      if (buffer.byteLength < 16 || u32(view, 0) !== 0x54585443 || u32(view, 4) !== 1 || u32(view, 8) !== buffer.byteLength) return;
      const count = u32(view, 12);
      if (count > (buffer.byteLength - 16) / 16) return;
      const picker = $('#container');
      const hasHost = Array.from({length: count}, (_, i) => stringAt(buffer, view, 16 + i * 16)).includes('host');
      picker.options[0].textContent = hasHost ? 'All containers and host' : 'All containers';
      if (!hasHost) [...picker.options].find(option => option.value === 'host')?.remove();
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
