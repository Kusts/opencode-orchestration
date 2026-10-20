// index.tests.js -- isolated CLAIM bridge hook (F1-S1, fixture only).
// node:test suite, no spawn of real processes. The bridge child is always
// a stub; the real PowerShell bridge is covered by the PS suite.
// Run: node --test plugins/g1-dispatch-admission/index.tests.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');

const plugin = require('./index.js');
const T = plugin.__g1IsolatedClaimTest;

const ISO_KEYS = [
  'OPENCODE_G1_ISOLATED_CLAIM',
  'OPENCODE_G1_CLAIM_BRIDGE',
  'OPENCODE_G1_CLAIM_CONTEXT',
  'OPENCODE_G1_CLAIM_SHELL',
  'OPENCODE_G1_CLAIM_TIMEOUT_MS',
];

function saveEnv() {
  const out = {};
  for (const k of ISO_KEYS) out[k] = process.env[k];
  return out;
}

function restoreEnv(saved) {
  for (const k of ISO_KEYS) {
    if (saved[k] === undefined) delete process.env[k];
    else process.env[k] = saved[k];
  }
}

function clearIsoEnv() {
  for (const k of ISO_KEYS) delete process.env[k];
}

function makeFixtureFiles() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'g1-iso-'));
  const bridge = path.join(dir, 'native-dispatch-claim.ps1');
  const context = path.join(dir, 'claim-context.json');
  fs.writeFileSync(bridge, '# fixture bridge\n', 'utf8');
  // Setup binds these hashes (R1); keep them 32hex lowercase.
  fs.writeFileSync(context, JSON.stringify({
    schema_version: 1,
    idempotency_key: 'a'.repeat(32),
    prepared_fingerprint: 'b'.repeat(32),
  }) + '\n', 'utf8');
  return { dir, bridge, context };
}

function cleanDir(dir) {
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch (ignored) {}
}

const CALL_MATERIAL = 'ndcall1;session:6:ses-01;message:6:msg-01;call:7:call-01;caller:7:planner;target:5:coder;key:32:' + 'a'.repeat(32) + ';';
const CALL_FP = require('node:crypto').createHash('sha256').update(CALL_MATERIAL, 'utf8').digest('hex').slice(0, 32);

function goodDoc() {
  return {
    schema_version: 1,
    operation: 'claim',
    ok: true,
    claimed: true,
    reason: '',
    idempotency_key: 'a'.repeat(32),
    prepared_fingerprint: 'b'.repeat(32),
    session_id: 'ses-01',
    message_id: 'msg-01',
    call_id: 'call-01',
    call_fingerprint: CALL_FP,
    call_binding_material: CALL_MATERIAL,
    target_agent: 'coder',
    tool: 'subagent',
    grant_projection: {
      ok: true,
      source_revision: 'c'.repeat(32),
      denied: [],
      reason: 'grant-projection-clear',
      authority: false,
    },
    grants_authority: false,
    verified_pass: false,
    done_approved: false,
  };
}

function clearProjection() {
  return {
    ok: true,
    source_revision: 'c'.repeat(32),
    denied: [],
    reason: 'grant-projection-clear',
    authority: false,
  };
}

function goodInput() {
  return {
    tool: 'subagent',
    sessionID: 'ses-01',
    messageID: 'msg-01',
    callID: 'call-01',
    callerAgent: 'planner',
    args: { agent: 'coder', prompt: 'do it', note: 's1' },
  };
}

// Stub spawn: script({ child, payload }) drives stdout/close.
function stubSpawn(calls, script) {
  return function fakeSpawn(exe, argv, opts) {
    const child = new EventEmitter();
    const stdout = new EventEmitter();
    const stderr = new EventEmitter();
    const stdin = new EventEmitter();
    let payload = '';
    stdin.write = (chunk) => { payload += String(chunk); return true; };
    stdin.end = () => {
      try { script({ child, stdout, payload, exe, argv, opts }); }
      catch (err) { child.emit('error', err); }
    };
    child.stdin = stdin;
    child.stdout = stdout;
    child.stderr = stderr;
    child.kill = () => { try { child.emit('close', null); } catch (ignored) {} return true; };
    calls.push({ exe, argv, opts, getPayload: () => payload });
    return child;
  };
}

function successScript(text) {
  return ({ child, stdout }) => {
    stdout.emit('data', text);
    child.emit('close', 0);
  };
}

test('outside isolated mode: no execute.before hook is registered', async () => {
  const saved = saveEnv();
  try {
    clearIsoEnv();
    let hooked = null;
    const ctx = { tool: { hook: async (name, fn) => { hooked = { name, fn }; } } };
    await plugin.G1DispatchAdmission.setup(ctx);
    assert.equal(hooked, null);
  } finally { restoreEnv(saved); }
});

