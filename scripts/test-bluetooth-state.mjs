#!/usr/bin/env node
// Exercise the panel's actual JS with synthetic BlueZ rows. No Bluetooth,
// helper processes, desktop session or VM is accessed. Requires Node.js 18+.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const source = readFileSync(new URL(
  '../default/etc/skel/.config/omarchy/plugins/mobile.shell/BluetoothScreen.qml',
  import.meta.url), 'utf8');

// Extract the QML-owned function/event bodies rather than duplicating their
// policy in a test model. Strings and comments may contain braces.
function body(marker) {
  const index = source.indexOf(marker);
  assert.notEqual(index, -1, `Missing panel code: ${marker}`);
  const start = source.indexOf('{', index + marker.length) + 1;
  let depth = 1, quote = '', escaped = false, comment = '';
  for (let i = start; i < source.length; i++) {
    const c = source[i], next = source[i + 1];
    if (comment === '//') {
      if (c === '\n') comment = '';
    } else if (comment === '/*') {
      if (c === '*' && next === '/') { comment = ''; i++; }
    } else if (quote) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === quote) quote = '';
    } else if (c === '/' && (next === '/' || next === '*')) {
      comment = c + next; i++;
    } else if (c === '"' || c === "'" || c === '`') quote = c;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return source.slice(start, i);
  }
  assert.fail(`Unclosed panel code: ${marker}`);
}

const rowStatus = new Function('row', body('function rowStatus(row)'));
const canPair = new Function('row', body('function canPair(row)'));
const actionComplete = new Function('verb', 'row', body('function actionComplete(verb, row)'));
const connectRow = new Function('root', 'row', body('function connectRow(row)'));
const pairRow = new Function('root', 'row', body('function pairRow(row)'));
const settle = new Function('root', 'actionTimeout', body('onLiveRowsChanged:'));
const readRows = new Function('root', 'Bluetooth', body('readonly property var liveRows:'));

function row(flags = {}) {
  const r = { address: 'fixture', name: 'Fixture', connected: false,
    paired: false, bonded: false, trusted: false, pairing: false,
    blocked: false, ...flags };
  return { ...r, known: r.paired || r.bonded || r.trusted };
}

function rootFor(rows) {
  const root = { liveRows: rows, busyAddress: '', busyVerb: '', busyName: '',
    expandedAddress: 'fixture', calls: [], canPair, actionComplete,
    runAction(r, verb, label) {
      this.calls.push([r.address, verb, label]);
      this.busyAddress = r.address;
      this.busyVerb = label;
      this.busyName = r.name;
    } };
  root.pairRow = r => pairRow(root, r);
  return root;
}

for (const [name, flags, expected] of [
  ['new device', {}, 'Available'],
  ['trust only is not pairing', { trusted: true }, 'Trusted'],
  ['pair without bond', { paired: true }, 'Paired (not saved)'],
  ['stored bond', { paired: true, bonded: true }, 'Paired'],
  ['bond reported before paired', { bonded: true }, 'Paired'],
  ['unpaired connection', { connected: true }, 'Connected (not saved)'],
  ['paired unbonded connection', { connected: true, paired: true }, 'Connected (not saved)'],
  ['saved connection', { connected: true, paired: true, bonded: true }, 'Connected'],
  ['pair in progress', { pairing: true, connected: true }, 'Pairing…'],
  ['blocked', { blocked: true, trusted: true }, 'Blocked'],
]) {
  test(`Status: ${name}`, () => assert.equal(rowStatus(row(flags)), expected));
}

test('Snapshot retains paired/bonded/trusted as distinct primitive fields', () => {
  const rows = readRows({ hasHumanName: () => true }, { devices: { values: [
    { address: 'trusted', name: 'A', trusted: true },
    { address: 'paired', name: 'B', paired: true },
    { address: 'bonded', name: 'C', bonded: true },
  ] } });
  assert.deepEqual(rows.map(r => [r.address, r.known, r.paired, r.bonded, r.trusted]), [
    ['trusted', true, false, false, true],
    ['paired', true, true, false, false],
    ['bonded', true, false, true, false],
  ]);
});

test('Existing connected/remembered/new sorting is preserved', () => {
  const rows = readRows({ hasHumanName: () => true }, { devices: { values: [
    { address: 'new', name: 'A' },
    { address: 'trusted', name: 'Z', trusted: true },
    { address: 'connected', name: 'Z', connected: true },
  ] } });
  assert.deepEqual(rows.map(r => r.address), ['connected', 'trusted', 'new']);
});

for (const [name, flags, expected] of [
  ['discovered device pairs', {}, ['fixture', 'pair', 'Pairing']],
  ['trusted-only connection is retained', { trusted: true }, ['fixture', 'connect', 'Connecting']],
  ['paired unbonded device reconnects', { paired: true }, ['fixture', 'connect', 'Connecting']],
  ['bonded device reconnects', { bonded: true }, ['fixture', 'connect', 'Connecting']],
]) {
  test(`Primary action: ${name}`, () => {
    const r = row(flags), root = rootFor([r]);
    connectRow(root, r);
    assert.deepEqual(root.calls, [expected]);
  });
}

