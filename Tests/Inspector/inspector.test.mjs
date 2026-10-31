import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
const source = fs.readFileSync(new URL('../../StreamDeck/cafe.nero.neronook.sdPlugin/inspector.js', import.meta.url), 'utf8');
const entry = { address: { plugin: 'authored.provider', name: 'ping' }, action: {
  id: 'ping', title: 'Authored check', effect: 'readOnly', cancellable: true, input: { fields: [] }, output: { fields: [] } } };
const original = { provider: entry.address.plugin, name: 'ping', arguments: '{}', field: 'message', label: 'Original' };
function fixture(action = 'run') {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', disabled: false, hidden: false, children: [],
      replaceChildren() { this.children = []; }, append(child) { this.children.push(child); } });
    return elements.get(id);
  };
  const sent = [], timers = new Map(); let timerID = 0, requestID = 0, generation = 0;
  class Socket {
    constructor(url) { this.url = url; this.readyState = 0; }
    send(text) { sent.push(JSON.parse(text)); }
  }
  const sandbox = { document: { getElementById: element, createElement: () => ({}) }, TextEncoder,
    WebSocket: Socket, crypto: { randomUUID: () => 'aaaaaaaa-aaaa-4aaa-8aaa-' + String(++requestID).padStart(12, '0') },
    setTimeout: fn => { const id = ++timerID; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id) };
  sandbox.window = sandbox;
  let socket;
  sandbox.WebSocket = class extends Socket { constructor(url) { super(url); socket = this; } };
  vm.runInNewContext(source, sandbox, { filename: 'inspector.js' });
  const actionID = 'cafe.nero.neronook.' + action;
  sandbox.connectElgatoStreamDeckSocket('12345', 'registration-only', 'registerPropertyInspector', '{}',
    JSON.stringify({ context: 'action-instance', action: actionID, payload: { settings: original } }));
  socket.readyState = 1; socket.onopen();
  const frame = (payload, context = 'action-instance') => socket.onmessage({ data: JSON.stringify({ event: 'sendToPropertyInspector', context, action: actionID, payload }) });
  const snapshot = (revision = 'R1', settings = original, extra = {}) => frame({ catalogGeneration: 'g' + ++generation, catalog: [entry], complete: true, online: true, revision, settings, savePending: false, ...extra });
  const change = (id, value) => { element(id).value = value; element(id).oninput(); };
  const saves = () => sent.filter(x => x.payload?.saveMapping);
  const result = (outcome, revision, request = saves().at(-1)?.payload.request) => frame({ mappingResult: { request, outcome, revision, message: 'Authored ' + outcome } });
  return { el: element, sent, timers, socket, frame, snapshot, change, saves, result };
}