test('isolated mode with incomplete config throws (invalid fixture)', async () => {
  const saved = saveEnv();
  try {
    clearIsoEnv();
    process.env.OPENCODE_G1_ISOLATED_CLAIM = '1';
    const ctx = { tool: { hook: async () => {} } };
    await assert.rejects(plugin.G1DispatchAdmission.setup(ctx), /invalid fixture/);
  } finally { restoreEnv(saved); }
});

test('isolated mode with bad timeout throws', async () => {
  const saved = saveEnv();
  const fx = makeFixtureFiles();
  try {
    clearIsoEnv();
    process.env.OPENCODE_G1_ISOLATED_CLAIM = '1';
    process.env.OPENCODE_G1_CLAIM_BRIDGE = fx.bridge;
    process.env.OPENCODE_G1_CLAIM_CONTEXT = fx.context;
    process.env.OPENCODE_G1_CLAIM_SHELL = process.execPath;
    process.env.OPENCODE_G1_CLAIM_TIMEOUT_MS = 'nope';
    const ctx = { tool: { hook: async () => {} } };
    await assert.rejects(plugin.G1DispatchAdmission.setup(ctx), /invalid fixture/);
  } finally { restoreEnv(saved); cleanDir(fx.dir); }
});

test('isolated mode with missing bridge file throws', async () => {
  const saved = saveEnv();
  const fx = makeFixtureFiles();
  try {
    clearIsoEnv();
    process.env.OPENCODE_G1_ISOLATED_CLAIM = '1';
    process.env.OPENCODE_G1_CLAIM_BRIDGE = path.join(fx.dir, 'no-such.ps1');
    process.env.OPENCODE_G1_CLAIM_CONTEXT = fx.context;
    process.env.OPENCODE_G1_CLAIM_SHELL = process.execPath;
    const ctx = { tool: { hook: async () => {} } };
    await assert.rejects(plugin.G1DispatchAdmission.setup(ctx), /invalid fixture/);
  } finally { restoreEnv(saved); cleanDir(fx.dir); }
});

test('isolated mode registers one execute.before hook; existing permission path intact', async () => {
  const saved = saveEnv();
  const fx = makeFixtureFiles();
  try {
    clearIsoEnv();
    process.env.OPENCODE_G1_ISOLATED_CLAIM = '1';
    process.env.OPENCODE_G1_CLAIM_BRIDGE = fx.bridge;
    process.env.OPENCODE_G1_CLAIM_CONTEXT = fx.context;
    process.env.OPENCODE_G1_CLAIM_SHELL = process.execPath;
    let toolHook = null;
    let permHook = null;
    const ctx = {
      tool: { hook: async (name, fn) => { toolHook = { name, fn }; } },
      permission: { hook: (name, fn) => { permHook = { name, fn }; } },
    };
    await plugin.G1DispatchAdmission.setup(ctx);
    assert.ok(toolHook !== null);
    assert.equal(toolHook.name, 'execute.before');
    assert.equal(typeof toolHook.fn, 'function');
    assert.ok(permHook !== null);
    assert.equal(permHook.name, 'evaluate');
  } finally { restoreEnv(saved); cleanDir(fx.dir); }
});

test('isolated mode without tool.hook throws (invalid fixture)', async () => {
  const saved = saveEnv();
  const fx = makeFixtureFiles();
  try {
    clearIsoEnv();
    process.env.OPENCODE_G1_ISOLATED_CLAIM = '1';
    process.env.OPENCODE_G1_CLAIM_BRIDGE = fx.bridge;
    process.env.OPENCODE_G1_CLAIM_CONTEXT = fx.context;
    process.env.OPENCODE_G1_CLAIM_SHELL = process.execPath;
    await assert.rejects(plugin.G1DispatchAdmission.setup({}), /invalid fixture/);
  } finally { restoreEnv(saved); cleanDir(fx.dir); }
});

test('config validation: absolute paths, timeout bounds, default', () => {
  const fx = makeFixtureFiles();
  try {
    assert.equal(T.readIsolatedClaimConfig({}).ok, false);
    assert.equal(T.readIsolatedClaimConfig({
      OPENCODE_G1_CLAIM_BRIDGE: 'rel.ps1',
      OPENCODE_G1_CLAIM_CONTEXT: fx.context,
      OPENCODE_G1_CLAIM_SHELL: process.execPath,
    }).ok, false);
    const good = T.readIsolatedClaimConfig({
      OPENCODE_G1_CLAIM_BRIDGE: fx.bridge,
      OPENCODE_G1_CLAIM_CONTEXT: fx.context,
      OPENCODE_G1_CLAIM_SHELL: process.execPath,
    });
    assert.equal(good.ok, true);
    assert.equal(good.timeoutMs, 10000);
    const badTimeout = T.readIsolatedClaimConfig({
      OPENCODE_G1_CLAIM_BRIDGE: fx.bridge,
      OPENCODE_G1_CLAIM_CONTEXT: fx.context,
      OPENCODE_G1_CLAIM_SHELL: process.execPath,
      OPENCODE_G1_CLAIM_TIMEOUT_MS: '999999',
    });
    assert.equal(badTimeout.ok, false);
    assert.equal(T.isIsolatedClaimEnabled({ OPENCODE_G1_ISOLATED_CLAIM: '1' }), true);
    assert.equal(T.isIsolatedClaimEnabled({ OPENCODE_G1_ISOLATED_CLAIM: 'true' }), false);
    assert.equal(T.isIsolatedClaimEnabled({}), false);
  } finally { cleanDir(fx.dir); }
});