test('Trusted-only device also permits an explicit Pair without Forget', () => {
  const r = row({ trusted: true }), root = rootFor([r]);
  assert.equal(canPair(r), true);
  pairRow(root, r);
  assert.deepEqual(root.calls, [['fixture', 'pair', 'Pairing']]);
});

for (const flags of [
  { connected: true }, { paired: true }, { bonded: true },
  { pairing: true }, { blocked: true },
]) {
  test(`Pair refuses inappropriate state ${JSON.stringify(flags)}`, () => {
    const r = row(flags), root = rootFor([r]);
    pairRow(root, r);
    assert.deepEqual(root.calls, []);
  });
}

test('A connected unbonded device is left working by both action paths', () => {
  const r = row({ trusted: true, connected: true }), root = rootFor([r]);
  connectRow(root, r);
  pairRow(root, r);
  assert.deepEqual(root.calls, []);
});

test('Pair rechecks a frozen row after a bond was established', () => {
  const frozen = row({ trusted: true });
  const root = rootFor([row({ trusted: true, paired: true, bonded: true })]);
  pairRow(root, frozen);
  assert.deepEqual(root.calls, []);
});

test('Pair rechecks a frozen row after an unbonded connection was established', () => {
  const frozen = row({ trusted: true });
  const root = rootFor([row({ trusted: true, connected: true })]);
  pairRow(root, frozen);
  assert.deepEqual(root.calls, []);
});

test('A vanished device is not paired using its frozen row', () => {
  const root = rootFor([]);
  pairRow(root, row({ trusted: true }));
  assert.deepEqual(root.calls, []);
});

test('A second Pair/Connect cannot replace an in-flight action', () => {
  const r = row({ trusted: true }), root = rootFor([r]);
  root.busyAddress = 'another-fixture';
  pairRow(root, r);
  connectRow(root, r);
  assert.deepEqual(root.calls, []);
});

for (const [name, flags, expected] of [
  ['early connection is not pairing success', { connected: true }, false],
  ['helper trust is not pairing success', { connected: true, trusted: true }, false],
  ['pair in progress stays pending', { connected: true, paired: true, pairing: true }, false],
  ['paired but disconnected stays pending', { paired: true }, false],
  ['saved but disconnected stays pending', { bonded: true }, false],
  ['unbonded pairing may succeed', { connected: true, paired: true }, true],
  ['saved pairing may succeed', { connected: true, paired: true, bonded: true }, true],
]) {
  test(`Completion: ${name}`, () => {
    const root = rootFor([row(flags)]);
    Object.assign(root, { busyAddress: 'fixture', busyVerb: 'Pairing', busyName: 'Fixture' });
    let stopped = false;
    settle(root, { stop() { stopped = true; } });
    assert.equal(stopped, expected);
    assert.equal(root.busyAddress, expected ? '' : 'fixture');
    assert.equal(root.expandedAddress, expected ? '' : 'fixture');
    assert.equal(root.busyVerb, expected ? '' : 'Pairing');
    assert.equal(root.busyName, expected ? '' : 'Fixture');
  });
}

test('Pair completion ignores a different device becoming paired', () => {
  const root = rootFor([row({ address: 'other', connected: true, paired: true, bonded: true })]);
  Object.assign(root, { busyAddress: 'fixture', busyVerb: 'Pairing' });
  settle(root, { stop() { assert.fail('wrong device completed action'); } });
  assert.equal(root.busyAddress, 'fixture');
});

for (const [verb, r, expected] of [
  ['Connecting', row({ connected: true }), true],
  ['Connecting', row({ connected: true, paired: true }), true],
  ['Connecting', row({ bonded: true }), false],
  ['Connecting', null, false],
  ['Pairing', null, false],
  ['Disconnecting', row({ bonded: true }), true],
  ['Disconnecting', row({ connected: true }), false],
  ['Disconnecting', null, true],
  ['Forgetting', null, true],
  ['Forgetting', row(), true],
  ['Forgetting', row({ trusted: true }), false],
  ['Forgetting', row({ paired: true }), false],
  ['Forgetting', row({ bonded: true }), false],
]) {
  test(`${verb} completion for ${JSON.stringify(r)}`, () => {
    assert.equal(actionComplete(verb, r), expected);
  });
}

test('Row text and explicit Pair control use the tested panel functions', () => {
  assert.match(source, /:\s*root\.rowStatus\(rowItem\.modelData\)/);
  assert.match(source, /onClicked:\s*root\.pairRow\(rowItem\.modelData\)/);
  assert.match(source, /readonly property bool canPairSeparately:\s*rowItem\.modelData\.known\s*&& root\.canPair\(rowItem\.modelData\)/);
});