test('registration UUID stays separate from action context; no save before snapshot', () => {
  const f = fixture();
  assert.deepEqual(f.sent[0], { event: 'registerPropertyInspector', uuid: 'registration-only' });
  assert.equal(f.sent[1].context, 'action-instance');
  assert.equal(f.el('save').disabled, true);
  f.snapshot(); assert.equal(f.el('save').disabled, false);
});
test('save goes through companion once and waits for readback', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'A draft');
  f.el('save').onclick(); f.el('save').onclick();
  assert.equal(f.saves().length, 1);
  assert.equal(f.saves()[0].payload.revision, 'R1');
  assert.equal(f.saves()[0].payload.settings.label, 'A draft');
  assert.match(f.saves()[0].payload.request, /^AAAAAAAA-/);
  assert.equal(f.sent.some(x => x.event === 'setSettings'), false);
  assert.equal(f.el('save').disabled, true); assert.equal(f.el('test').disabled, true);
  assert.match(f.el('status').textContent, /Waiting/);
});
test('confirmed result before snapshot waits for the exact current revision', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Draft'); f.el('save').onclick();
  f.result('confirmed', 'R2'); assert.equal(f.el('save').disabled, true);
  f.snapshot('R1'); assert.equal(f.el('save').disabled, true);
  f.snapshot('R2', { ...original, label: 'Draft' });
  assert.equal(f.el('save').disabled, false); assert.equal(f.el('test').disabled, false);
  assert.equal(f.el('label').value, 'Draft'); assert.match(f.el('status').textContent, /readback confirmed/);
  assert.equal(f.timers.size, 0);
});
test('snapshot before matching confirmation does not optimistically save', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Draft'); f.el('save').onclick();
  f.snapshot('R2', { ...original, label: 'Draft' });
  assert.equal(f.el('save').disabled, true); assert.match(f.el('status').textContent, /Waiting/);
  f.result('confirmed', 'R2'); assert.equal(f.el('save').disabled, false);
});
test('foreign request and context cannot finish a pending save', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Draft'); f.el('save').onclick();
  f.result('confirmed', 'R2', 'unrelated');
  f.frame({ mappingResult: { request: f.saves()[0].payload.request, outcome: 'confirmed', revision: 'R2' } }, 'another-action');
  assert.equal(f.el('save').disabled, true); assert.equal(f.timers.size, 1);
});
test('background change preserves draft; explicit reload requires a fresh revision', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Keep this draft'); f.change('args', '{"message":"mine"}');
  f.snapshot('R2', { ...original, label: 'Other editor' });
  assert.equal(f.el('label').value, 'Keep this draft'); assert.equal(f.el('args').value, '{"message":"mine"}');
  assert.equal(f.el('save').disabled, true);
  f.el('refresh').onclick(); f.snapshot('R2', { ...original, label: 'Other editor' });
  assert.equal(f.el('label').value, 'Keep this draft'); assert.equal(f.el('save').disabled, true);
  f.el('reload').onclick(); assert.equal(f.sent.at(-1).payload.readSettings, true);
  assert.equal(f.el('label').disabled, true); assert.equal(f.el('reload').disabled, true);
  f.snapshot('R2', { ...original, label: 'Stale snapshot' }); assert.equal(f.el('label').value, 'Keep this draft');
  f.snapshot('R3', { ...original, label: 'Current readback' });
  assert.equal(f.el('label').value, 'Current readback'); assert.equal(f.el('save').disabled, false);
  assert.equal(f.el('label').disabled, false); assert.equal(f.timers.size, 0);
});
test('fresh-settings timeout keeps the draft and permits read retry only', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Draft');
  f.snapshot('R2', { ...original, label: 'Other editor' }); f.el('reload').onclick();
  [...f.timers.values()][0]();
  assert.equal(f.el('label').value, 'Draft'); assert.equal(f.el('label').disabled, false);
  assert.equal(f.el('reload').disabled, false); assert.equal(f.el('save').disabled, true);
  assert.equal(f.saves().length, 0); assert.match(f.el('status').textContent, /draft is kept/);
});
for (const outcome of ['conflict', 'unconfirmed']) {
  test(outcome + ' requires reload and never retries or accepts late confirmation', () => {
    const f = fixture(); f.snapshot(); f.change('label', 'Draft'); f.el('save').onclick();
    const request = f.saves()[0].payload.request;
    f.result(outcome); assert.equal(f.el('label').value, 'Draft'); assert.equal(f.el('save').disabled, true);
    assert.equal(f.timers.size, 0); f.el('save').onclick(); assert.equal(f.saves().length, 1);
    f.result('confirmed', 'R2', request); assert.equal(f.el('save').disabled, true);
  });
}
test('rejected active-run save leaves editable draft and reports no confirmation', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Draft'); f.el('save').onclick();
  f.result('rejected'); assert.equal(f.el('save').disabled, false); assert.equal(f.el('label').value, 'Draft');
  assert.match(f.el('status').textContent, /rejected/); assert.equal(f.el('test').disabled, true);
});
test('watchdog is unconfirmed, never an automatic retry', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Draft'); f.el('save').onclick();
  [...f.timers.values()][0]();
  assert.match(f.el('status').textContent, /may have been applied/);
  assert.equal(f.el('save').disabled, true); assert.equal(f.saves().length, 1);
});
test('disconnect during save preserves uncertainty and draft', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Draft'); f.el('save').onclick();
  f.socket.readyState = 3; f.socket.onclose();
  assert.equal(f.el('label').value, 'Draft'); assert.equal(f.el('save').disabled, true);
  assert.match(f.el('status').textContent, /before confirmation/); assert.equal(f.timers.size, 0);
});
test('invalid arguments never reach the companion', () => {
  const f = fixture(); f.snapshot(); f.change('args', '[]'); f.el('save').onclick();
  assert.equal(f.saves().length, 0); assert.match(f.el('status').textContent, /JSON object/);
});
test('menu stays dynamic without persistent target writes', () => {
  const f = fixture('menu'); f.snapshot();
  assert.equal(f.el('save').disabled, true); assert.equal(f.el('target').disabled, true);
  assert.match(f.el('schema').textContent, /no saved target/);
  f.el('save').onclick(); assert.equal(f.saves().length, 0);
  f.el('test').onclick(); assert.equal(f.sent.at(-1).payload.test, true);
});
test('missing legacy target is explicit and never guessed by title', () => {
  const f = fixture(); f.snapshot('R1', { ...original, name: 'old_missing_action' });
  assert.equal(f.el('target').value, 'authored.provider/old_missing_action');
  assert.match(f.el('target').children.at(-1).textContent, /Unavailable saved target/);
  f.el('save').onclick(); assert.equal(f.saves().length, 0);
  f.change('target', 'authored.provider/ping'); f.el('save').onclick(); assert.equal(f.saves().length, 1);
});
test('old companion without revision fails closed without direct write fallback', () => {
  const f = fixture(); f.frame({ catalogGeneration: 'old', catalog: [entry], complete: true, online: true });
  assert.equal(f.el('save').disabled, true); assert.match(f.el('status').textContent, /Update/);
  f.el('save').onclick(); assert.equal(f.sent.some(x => x.event === 'setSettings'), false);
});
test('new inspector retains an earlier unresolved save until explicit fresh readback', () => {
  const f = fixture(); f.snapshot('R1', original, { saveUnresolved: true });
  assert.equal(f.el('save').disabled, true); assert.equal(f.el('test').disabled, true);
  assert.match(f.el('status').textContent, /earlier mapping save is unconfirmed/);
  f.el('reload').onclick();
  f.snapshot('R1', original, { saveUnresolved: true }); assert.equal(f.el('save').disabled, true);
  f.snapshot('R2'); assert.equal(f.el('save').disabled, false); assert.equal(f.el('test').disabled, false);
});
test('saved-outcome wait blocks new effects and releases only on companion readiness', () => {
  const f = fixture(); f.snapshot('R1', original, { recoveryBlocked: true });
  f.el('save').onclick(); f.el('test').onclick();
  assert.equal(f.saves().length, 0); assert.equal(f.sent.some(x => x.payload?.test), false);
  assert.equal(f.el('save').disabled, true); assert.equal(f.el('test').disabled, true);
  assert.match(f.el('status').textContent, /Waiting for a saved outcome/);
  f.frame({ recoveryReadiness: true, recoveryBlocked: false });
  assert.equal(f.el('save').disabled, false); assert.equal(f.el('test').disabled, false);
  assert.equal(f.saves().length, 0);
});
test('saved-outcome wait preserves a draft without requiring an unnecessary reload', () => {
  const f = fixture(); f.snapshot(); f.change('label', 'Keep my draft');
  f.snapshot('R1', original, { recoveryBlocked: true });
  assert.equal(f.el('label').value, 'Keep my draft'); assert.equal(f.el('save').disabled, true);
  f.frame({ recoveryReadiness: true, recoveryBlocked: false });
  assert.equal(f.el('label').value, 'Keep my draft'); assert.equal(f.el('save').disabled, false);
  assert.equal(f.saves().length, 0);
});
test('saved-outcome wait keeps the exact paired Stop control available', () => {
  const f = fixture('stop'); f.snapshot('R1', original, { recoveryBlocked: true });
  assert.equal(f.el('save').disabled, true); assert.equal(f.el('test').disabled, false);
  f.el('test').onclick();
  assert.equal(f.sent.filter(x => x.payload?.test).length, 1);
  assert.equal(f.saves().length, 0);
});