function makeHandler(cfg, spawnFn) {
  return T.makeIsolatedClaimHandler(cfg, { spawnFn });
}

function baseCfg() {
  return {
    bridge: '/abs/bridge.ps1',
    context: '/abs/context.json',
    shell: '/abs/pwsh',
    timeoutMs: 5000,
    expectedIdempotencyKey: 'a'.repeat(32),
    expectedPreparedFingerprint: 'b'.repeat(32),
  };
}

test('non-subagent tool abstains without spawning', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript('{}')));
  const out = await handler({ tool: 'read', sessionID: 'ses-01', messageID: 'msg-01', callID: 'call-01', callerAgent: 'planner', args: { agent: 'coder' } });
  assert.equal(out, undefined);
  assert.equal(calls.length, 0);
});

test('positive claim abstains; spawn uses shell:false, absolute paths, literal argv, stdin request', async () => {
  const calls = [];
  const text = JSON.stringify(goodDoc());
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(text)));
  const input = goodInput();
  const before = JSON.stringify(input);
  const out = await handler(input);
  assert.equal(out, undefined);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].exe, '/abs/pwsh');
  // SEC2: the real spawn carries -NoProfile -NonInteractive -File, exactly
  // like the harness invocation.
  assert.deepEqual(calls[0].argv, ['-NoProfile', '-NonInteractive', '-File', '/abs/bridge.ps1', '-Action', 'claim', '-ContextFile', '/abs/context.json']);
  assert.equal(calls[0].opts.shell, false);
  const payload = JSON.parse(calls[0].getPayload());
  assert.equal(payload.schema_version, 1);
  assert.equal(payload.tool, 'subagent');
  assert.equal(payload.session_id, 'ses-01');
  assert.equal(payload.caller_agent, 'planner');
  assert.equal(payload.target_agent, 'coder');
  assert.deepEqual(payload.args, { agent: 'coder', prompt: 'do it', note: 's1' });
  assert.equal(JSON.stringify(input), before);
});

test('bridge non-zero exit refuses', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, ({ child }) => { child.emit('close', 1); }));
  await assert.rejects(handler(goodInput()), /g1-isolated-claim denied/);
});

test('bridge timeout refuses', async () => {
  const calls = [];
  const hanging = stubSpawn(calls, () => {});
  const handler = makeHandler({ bridge: '/abs/b.ps1', context: '/abs/c.json', shell: '/abs/s', timeoutMs: 50 }, hanging);
  await assert.rejects(handler(goodInput()), /isolated-bridge-timeout/);
});

test('malformed bridge output refuses', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript('{not json')));
  await assert.rejects(handler(goodInput()), /g1-isolated-claim denied/);
});

test('bridge output with extra field refuses', async () => {
  const doc = goodDoc();
  doc.extra = 'nope';
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /g1-isolated-claim denied/);
});

test('bridge output with authority pins set refuses', async () => {
  const doc = goodDoc();
  doc.done_approved = true;
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-authority-pin-violated/);
});

test('bridge output with binding mismatch refuses', async () => {
  const doc = goodDoc();
  doc.call_id = 'call-other';
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-binding-mismatch/);
});

test('bridge ok:false refuses (never allow)', async () => {
  const doc = goodDoc();
  doc.ok = false;
  doc.claimed = false;
  doc.reason = 'claim-already-consumed';
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-claim-refused-claim-already-consumed/);
});

test('unknown input shape refuses without spawning', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(goodDoc()))));
  await assert.rejects(handler({ tool: 'subagent' }), /g1-isolated-claim denied/);
  assert.equal(calls.length, 0);
});

test('handler never returns allow and never throws raw content', async () => {
  const doc = goodDoc();
  doc.ok = false;
  doc.claimed = false;
  doc.reason = 'claim-fingerprint-mismatch';
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  let err = null;
  try {
    await handler(goodInput());
  } catch (e) { err = e; }
  assert.ok(err instanceof Error);
  assert.match(err.message, /^g1-isolated-claim denied: [a-z0-9_-]{1,64}$/);
  assert.equal(err.code, 'G1_ISOLATED_CLAIM_DENY');
});

