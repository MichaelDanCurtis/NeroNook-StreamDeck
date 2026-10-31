(() => {
  'use strict';
  const el = id => document.getElementById(id);
  const keys = ['provider', 'name', 'arguments', 'field', 'label'];
  const state = { ws: null, context: null, action: null, catalog: [], fragments: [], generation: null,
    baseline: null, latest: null, dirty: false, reloadRequired: false, reloadingFrom: null,
    pending: null, reloadTimer: null, online: false, externalPending: false, recoveryBlocked: false };
  const status = text => { el('status').textContent = text; };
  const menu = () => state.action?.endsWith('.menu');
  const stop = () => state.action?.endsWith('.stop');
  const liveStatus = () => state.action?.endsWith('.status');
  const connected = () => state.ws?.readyState === 1;
  const address = item => item.address.plugin + '/' + item.address.name;
  function send(payload) {
    if (!connected() || !state.context) return false;
    state.ws.send(JSON.stringify({ event: 'sendToPlugin', context: state.context, action: state.action, payload }));
    return true;
  }
  function knownSettings(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    const entries = Object.entries(value).filter(([key]) => keys.includes(key));
    if (entries.some(([, item]) => typeof item !== 'string' || new TextEncoder().encode(item).length > 8192)) return null;
    return Object.fromEntries(entries);
  }
  function controls() {
    const busy = !!state.pending || state.externalPending;
    el('save').disabled = menu() || !connected() || !state.online || !state.baseline || state.reloadRequired || state.reloadingFrom !== null || busy || state.recoveryBlocked;
    el('test').disabled = !connected() || !state.online || state.dirty || state.reloadRequired || state.reloadingFrom !== null || busy || (state.recoveryBlocked && !stop());
    for (const id of ['target', 'args', 'field', 'label']) el(id).disabled = menu() || !!state.pending || state.reloadingFrom !== null;
    el('reload').disabled = !connected() || !!state.pending || state.reloadingFrom !== null;
    el('refresh').disabled = !connected();
  }
  function describe() {
    const item = state.catalog.find(x => address(x) === el('target').value);
    el('schema').textContent = menu() ? 'Action Menu chooses from the current permitted actions. It has no saved target to reconnect.'
      : stop() ? 'Stop uses this deck’s exact original run and waits for confirmation. Completed effects are not undone.'
      : item?.action ? 'Inputs: ' + (item.action.input.fields.map(x => x.name + ' (' + x.kind + (x.required ? ', required' : '') + ')').join(', ') || 'none')
        + (item.action.effect !== 'readOnly' ? ' · Each run requires review.' : '')
      : item?.channel ? 'Fields: ' + item.channel.schema.fields.map(x => x.name).join(', ') : 'No permitted target selected.';
  }
  function renderTargets() {
    const settings = state.baseline?.settings || {};
    const selected = state.dirty ? el('target').value : (settings.provider || 'cafe.nero.plugin.streamdeck') + '/' + (settings.name || (liveStatus() ? 'connection' : 'check_connection'));
    const select = el('target'); select.replaceChildren();
    for (const item of state.catalog.filter(x => stop() ? x.action?.cancellable === true : liveStatus() ? x.channel?.kind === 'state' : x.action)) {
      const option = document.createElement('option'); option.value = address(item);
      option.textContent = (item.action?.title || item.channel?.title) + ' · ' + item.address.plugin; select.append(option);
    }
    if (selected && !state.catalog.some(x => address(x) === selected)) {
      const option = document.createElement('option'); option.value = selected; option.textContent = 'Unavailable saved target · ' + selected; select.append(option);
    }
    select.value = selected;
    if (!state.dirty) {
      el('args').value = settings.arguments || '{}'; el('field').value = settings.field || 'message'; el('label').value = settings.label || '';
    }
    el('argumentsRow').hidden = liveStatus() || stop() || menu(); el('fieldRow').hidden = !liveStatus();
    el('test').textContent = menu() ? 'Open action menu' : stop() ? 'Stop paired run' : 'Test saved mapping';
    describe(); controls();
  }
  function adopt(snapshot) {
    if (state.reloadTimer !== null) clearTimeout(state.reloadTimer);
    state.reloadTimer = null;
    state.baseline = snapshot; state.dirty = false; state.reloadRequired = false; state.reloadingFrom = null;
    renderTargets();
  }
  function finishPending() {
    if (state.pending) clearTimeout(state.pending.timer);
    state.pending = null;
  }
  function snapshot(payload) {
    const settings = knownSettings(payload.settings);
    if (typeof payload.revision !== 'string' || !payload.revision || payload.revision.length > 200 || !settings) {
      status('Update the NeroNook companion before saving mappings.'); controls(); return;
    }
    const next = { revision: payload.revision, settings };
    state.latest = next; state.externalPending = payload.savePending === true || payload.saveUnresolved === true;
    state.recoveryBlocked = payload.recoveryBlocked === true;
    if (state.pending) {
      if (state.pending.confirmedRevision === next.revision) {
        finishPending(); adopt(next); status('Mapping readback confirmed in Elgato.');
      }
    } else if (state.reloadingFrom !== null) {
      if (next.revision !== state.reloadingFrom && !state.externalPending) {
        adopt(next); status('Current key settings loaded.');
      }
    } else if (!state.baseline || (!state.dirty && !state.reloadRequired)) {
      adopt(next); status(state.online ? 'Connected to NeroNook' : 'Enable the Stream Deck module in NeroNook');
    } else if (next.revision !== state.baseline.revision) {
      state.reloadRequired = true; status('The key changed. Your draft is kept; reload key settings before saving.');
    }
    if (payload.saveUnresolved === true && !state.pending) {
      state.reloadRequired = true;
      status('An earlier mapping save is unconfirmed. Reload key settings before running or saving.');
    }
    if (state.recoveryBlocked && !state.pending && payload.saveUnresolved !== true) {
      status('Waiting for a saved outcome. If this persists, open Recovery & pending outcomes in NeroNook.');
    }
    renderTargets();
  }
  function mappingResult(result) {
    const pending = state.pending;
    if (!pending || result.request !== pending.id) return;
    if (result.outcome === 'confirmed' && typeof result.revision === 'string') {
      pending.confirmedRevision = result.revision;
      if (state.latest?.revision === result.revision) {
        finishPending(); adopt(state.latest); status('Mapping readback confirmed in Elgato.');
      } else status('Readback received; waiting for current key settings…');
    } else if (['conflict', 'unconfirmed', 'rejected'].includes(result.outcome)) {
      finishPending();
      state.reloadRequired = result.outcome !== 'rejected';
      status(typeof result.message === 'string' ? result.message.slice(0, 300) : 'Mapping was not confirmed. Reload key settings.');
    }
    controls();
  }
  function receive(event) {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message.event !== 'sendToPropertyInspector' || (message.context && message.context !== state.context) || (message.action && message.action !== state.action)) return;
    const payload = message.payload || {};
    if (payload.mappingResult) { mappingResult(payload.mappingResult); return; }
    if (payload.recoveryReadiness === true && typeof payload.recoveryBlocked === 'boolean') {
      const wasBlocked = state.recoveryBlocked;
      state.recoveryBlocked = payload.recoveryBlocked;
      if (!state.pending && !state.reloadRequired && state.reloadingFrom === null) {
        if (state.recoveryBlocked) status('Waiting for a saved outcome. If this persists, open Recovery & pending outcomes in NeroNook.');
        else if (wasBlocked) status('Saved outcome confirmed. Your current mapping and draft are unchanged.');
      }
      controls(); return;
    }
    if (typeof payload.catalogGeneration !== 'string') return;
    if (state.generation !== payload.catalogGeneration) { state.generation = payload.catalogGeneration; state.fragments = []; }
    if (Array.isArray(payload.catalog)) state.fragments.push(...payload.catalog);
    if (state.fragments.length > 1280) { state.fragments = []; state.reloadRequired = true; status('Available-action list is too large.'); controls(); return; }
    if (payload.complete) {
      state.catalog = state.fragments.filter(x => x?.address && typeof x.address.plugin === 'string' && typeof x.address.name === 'string' && (x.action?.input?.fields || x.channel?.schema?.fields));
      state.fragments = []; state.online = payload.online === true; snapshot(payload);
    }
  }
  function markDirty() { state.dirty = true; describe(); controls(); }
  window.connectElgatoStreamDeckSocket = (port, uuid, registerEvent, info, actionInfo) => {
    let data;
    try { data = JSON.parse(actionInfo); } catch { status('Invalid key information.'); return; }
    if (!/^\d+$/.test(String(port)) || +port < 1 || +port > 65535 || registerEvent !== 'registerPropertyInspector' || typeof uuid !== 'string'
      || typeof data.context !== 'string' || !data.context || data.context.length > 200 || typeof data.action !== 'string') {
      status('The key context is unavailable.'); controls(); return;
    }
    state.context = data.context; state.action = data.action;
    state.ws = new WebSocket('ws://127.0.0.1:' + port);
    state.ws.onopen = () => { state.ws.send(JSON.stringify({ event: registerEvent, uuid })); send({ refresh: true }); controls(); };
    state.ws.onmessage = receive;
    state.ws.onclose = () => {
      const unconfirmed = !!state.pending; finishPending(); state.online = false; state.reloadRequired = true;
      if (state.reloadTimer !== null) clearTimeout(state.reloadTimer);
      state.reloadTimer = null; state.reloadingFrom = null;
      status(unconfirmed ? 'Connection closed before confirmation. Changes may have been applied; reload before retrying.' : 'Elgato connection closed.'); controls();
    };
    renderTargets();
  };
  el('save').onclick = () => {
    controls(); if (el('save').disabled) return;
    const selected = state.catalog.find(x => address(x) === el('target').value);
    if (!selected) { status('Choose an available target.'); return; }
    let argumentsJSON;
    try {
      const args = stop() ? {} : JSON.parse(el('args').value);
      if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error();
      argumentsJSON = JSON.stringify(args);
    } catch { status('Arguments must be a JSON object.'); return; }
    if (!globalThis.crypto?.randomUUID) { status('This inspector cannot create a save request. Update Stream Deck.'); return; }
    const id = globalThis.crypto.randomUUID().toUpperCase();
    const timer = setTimeout(() => {
      if (state.pending?.id !== id) return;
      finishPending(); state.reloadRequired = true; status('No confirmed readback arrived. Changes may have been applied; reload before retrying.'); controls();
    }, 12000);
    state.pending = { id, timer, confirmedRevision: null };
    send({ saveMapping: true, revision: state.baseline.revision, request: id, settings: {
      provider: selected.address.plugin, name: selected.address.name, arguments: argumentsJSON, field: el('field').value, label: el('label').value } });
    status('Waiting for Elgato readback…'); controls();
  };
  el('test').onclick = () => { controls(); if (!el('test').disabled) send({ test: true }); };
  el('refresh').onclick = () => send({ refresh: true });
  el('reload').onclick = () => {
    controls(); if (el('reload').disabled) return;
    state.reloadingFrom = state.latest?.revision || state.baseline?.revision || '';
    state.reloadTimer = setTimeout(() => {
      state.reloadTimer = null; state.reloadingFrom = null; state.reloadRequired = true;
      status('Current key settings did not arrive. Your draft is kept; retry Reload key settings.'); controls();
    }, 12000);
    status('Reading current key settings…'); send({ refresh: true, readSettings: true }); controls();
  };
  for (const id of ['target', 'args', 'field', 'label']) {
    el(id).oninput = markDirty; el(id).onchange = markDirty;
  }
  controls();
})();