test('hook ordering: invalid subagent input denies even with no bridge configured at call time', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(goodDoc()))));
  const bad = goodInput();
  delete bad.callID;
  await assert.rejects(handler(bad), /isolated-identity-unknown/);
  assert.equal(calls.length, 0);
});

test('R2: read without identity abstains immediately (no deny, no spawn)', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(goodDoc()))));
  const out = await handler({ tool: 'read', args: { path: 'x' } });
  assert.equal(out, undefined);
  assert.equal(calls.length, 0);
});

test('extractIsolatedToolName reads aliases, empty when unknown', () => {
  assert.equal(T.extractIsolatedToolName({ tool: 'subagent' }), 'subagent');
  assert.equal(T.extractIsolatedToolName({ toolName: 'read' }), 'read');
  assert.equal(T.extractIsolatedToolName({ name: 'write' }), 'write');
  assert.equal(T.extractIsolatedToolName({}), '');
  assert.equal(T.extractIsolatedToolName(null), '');
});

test('R1: tampered idempotency_key refuses against setup bindings', async () => {
  const doc = goodDoc();
  doc.idempotency_key = 'c'.repeat(32);
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-key-mismatch/);
});

test('R1: tampered prepared_fingerprint refuses against setup bindings', async () => {
  const doc = goodDoc();
  doc.prepared_fingerprint = 'd'.repeat(32);
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-fingerprint-mismatch/);
});

test('R1: tampered call_fingerprint refuses (recompute mismatch)', async () => {
  const doc = goodDoc();
  doc.call_fingerprint = 'e'.repeat(32);
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-call-fingerprint-mismatch/);
});

test('R1: one-element array hashes refuse (no coercion)', async () => {
  for (const field of ['idempotency_key', 'prepared_fingerprint', 'call_fingerprint']) {
    const doc = goodDoc();
    doc[field] = ['a'.repeat(32)];
    const calls = [];
    const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
    await assert.rejects(handler(goodInput()), /isolated-bridge-output-shape/, field);
  }
});

test('R1: divergent material refuses (exact canonical match runs first)', async () => {
  const doc = goodDoc();
  doc.call_binding_material = CALL_MATERIAL + 'X';
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-material-mismatch/);
});

test('R1: setup binding mismatch refuses even with coherent output', async () => {
  // The output is coherent for key A, but setup expects key F: the
  // reconstructed material (bound to F) already mismatches, so the
  // refusal lands on the material gate before the key gate.
  const cfg = baseCfg();
  cfg.expectedIdempotencyKey = 'f'.repeat(32);
  const calls = [];
  const handler = makeHandler(cfg, stubSpawn(calls, successScript(JSON.stringify(goodDoc()))));
  await assert.rejects(handler(goodInput()), /isolated-material-mismatch/);
});

test('R1: echoed target/tool mismatch refuses', async () => {
  const doc = goodDoc();
  doc.target_agent = 'tester';
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-binding-mismatch/);
  const doc2 = goodDoc();
  doc2.tool = 'read';
  const calls2 = [];
  const handler2 = makeHandler(baseCfg(), stubSpawn(calls2, successScript(JSON.stringify(doc2))));
  await assert.rejects(handler2(goodInput()), /isolated-binding-mismatch/);
});

test('readIsolatedContextBindings validation', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'g1-bind-'));
  try {
    const valid = path.join(dir, 'valid.json');
    fs.writeFileSync(valid, JSON.stringify({ idempotency_key: 'a'.repeat(32), prepared_fingerprint: 'b'.repeat(32) }), 'utf8');
    const r = T.readIsolatedContextBindings(valid);
    assert.equal(r.ok, true);
    assert.equal(r.idempotencyKey, 'a'.repeat(32));
    assert.equal(T.readIsolatedContextBindings(path.join(dir, 'nope.json')).ok, false);
    const numHash = path.join(dir, 'num.json');
    fs.writeFileSync(numHash, JSON.stringify({ idempotency_key: 123, prepared_fingerprint: 'b'.repeat(32) }), 'utf8');
    assert.equal(T.readIsolatedContextBindings(numHash).ok, false);
    const arrHash = path.join(dir, 'arr.json');
    fs.writeFileSync(arrHash, JSON.stringify({ idempotency_key: ['a'.repeat(32)], prepared_fingerprint: 'b'.repeat(32) }), 'utf8');
    assert.equal(T.readIsolatedContextBindings(arrHash).ok, false);
    const badShape = path.join(dir, 'shape.json');
    fs.writeFileSync(badShape, JSON.stringify({ idempotency_key: 'z'.repeat(32), prepared_fingerprint: 'b'.repeat(32) }), 'utf8');
    assert.equal(T.readIsolatedContextBindings(badShape).ok, false);
    const badEnc = path.join(dir, 'enc.json');
    fs.writeFileSync(badEnc, Buffer.from([0x7b, 0xff, 0x7d]));
    assert.equal(T.readIsolatedContextBindings(badEnc).ok, false);
  } finally { cleanDir(dir); }
});

test('R4: multibyte character split across chunks decodes correctly', async () => {
  const doc = goodDoc();
  doc.ok = false;
  doc.claimed = false;
  doc.reason = 'caf\u00e9-x';
  const buf = Buffer.from(JSON.stringify(doc), 'utf8');
  const idx = buf.indexOf(Buffer.from('\u00e9', 'utf8'));
  assert.ok(idx > 0);
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, ({ child, stdout }) => {
    stdout.emit('data', buf.slice(0, idx + 1));
    stdout.emit('data', buf.slice(idx + 1));
    child.emit('close', 0);
  }));
  await assert.rejects(handler(goodInput()), /isolated-claim-refused-caf--x/);
});

test('R4: invalid UTF-8 byte in stdout refuses', async () => {
  const text = JSON.stringify(goodDoc());
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, ({ child, stdout }) => {
    stdout.emit('data', Buffer.from(text.slice(0, 10), 'utf8'));
    stdout.emit('data', Buffer.from([0xff, 0xfe]));
    stdout.emit('data', Buffer.from(text.slice(10), 'utf8'));
    child.emit('close', 0);
  }));
  await assert.rejects(handler(goodInput()), /isolated-bridge-output-invalid/);
});

test('R4: stdout exactly at 64 KiB passes, one byte over refuses', async () => {
  const text = JSON.stringify(goodDoc());
  const pad = 65536 - Buffer.byteLength(text, 'utf8');
  assert.ok(pad > 0);
  const exact = text + ' '.repeat(pad);
  assert.equal(Buffer.byteLength(exact, 'utf8'), 65536);
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, ({ child, stdout }) => {
    const buf = Buffer.from(exact, 'utf8');
    stdout.emit('data', buf.slice(0, 1000));
    stdout.emit('data', buf.slice(1000));
    child.emit('close', 0);
  }));
  assert.equal(await handler(goodInput()), undefined);
  const over = exact + ' ';
  assert.equal(Buffer.byteLength(over, 'utf8'), 65537);
  const calls2 = [];
  const handler2 = makeHandler(baseCfg(), stubSpawn(calls2, ({ child, stdout }) => {
    stdout.emit('data', Buffer.from(over, 'utf8'));
    child.emit('close', 0);
  }));
  await assert.rejects(handler2(goodInput()), /isolated-bridge-output-unbounded/);
});

test('R4: oversized multibyte payload never spawns (bytes, not chars)', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(goodDoc()))));
  const input = goodInput();
  input.args = { agent: 'coder', prompt: '\u00e9'.repeat(40000), note: 's1' };
  await assert.rejects(handler(input), /isolated-request-unbounded/);
  assert.equal(calls.length, 0);
});

function findRealShell() {
  const cands = [
    'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
    'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
  ];
  for (const c of cands) {
    try { if (fs.statSync(c).isFile()) return c; } catch (ignored) {}
  }
  return null;
}

const REAL_SHELL = findRealShell();
const REAL_BRIDGE = path.join(__dirname, '..', '..', 'scripts', 'v3', 'native-dispatch-claim.ps1');

test('SEC4: real subprocess with invalid context refuses', { skip: REAL_SHELL === null }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'g1-sec4-'));
  try {
    const badCtx = path.join(dir, 'ctx.json');
    fs.writeFileSync(badCtx, '{"schema_version":2}', 'utf8');
    const cfg = { bridge: REAL_BRIDGE, context: badCtx, shell: REAL_SHELL, timeoutMs: 20000 };
    const handler = makeHandler(cfg, {});
    await assert.rejects(handler(goodInput()), /isolated-bridge-exit-refused/);
  } finally { cleanDir(dir); }
});

test('SEC4: real subprocess with missing bridge refuses', { skip: REAL_SHELL === null }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'g1-sec4b-'));
  try {
    const ctxFile = path.join(dir, 'ctx.json');
    fs.writeFileSync(ctxFile, '{"schema_version":1}', 'utf8');
    const cfg = { bridge: path.join(dir, 'no-such-bridge.ps1'), context: ctxFile, shell: REAL_SHELL, timeoutMs: 20000 };
    const handler = makeHandler(cfg, {});
    await assert.rejects(handler(goodInput()), /isolated-bridge-exit-refused/);
  } finally { cleanDir(dir); }
});

test('R1b: coherent altered material plus matching hash still refuses', () => {
  // The attacker crafts a different canonical string AND its correct
  // sha256: recomputation matches, but the material is not this request.
  const evilMaterial = CALL_MATERIAL + 'X';
  const evilFp = require('node:crypto').createHash('sha256').update(evilMaterial, 'utf8').digest('hex').slice(0, 32);
  const doc = goodDoc();
  doc.call_binding_material = evilMaterial;
  doc.call_fingerprint = evilFp;
  const parsed = T.parseIsolatedClaimResponse(JSON.stringify(doc), {
    session_id: 'ses-01',
    message_id: 'msg-01',
    call_id: 'call-01',
    target_agent: 'coder',
    caller_agent: 'planner',
    tool: 'subagent',
    idempotency_key: 'a'.repeat(32),
    prepared_fingerprint: 'b'.repeat(32),
  });
  assert.equal(parsed.ok, false);
  assert.equal(parsed.reason, 'isolated-material-mismatch');
});

test('R1b: buildIsolatedCallMaterial mirrors the bridge field order', () => {
  const built = T.buildIsolatedCallMaterial({
    sessionId: 'ses-01',
    messageId: 'msg-01',
    callId: 'call-01',
    caller: 'planner',
    target: 'coder',
    key: 'a'.repeat(32),
  });
  assert.equal(built, CALL_MATERIAL);
  // UTF-16 length agreement: astral chars count 2 on both sides.
  const astral = T.buildIsolatedCallMaterial({
    sessionId: '\u{1F600}',
    messageId: 'm',
    callId: 'c',
    caller: 'p',
    target: 't',
    key: 'k'.repeat(32),
  });
  assert.ok(astral.includes('session:2:\u{1F600};'));
});

test('R1b: handler refuses coherent forged material end to end', async () => {
  const evilMaterial = CALL_MATERIAL + 'X';
  const evilFp = require('node:crypto').createHash('sha256').update(evilMaterial, 'utf8').digest('hex').slice(0, 32);
  const doc = goodDoc();
  doc.call_binding_material = evilMaterial;
  doc.call_fingerprint = evilFp;
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-material-mismatch/);
});

test('R4b: context file past 64 KiB refuses at setup (descriptor-limited read)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'g1-bigctx-'));
  try {
    const bigCtx = path.join(dir, 'ctx.json');
    const payload = JSON.stringify({
      schema_version: 1,
      idempotency_key: 'a'.repeat(32),
      prepared_fingerprint: 'b'.repeat(32),
      pad: 'x'.repeat(70000),
    });
    assert.ok(Buffer.byteLength(payload, 'utf8') > 65537);
    fs.writeFileSync(bigCtx, payload, 'utf8');
    const r = T.readIsolatedContextBindings(bigCtx);
    assert.equal(r.ok, false);
    assert.equal(r.reason, 'isolated-context-unbounded');
  } finally { cleanDir(dir); }
});

test('FIX3: context at exactly 65536 bytes accepted, 65537 refused', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'g1-ctxcap-'));
  try {
    const base = JSON.stringify({
      idempotency_key: 'a'.repeat(32),
      prepared_fingerprint: 'b'.repeat(32),
    });
    assert.ok(Buffer.byteLength(base, 'utf8') < 65536);
    const exactPath = path.join(dir, 'exact.json');
    const exact = base + ' '.repeat(65536 - Buffer.byteLength(base, 'utf8'));
    assert.equal(Buffer.byteLength(exact, 'utf8'), 65536);
    fs.writeFileSync(exactPath, exact, 'utf8');
    const rok = T.readIsolatedContextBindings(exactPath);
    assert.equal(rok.ok, true);
    assert.equal(rok.idempotencyKey, 'a'.repeat(32));
    const overPath = path.join(dir, 'over.json');
    const over = exact + ' ';
    assert.equal(Buffer.byteLength(over, 'utf8'), 65537);
    fs.writeFileSync(overPath, over, 'utf8');
    const rbad = T.readIsolatedContextBindings(overPath);
    assert.equal(rbad.ok, false);
    assert.equal(rbad.reason, 'isolated-context-unbounded');
  } finally { cleanDir(dir); }
});

test('R4b: measureIsolatedRequestBytes is a lower bound in bytes', () => {
  const small = T.measureIsolatedRequestBytes({
    sessionId: 'ses-01', messageId: 'msg-01', callId: 'call-01',
    caller: 'planner', target: 'coder', args: { prompt: 'hi' },
  });
  assert.ok(small > 0 && small < 1000);
  const big = T.measureIsolatedRequestBytes({
    sessionId: 'ses-01', messageId: 'msg-01', callId: 'call-01',
    caller: 'planner', target: 'coder', args: { note: 'x'.repeat(70000) },
  });
  assert.ok(big > 65536);
  const circular = { a: 'x' };
  circular.self = circular;
  // Circular graphs refuse either by item cap (-1) or by byte total
  // crossing the cap first; both paths deny without serializing.
  const circResult = T.measureIsolatedRequestBytes({
    sessionId: 's', messageId: 'm', callId: 'c',
    caller: 'p', target: 't', args: circular,
  });
  assert.ok(circResult === -1 || circResult > 65536);
});

// F1-S5 grant projection (deny-only observation, fixture only).
// parse: strict shape, exact keys, authority===false, 32hex-or-empty
// revision, bounded denied list. handler: claim refusal first, then
// projection gates (unevaluated/invalid/absent/denied deny, clear
// abstains, never allow).

function s5Parse(doc) {
  return T.parseIsolatedClaimResponse(JSON.stringify(doc), {
    session_id: 'ses-01',
    message_id: 'msg-01',
    call_id: 'call-01',
    target_agent: 'coder',
    caller_agent: 'planner',
    tool: 'subagent',
    idempotency_key: 'a'.repeat(32),
    prepared_fingerprint: 'b'.repeat(32),
  });
}

test('S5 parse: clear projection accepted', () => {
  const r = s5Parse(goodDoc());
  assert.equal(r.ok, true);
});

test('S5 parse: missing grant_projection refuses', () => {
  const doc = goodDoc();
  delete doc.grant_projection;
  const r = s5Parse(doc);
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'isolated-grant-projection-invalid');
});

test('S5 parse: projection as scalar/array refuses', () => {
  for (const gp of ['x', 7, ['a'], null]) {
    const doc = goodDoc();
    doc.grant_projection = gp;
    const r = s5Parse(doc);
    assert.equal(r.ok, false, JSON.stringify(gp));
    assert.equal(r.reason, 'isolated-grant-projection-invalid');
  }
});

test('S5 parse: extra/missing key in projection refuses', () => {
  const extra = goodDoc();
  extra.grant_projection.extra = 'nope';
  assert.equal(s5Parse(extra).reason, 'isolated-grant-projection-invalid');
  const missing = goodDoc();
  delete missing.grant_projection.denied;
  assert.equal(s5Parse(missing).reason, 'isolated-grant-projection-invalid');
});

test('S5 parse: __proto__ key in projection refuses', () => {
  const doc = goodDoc();
  const raw = JSON.stringify(doc).replace(
    '"grant_projection":{',
    '"grant_projection":{"__proto__":{"x":1},'
  );
  const r = s5Parse(JSON.parse(raw));
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'isolated-grant-projection-invalid');
});

test('S5 parse: authority true/missing refuses, false passes', () => {
  const t = goodDoc();
  t.grant_projection.authority = true;
  assert.equal(s5Parse(t).reason, 'isolated-grant-projection-invalid');
  const m = goodDoc();
  delete m.grant_projection.authority;
  assert.equal(s5Parse(m).reason, 'isolated-grant-projection-invalid');
});

test('S5 parse: ok non-boolean refuses', () => {
  const doc = goodDoc();
  doc.grant_projection.ok = 1;
  assert.equal(s5Parse(doc).reason, 'isolated-grant-projection-invalid');
});

test('S5 parse: source_revision 32hex or empty accepted, else refused', () => {
  const empty = goodDoc();
  empty.grant_projection = {
    ok: false, source_revision: '', denied: [],
    reason: 'grant-source-not-evaluated', authority: false,
  };
  assert.equal(s5Parse(empty).ok, true);
  for (const bad of ['ZZZ', 'c'.repeat(31), 'c'.repeat(33), 'C'.repeat(32), 7, ['c'.repeat(32)]]) {
    const doc = goodDoc();
    doc.grant_projection.source_revision = bad;
    const r = s5Parse(doc);
    assert.equal(r.ok, false, JSON.stringify(bad));
    assert.equal(r.reason, 'isolated-grant-projection-invalid');
  }
});

test('S5 parse: reason bounds enforced', () => {
  const emptyReason = goodDoc();
  emptyReason.grant_projection.reason = '';
  assert.equal(s5Parse(emptyReason).reason, 'isolated-grant-projection-invalid');
  const longReason = goodDoc();
  longReason.grant_projection.reason = 'x'.repeat(129);
  assert.equal(s5Parse(longReason).reason, 'isolated-grant-projection-invalid');
  const numReason = goodDoc();
  numReason.grant_projection.reason = 7;
  assert.equal(s5Parse(numReason).reason, 'isolated-grant-projection-invalid');
});

test('S5 parse: denied must be a bounded array of {grant, reason}', () => {
  const notArray = goodDoc();
  notArray.grant_projection.denied = 'fs.read';
  assert.equal(s5Parse(notArray).reason, 'isolated-grant-projection-invalid');
  const big = goodDoc();
  big.grant_projection.denied = [];
  for (let i = 0; i < 65; i++) big.grant_projection.denied.push({ grant: 'g' + i, reason: 'grant-not-effective' });
  assert.equal(s5Parse(big).reason, 'isolated-grant-projection-invalid');
  const cases = [
    { grant: 'fs.read' },
    { reason: 'grant-not-effective' },
    { grant: 'fs.read', reason: 'grant-not-effective', extra: 1 },
    { grant: 7, reason: 'grant-not-effective' },
    { grant: '', reason: 'grant-not-effective' },
    { grant: 'x'.repeat(129), reason: 'grant-not-effective' },
    { grant: 'fs.read', reason: '' },
    { grant: 'fs.read', reason: 'x'.repeat(65) },
    { grant: 'fs.read', reason: 7 },
    'nope',
  ];
  for (const entry of cases) {
    const doc = goodDoc();
    doc.grant_projection.denied = [entry];
    const r = s5Parse(doc);
    assert.equal(r.ok, false, JSON.stringify(entry));
    assert.equal(r.reason, 'isolated-grant-projection-invalid');
  }
});

test('S5 parse: denied one-element array shape enforced (no unroll hazard)', () => {
  const doc = goodDoc();
  doc.grant_projection.denied = [{ grant: 'fs.read', reason: 'grant-not-effective' }];
  assert.equal(s5Parse(doc).ok, true);
});

test('S5 handler: clear projection abstains (S1 behavior, never allow)', async () => {
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(goodDoc()))));
  assert.equal(await handler(goodInput()), undefined);
  assert.equal(calls.length, 1);
});

test('S5 handler: denied projection denies isolated-grant-denied', async () => {
  const doc = goodDoc();
  doc.grant_projection = {
    ok: true, source_revision: 'c'.repeat(32),
    denied: [{ grant: 'fs.read', reason: 'grant-not-effective' }],
    reason: 'grant-projection-denied', authority: false,
  };
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-grant-denied/);
});

test('S5 handler: unevaluated projection denies with sanitized reason', async () => {
  const doc = goodDoc();
  doc.ok = true;
  doc.claimed = true;
  doc.grant_projection = {
    ok: false, source_revision: '', denied: [],
    reason: 'grant-source-not-evaluated', authority: false,
  };
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-grant-projection-grant-source-not-evaluated/);
});

test('S5 handler: claim refusal wins over projection (order)', async () => {
  const doc = goodDoc();
  doc.ok = false;
  doc.claimed = false;
  doc.reason = 'claim-already-consumed';
  doc.grant_projection = {
    ok: false, source_revision: '', denied: [],
    reason: 'grant-source-not-evaluated', authority: false,
  };
  const calls = [];
  const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
  await assert.rejects(handler(goodInput()), /isolated-claim-refused-claim-already-consumed/);
});

test('S5 handler: missing/invalid projection denies (never abstains)', async () => {
  const missing = goodDoc();
  delete missing.grant_projection;
  const calls = [];
  await assert.rejects(
    makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(missing))))(goodInput()),
    /isolated-grant-projection-invalid/
  );
  const forged = goodDoc();
  forged.grant_projection.authority = true;
  const calls2 = [];
  await assert.rejects(
    makeHandler(baseCfg(), stubSpawn(calls2, successScript(JSON.stringify(forged))))(goodInput()),
    /isolated-grant-projection-invalid/
  );
});

test('S5 handler: never returns allow across projection outcomes', async () => {
  const docs = [
    goodDoc(),
    (() => { const d = goodDoc(); d.grant_projection.denied = [{ grant: 'x', reason: 'grant-not-effective' }]; d.grant_projection.reason = 'grant-projection-denied'; return d; })(),
    (() => { const d = goodDoc(); d.grant_projection.ok = false; d.grant_projection.reason = 'grant-source-unavailable'; return d; })(),
    (() => { const d = goodDoc(); d.ok = false; d.claimed = false; d.reason = 'claim-fingerprint-mismatch'; return d; })(),
  ];
  for (const doc of docs) {
    const calls = [];
    const handler = makeHandler(baseCfg(), stubSpawn(calls, successScript(JSON.stringify(doc))));
    let threw = false;
    let out = null;
    try { out = await handler(goodInput()); } catch (e) {
      threw = true;
      assert.ok(e instanceof Error);
      assert.match(e.message, /^g1-isolated-claim denied: [a-z0-9_-]{1,64}$/);
      assert.equal(e.code, 'G1_ISOLATED_CLAIM_DENY');
    }
    if (threw) continue;
    assert.equal(out, undefined);
  }
});

test('S5 regression: S1 suite still passes with projection in shape', async () => {
  // The positive-claim, authority-pin, binding and coercion tests above
  // already run against goodDoc() WITH grant_projection; this pins the
  // 18-key exact shape explicitly.
  const r = s5Parse(goodDoc());
  assert.equal(r.ok, true);
  assert.equal(Object.keys(r.doc).length, 18);
  assert.deepEqual(Object.keys(r.doc.grant_projection).sort(), ['authority', 'denied', 'ok', 'reason', 'source_revision']);
});
