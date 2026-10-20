// G1-B (additive): deny-by-default admission gate for the native subagent
// dispatch surface.
//
// WHY JS and not .ts: the versioned plugin layout in this repo
// (plugins/orchestration-enforcement.ts + plugins/dist bundle + sha256 +
// scripts/ci/typecheck-plugin.ps1) is a BUILD pipeline. This file is the
// opposite on purpose: a minimal, dependency-free, zero-build module that
// mirrors the PowerShell decision function `Test-NDAdmissionDecision`
// (scripts/v3/lib/OrchestrationNativeDispatch.ps1) one-for-one. Keeping it
// out of the bundle keeps the existing typecheck/bundle contract
// untouched, and any future move to .ts must re-run that pipeline.
//
// CONTRACT (honest limits):
//   * The admission file is a DURABLE artifact written by CLAIM under the
//     receipt locks (<ReceiptDir>/<goal-hash>/admission/<key>.admission.json).
//     The host never invents it and the model text never creates it.
//   * Location is EXTERNALLY supplied via the env var
//     OPENCODE_G1_ADMISSION_FILE (absolute path, regular file). The plugin
//     never derives the goal hash itself and never trusts a path carried by
//     the tool input: a model-supplied path would be forgeable.
//   * Durable CLAIM receipt (optional, via OPENCODE_G1_RECEIPT_FILE):
//     when set, the receipt must exist with phase exactly 'claimed' AND
//     bound to the same dispatch (idempotency_key + goal_id match the
//     admission) - a receipt of another dispatch still 'claimed' cannot
//     sustain a forged/surviving admission. The admission is written
//     only AFTER the durable CLAIM commit, so the file alone never
//     authorizes; after SETTLE the phase is 'settled' and replay denies.
//     Env unset = admission-only mode (weaker, documented residual,
//     never claimed as enforcement).
//   * Optional identity: OPENCODE_G1_EXPECTED_OWNER (owner fencing),
//     OPENCODE_G1_EXPECTED_GENERATION (generation floor, 0 = unset).
//   * DENY-BY-DEFAULT: every doubt (missing/expired/torn file, unknown
//     field, unreadable env, symlink, oversized file, exception) denies.
//     The ONLY allow is a live admission whose (session, call, agent)
//     tuple matches the invocation and whose fencing is still valid.
//   * Residual (documented, not claimed): this gate covers the
//     model-callable `subagent` surface only. A DIRECT shell/REST call
//     does not pass through permission.evaluate, so it is NOT covered by
//     this file; the PowerShell lifecycle governs creation/removal of the
//     admission file, NOT invocation outside the tool. Whoever can write
//     the admission file can forge authorization - full closure needs
//     host-side interception of all native entries plus artifacts
//     unreadable by the Planner (upstream dependency).

/**
 * @param {string} reason
 * @returns {{ allow: boolean, reason: string }}
 */
function deny(reason) {
  return { allow: false, reason: String(reason || 'admission-denied') };
}

/**
 * @param {unknown} value
 * @returns {string}
 */
function asString(value) {
  if (typeof value !== 'string') return '';
  return value.trim();
}

/**
 * @param {unknown} value
 * @returns {boolean}
 */
function isPlainObject(value) {
  return (
    value !== null &&
    typeof value === 'object' &&
    !Array.isArray(value)
  );
}

/**
 * @param {unknown} value
 * @returns {boolean}
 */
function looksLikeIsoInstant(value) {
  const text = asString(value);
  if (text.length === 0) return true;
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(text);
}

/**
 * Mirror of Test-NDAdmissionDecision (fail-closed, same reasons).
 *
 * @param {unknown} admission parsed admission record
 * @param {{ goalId?: string, sessionId?: string, callId?: string, agent?: string,
 *           model?: string, provider?: string, expectedGeneration?: number,
 *           now?: Date }} ctx
 * @returns {{ allow: boolean, reason: string }}
 */
function decide(admission, ctx) {
  if (!isPlainObject(admission)) return deny('admission-shape-invalid');

  const key = asString(admission.idempotency_key).toLowerCase();
  if (!/^[a-f0-9]{32}$/.test(key)) return deny('admission-shape-invalid');

  const session = asString(admission.session_id);
  const call = asString(admission.call_id);
  const agent = asString(admission.agent);
  if (session === '' || call === '' || agent === '') {
    return deny('admission-shape-invalid');
  }

  const generation = admission.generation;
  if (typeof generation !== 'number' || !Number.isInteger(generation) || generation < 1) {
    return deny('admission-shape-invalid');
  }

  const fencing = admission.fencing;
  if (!isPlainObject(fencing) || typeof fencing.ok !== 'boolean' || fencing.ok !== true) {
    return deny('admission-fencing-invalid');
  }

  // Snapshot de goal gravado no CLAIM: fora de ACTIVE, nega. Residual
  // honesto: isto confere o estado REGISTRADO, nao o goal vivo; takeover
  // apos o CLAIM exige leitura do kernel no evaluate (fora do alcance).
  const fenceGoalState = asString(fencing.goal_state).toUpperCase();
  if (fenceGoalState !== 'ACTIVE') {
    return deny('admission-goal-not-active');
  }
  const expectedOwner = asString(ctx.expectedOwner);
  if (expectedOwner !== '' && asString(fencing.owner) !== expectedOwner) {
    return deny('admission-owner-mismatch');
  }

  if (!looksLikeIsoInstant(admission.expires_at_utc)) {
    return deny('admission-shape-invalid');
  }
  const expiresAt = Date.parse(asString(admission.expires_at_utc));
  if (isNaN(expiresAt)) return deny('admission-shape-invalid');
  const now = ctx.now instanceof Date ? ctx.now.getTime() : Date.now();
  if (now > expiresAt) return deny('admission-expired');

  if (asString(admission.goal_id) !== asString(ctx.goalId)) {
    return deny('admission-goal-mismatch');
  }
  if (session !== asString(ctx.sessionId)) return deny('admission-session-mismatch');
  if (call !== asString(ctx.callId)) return deny('admission-call-mismatch');
  if (agent !== asString(ctx.agent)) return deny('admission-agent-mismatch');

  const expectedGeneration = Number(ctx.expectedGeneration || 0);
  if (expectedGeneration > 0 && generation < expectedGeneration) {
    return deny('admission-generation-stale');
  }

  // Restricao vazia/ausente = sem restricao (paridade com o PowerShell).
  // Restricao preenchida com identidade da invocacao vazia = deny
  // fail-closed: omitir model/provider nao contorna restricao gravada.
  // Residual: a identidade vem dos args/metadata da chamada, nao do
  // modelo efetivamente resolvido pelo host.
  const allowedModel = asString(admission.allowed_model);
  const model = asString(ctx.model);
  if (allowedModel !== '') {
    if (model === '') return deny('admission-model-not-authorized');
    if (allowedModel !== model) return deny('admission-model-not-authorized');
  }
  const allowedProvider = asString(admission.allowed_provider);
  const provider = asString(ctx.provider);
  if (allowedProvider !== '') {
    if (provider === '') return deny('admission-provider-not-authorized');
    if (allowedProvider !== provider) return deny('admission-provider-not-authorized');
  }

  return { allow: true, reason: '' };
}

/**
 * Bounded, regular-file-only reader. Symlinks, directories, oversized or
 * unreadable entries deny.
 *
 * @param {string} absolutePath
 * @returns {{ ok: boolean, admission?: unknown, reason: string }}
 */
function readAdmissionFile(absolutePath) {
  const fs = require('node:fs');
  const path = require('node:path');
  if (typeof absolutePath !== 'string' || absolutePath.trim() === '') {
    return { ok: false, reason: 'admission-unconfigured' };
  }
  const resolved = path.resolve(absolutePath.trim());
  if (!path.isAbsolute(resolved)) return { ok: false, reason: 'admission-unconfigured' };
  let stats = null;
  try {
    stats = fs.lstatSync(resolved);
  } catch (error) {
    return { ok: false, reason: 'admission-unreadable' };
  }
  if (stats.isSymbolicLink() || !stats.isFile()) {
    return { ok: false, reason: 'admission-not-regular-file' };
  }
  if (stats.size <= 0 || stats.size > 65536) {
    return { ok: false, reason: 'admission-unbounded' };
  }
  let text = '';
  try {
    text = fs.readFileSync(resolved, 'utf8');
  } catch (error) {
    return { ok: false, reason: 'admission-unreadable' };
  }
  if (text.length === 0 || text.length > 65536) {
    return { ok: false, reason: 'admission-unbounded' };
  }
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    return { ok: false, reason: 'admission-malformed' };
  }
  if (!isPlainObject(parsed)) return { ok: false, reason: 'admission-malformed' };
  return { ok: true, admission: parsed, reason: '' };
}

/**
 * Reads the CLAIM receipt phase when OPENCODE_G1_RECEIPT_FILE is set.
 * The admission file alone never authorizes: the durable 'claimed'
 * receipt must exist AND belong to the same dispatch (idempotency_key
 * and goal_id must match the admission). After SETTLE the phase becomes
 * 'settled', which closes post-settlement replay even if the admission
 * file survived. A receipt of ANOTHER dispatch still 'claimed' cannot
 * sustain a forged/surviving admission. Env unset = admission-only mode
 * (weaker, documented residual).
 *
 * @param {string} absolutePath
 * @param {{ key?: string, goalId?: string }} bind
 * @returns {{ ok: boolean, claimed?: boolean, reason: string }}
 */
function readReceiptClaimed(absolutePath, bind) {
  const loaded = readAdmissionFile(absolutePath);
  if (!loaded.ok) return { ok: false, reason: loaded.reason };
  const receipt = loaded.admission;
  if (!isPlainObject(receipt)) return { ok: false, reason: 'receipt-malformed' };
  const phase = asString(receipt.phase).toLowerCase();
  if (phase === '') return { ok: false, reason: 'receipt-malformed' };
  if (phase !== 'claimed') return { ok: true, claimed: false, reason: '' };
  const want = bind && typeof bind === 'object' ? bind : {};
  const rKey = asString(receipt.idempotency_key).toLowerCase();
  const rGoal = asString(receipt.goal_id);
  if (rKey === '' || rGoal === '') return { ok: false, reason: 'receipt-malformed' };
  if (asString(want.key).toLowerCase() !== rKey) return { ok: false, reason: 'receipt-key-mismatch' };
  if (asString(want.goalId) !== rGoal) return { ok: false, reason: 'receipt-goal-mismatch' };
  return { ok: true, claimed: true, reason: '' };
}

/**
 * Pulls the invocation identity out of the permission.evaluate input.
 * Unknown shapes deny (never guess).
 *
 * @param {unknown} input
 * @returns {{ tool: string, sessionId: string, callId: string, agent: string,
 *             model: string, provider: string }}
 */function readInvocation(input) {
  const out = {
    tool: '',
    sessionId: '',
    callId: '',
    agent: '',
    model: '',
    provider: '',
  };
  if (!isPlainObject(input)) return out;
  out.tool = asString(input.tool) || asString(input.toolName) || asString(input.name);
  out.sessionId = asString(input.sessionID) || asString(input.sessionId) || asString(input.session_id);
  out.callId = asString(input.callID) || asString(input.callId) || asString(input.call_id);
  const args = isPlainObject(input.args) ? input.args : (isPlainObject(input.arguments) ? input.arguments : null);
  if (args !== null) {
    out.agent = asString(args.agent) || asString(args.agentName) || asString(args.target_agent);
    out.model = asString(args.model);
    out.provider = asString(args.provider);
  }
  const metadata = isPlainObject(input.metadata) ? input.metadata : null;
  if (metadata !== null) {
    if (out.agent === '') out.agent = asString(metadata.agent);
    if (out.model === '') out.model = asString(metadata.model);
    if (out.provider === '') out.provider = asString(metadata.provider);
  }
  return out;
}

// F1-S1 isolated CLAIM bridge (additive; fixture-only, no production claims).
//
// Enabled ONLY when OPENCODE_G1_ISOLATED_CLAIM is exactly '1'. Outside this
// mode nothing below runs and the permission.evaluate path above behaves as
// before. Inside the mode the plugin registers an additional
// ctx.tool.hook("execute.before") gate that is DENY-ONLY:
//   * for the `subagent` tool it invokes the fixture-owned bridge
//     (native-dispatch-claim.ps1) with shell:false, absolute executable and
//     paths, literal argv and the request on stdin, then lets the call
//     through ONLY by abstaining (returning undefined) after a strict
//     ok:true + claimed:true observation;
//   * every other outcome - missing bridge, hash divergence, timeout,
//     oversized/invalid output, non-zero exit, missing fields, authority
//     pins set, grant projection missing/invalid/denied, unknown input
//     shape - throws a sanitized pre-effect error (fail-closed);
//   * it NEVER returns allow:true, never mutates the input/args, never
//     overrides another hook's denial and never authorizes anything.
//     F1-S5: the bridge observation also carries the deny-only
//     grant_projection (snapshot of the kernel grant intersection over the
//     canonical task grants). The handler denies when the projection is
//     missing/invalid/unevaluated or lists any denied grant; a clear
//     projection abstains exactly like the S1 ok:true + claimed:true path.
//     Refusal order is claim first, projection second.
// Residuals (documented, not claimed): the hook observes the host-provided
// input shape; independent provenance still belongs to the host. Setup with
// incomplete isolated config throws (invalid fixture) instead of silently
// installing nothing like the admission-only path does.
//
// HASH ALGORITHM NOTE: the bridge returns the exact canonical
// call_binding_material and the plugin recomputes
// sha256(material).slice(0,32) with node crypto (a pure function, not a
// duplication of CLAIM rules). If Get-NativeDispatchHash32 ever changes
// algorithm, the suites break loudly by design.
//
// EXPLICIT LIMITATIONS (fixture-only, no production claims):
//   * Absolute paths are NOT confinement: links/junctions in the path are
//     followed by IO; ownership of the fixture tree belongs to the
//     operator, outside this file.
//   * No signature or integrity check exists for the bridge script, the
//     shell executable or the dot-sourced libraries: a planted file runs
//     with the identity of the host process. The bridge file is verified
//     at setup time (regular file, bounded size); a setup throw never
//     proves the host will refuse a dispatch if it ignores the failure
//     or loads this plugin late.
//   * Context and authorization files do not authenticate origin: whoever
//     can write them forges the request. They require ownership external
//     to the agent.
//   * The bridge never writes an admission file: it consumes the durable
//     receipt and returns an observation only; this hook abstains after a
//     strict ok:true + claimed:true and never authorizes anything itself.

/**
 * @param {unknown} value
 * @returns {string}
 */
function sanitizeIsolatedCode(value) {
  const t = asString(value).toLowerCase();
  let out = '';
  for (let i = 0; i < t.length && out.length < 64; i++) {
    const c = t[i];
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c === '-' || c === '_') out += c;
    else out += '-';
  }
  if (out === '') return 'unknown';
  return out;
}

/**
 * @param {string} reason
 * @returns {Error}
 */
function isolatedDeny(reason) {
  const err = new Error('g1-isolated-claim denied: ' + sanitizeIsolatedCode(reason));
  try { err.code = 'G1_ISOLATED_CLAIM_DENY'; } catch (ignored) {}
  return err;
}

/**
 * @param {unknown} env
 * @returns {boolean}
 */
function isIsolatedClaimEnabled(env) {
  try {
    if (!env || typeof env !== 'object') return false;
    return asString(env.OPENCODE_G1_ISOLATED_CLAIM) === '1';
  } catch (ignored) {
    return false;
  }
}

/**
 * Reads the fixture-owned isolated bridge config. No defaults for
 * executables or paths; the timeout defaults to 10000 ms.
 *
 * @param {unknown} env
 * @returns {{ ok: boolean, reason: string, bridge?: string, context?: string,
 *             shell?: string, timeoutMs?: number }}
 */
function readIsolatedClaimConfig(env) {
  const e = (env && typeof env === 'object') ? env : {};
  const bridge = asString(e.OPENCODE_G1_CLAIM_BRIDGE);
  const context = asString(e.OPENCODE_G1_CLAIM_CONTEXT);
  const shell = asString(e.OPENCODE_G1_CLAIM_SHELL);
  const timeoutRaw = asString(e.OPENCODE_G1_CLAIM_TIMEOUT_MS);
  if (bridge === '' || context === '' || shell === '') {
    return { ok: false, reason: 'isolated-config-incomplete' };
  }
  let abs = null;
  try { abs = require('node:path'); } catch (ignored) { abs = null; }
  if (abs === null || !abs.isAbsolute(bridge) || !abs.isAbsolute(context) || !abs.isAbsolute(shell)) {
    return { ok: false, reason: 'isolated-config-not-absolute' };
  }
  let timeoutMs = 10000;
  if (timeoutRaw !== '') {
    if (!/^[0-9]{1,6}$/.test(timeoutRaw)) return { ok: false, reason: 'isolated-timeout-invalid' };
    timeoutMs = Number(timeoutRaw);
    if (!(timeoutMs >= 1000 && timeoutMs <= 60000)) return { ok: false, reason: 'isolated-timeout-invalid' };
  }
  return { ok: true, reason: '', bridge: bridge, context: context, shell: shell, timeoutMs: timeoutMs };
}

/**
 * Fail-fast fixture check: bridge + context must be bounded regular files
 * (never symlinks); the shell must exist as a file.
 *
 * @param {{ bridge: string, context: string, shell: string }} cfg
 */
function assertIsolatedBridgeFiles(cfg) {
  const fs = require('node:fs');
  const bounded = [cfg.bridge];
  for (const p of bounded) {
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink() || !st.isFile()) {
      throw new Error('g1-isolated-claim invalid fixture: isolated-bridge-not-regular-file');
    }
    if (st.size <= 0 || st.size > 65536) {
      throw new Error('g1-isolated-claim invalid fixture: isolated-bridge-unbounded');
    }
  }
  // The context file is only checked for regular-file shape here; its
  // byte cap is enforced by the descriptor-limited read in
  // readIsolatedContextBindings (R4b), never by a stat size alone.
  const ctxStat = fs.lstatSync(cfg.context);
  if (ctxStat.isSymbolicLink() || !ctxStat.isFile()) {
    throw new Error('g1-isolated-claim invalid fixture: isolated-bridge-not-regular-file');
  }
  const shellStat = fs.statSync(cfg.shell);
  if (!shellStat.isFile()) {
    throw new Error('g1-isolated-claim invalid fixture: isolated-shell-not-regular-file');
  }
}

/**
 * Rebuilds the exact canonical call material the bridge hashes (R1b).
 * Mirrors the $cfpMaterial composition in native-dispatch-claim.ps1:
 * 'ndcall1;' + name:length:value; fields, where length counts UTF-16
 * code units (PowerShell String.Length and JS String.length agree).
 * KEEP IN SYNC WITH THE BRIDGE: if Get-NativeDispatchHash32 ever
 * changes algorithm, update both sides together; the suites break
 * loudly by design.
 *
 * @param {{ sessionId: string, messageId: string, callId: string,
 *             caller: string, target: string, key: string }} parts
 * @returns {string}
 */
function buildIsolatedCallMaterial(parts) {
  const field = (name, value) => name + ':' + String(value).length + ':' + String(value) + ';';
  return 'ndcall1;'
    + field('session', parts.sessionId)
    + field('message', parts.messageId)
    + field('call', parts.callId)
    + field('caller', parts.caller)
    + field('target', parts.target)
    + field('key', parts.key);
}

/**
 * Reads the execute.before identity for the isolated bridge. Unknown or
 * malformed shapes refuse (never guess); the caller denies.
 *
 * @param {unknown} input
 * @returns {{ ok: boolean, reason: string, tool?: string, sessionId?: string,
 *             messageId?: string, callId?: string, caller?: string,
 *             target?: string, args?: unknown }}
 */
function readIsolatedInvocation(input) {
  if (!isPlainObject(input)) return { ok: false, reason: 'isolated-input-unknown' };
  const tool = asString(input.tool) || asString(input.toolName) || asString(input.name);
  const sessionId = asString(input.sessionID) || asString(input.sessionId) || asString(input.session_id);
  const messageId = asString(input.messageID) || asString(input.messageId) || asString(input.message_id);
  const callId = asString(input.callID) || asString(input.callId) || asString(input.call_id);
  const metadata = isPlainObject(input.metadata) ? input.metadata : null;
  let caller = asString(input.callerAgent) || asString(input.caller) || asString(input.sourceAgent) || asString(input.parentAgent);
  if (caller === '' && metadata !== null) {
    caller = asString(metadata.callerAgent) || asString(metadata.caller);
  }
  const args = isPlainObject(input.args) ? input.args : (isPlainObject(input.arguments) ? input.arguments : null);
  if (args === null) return { ok: false, reason: 'isolated-args-unknown' };
  let target = asString(args.agent) || asString(args.agentName) || asString(args.target_agent);
  if (target === '' && metadata !== null) target = asString(metadata.agent);
  if (tool === '') return { ok: false, reason: 'isolated-tool-unknown' };
  if (sessionId === '' || messageId === '' || callId === '') {
    return { ok: false, reason: 'isolated-identity-unknown' };
  }
  if (caller === '' || target === '') return { ok: false, reason: 'isolated-agent-unknown' };
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(sessionId)) return { ok: false, reason: 'isolated-session-invalid' };
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(messageId)) return { ok: false, reason: 'isolated-message-invalid' };
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(callId)) return { ok: false, reason: 'isolated-call-invalid' };
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(caller)) return { ok: false, reason: 'isolated-caller-invalid' };
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(target)) return { ok: false, reason: 'isolated-target-invalid' };
  return { ok: true, reason: '', tool: tool, sessionId: sessionId, messageId: messageId, callId: callId, caller: caller, target: target, args: args };
}

/**
 * Reads ONLY the tool name for the R2 fast path. Returns '' when the
 * tool cannot be recognized (the caller then denies fail-closed).
 *
 * @param {unknown} input
 * @returns {string}
 */
function extractIsolatedToolName(input) {
  try {
    if (!isPlainObject(input)) return '';
    return asString(input.tool) || asString(input.toolName) || asString(input.name);
  } catch (ignored) {
    return '';
  }
}

/**
 * Reads the expected CLAIM bindings from the fixture context file at
 * setup time. Bounded read, strict UTF-8, exact JSON string types.
 *
 * @param {string} contextPath
 * @returns {{ ok: boolean, reason: string, idempotencyKey?: string,
 *             preparedFingerprint?: string }}
 */
function readIsolatedContextBindings(contextPath) {
  try {
    const fs = require('node:fs');
    const st = fs.lstatSync(contextPath);
    if (st.isSymbolicLink() || !st.isFile()) {
      return { ok: false, reason: 'isolated-context-not-regular-file' };
    }
    // R4b/FIX3: descriptor-limited read. Each read requests at most
    // Math.min(8192, 65537 - total) bytes - the sentinel is no more than
    // ONE byte past the 65536 cap - and the loop refuses as soon as
    // total exceeds 65536, without reading the rest. Only the bytes
    // actually read are used; decoding is fatal UTF-8.
    let fd = -1;
    try {
      fd = fs.openSync(contextPath, 'r');
    } catch (ignored) {
      return { ok: false, reason: 'isolated-context-unreadable' };
    }
    const chunks = [];
    let total = 0;
    let readFailed = false;
    try {
      const buf = Buffer.alloc(8192);
      while (true) {
        let n = 0;
        try {
          n = fs.readSync(fd, buf, 0, Math.min(8192, 65537 - total), null);
        } catch (ignored) {
          readFailed = true;
          break;
        }
        if (n <= 0) break;
        total += n;
        if (total > 65536) {
          return { ok: false, reason: 'isolated-context-unbounded' };
        }
        chunks.push(Buffer.from(buf.subarray(0, n)));
      }
    } finally {
      try { fs.closeSync(fd); } catch (ignored) {}
    }
    if (readFailed) return { ok: false, reason: 'isolated-context-unreadable' };
    const raw = Buffer.concat(chunks);
    if (raw.length === 0) return { ok: false, reason: 'isolated-context-unreadable' };
    let text = '';
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(raw);
    } catch (ignored) {
      return { ok: false, reason: 'isolated-context-invalid-encoding' };
    }
    let doc = null;
    try {
      doc = JSON.parse(text);
    } catch (ignored) {
      return { ok: false, reason: 'isolated-context-malformed' };
    }
    if (!isPlainObject(doc)) return { ok: false, reason: 'isolated-context-malformed' };
    const key = doc.idempotency_key;
    const fp = doc.prepared_fingerprint;
    // R1: rejection of coercion - each hash must be typeof string, never
    // String() of something else and never a one-element array.
    if (typeof key !== 'string' || typeof fp !== 'string') {
      return { ok: false, reason: 'isolated-context-binding-type' };
    }
    if (!/^[a-f0-9]{32}$/.test(key) || !/^[a-f0-9]{32}$/.test(fp)) {
      return { ok: false, reason: 'isolated-context-binding-shape' };
    }
    return { ok: true, reason: '', idempotencyKey: key, preparedFingerprint: fp };
  } catch (ignored) {
    return { ok: false, reason: 'isolated-context-unreadable' };
  }
}

/**
 * Runs the fixture bridge as a subprocess: absolute executable, literal
 * argv (SEC2: -NoProfile -NonInteractive -File, exactly like the harness
 * invokes it), shell:false, request JSON on stdin, bounded stdout decoded
 * once with strict UTF-8 (R4: byte counting, no split-multibyte hazard).
 * Never resolves with authority; every transport anomaly resolves ok:false
 * (the caller denies fail-closed).
 *
 * @param {{ bridge: string, context: string, shell: string, timeoutMs: number }} cfg
 * @param {string} payload
 * @param {{ spawnFn?: Function }} deps
 * @returns {Promise<{ ok: boolean, reason: string, stdout?: string }>}
 */
function runIsolatedClaimBridge(cfg, payload, deps) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    let spawnFn = null;
    if (deps && typeof deps.spawnFn === 'function') spawnFn = deps.spawnFn;
    else {
      try { spawnFn = require('node:child_process').spawn; } catch (ignored) { spawnFn = null; }
    }
    if (typeof spawnFn !== 'function') {
      finish({ ok: false, reason: 'isolated-bridge-spawn-unavailable' });
      return;
    }
    let child = null;
    try {
      child = spawnFn(cfg.shell, ['-NoProfile', '-NonInteractive', '-File', cfg.bridge, '-Action', 'claim', '-ContextFile', cfg.context], { shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (ignored) {
      child = null;
    }
    if (!child || !child.stdin || !child.stdout || !child.stderr) {
      finish({ ok: false, reason: 'isolated-bridge-spawn-failed' });
      return;
    }
    // R4: accumulate raw BYTES and count bytes, never characters. Chunks
    // arrive as Buffers (or stub strings, normalized to Buffers) and are
    // decoded exactly ONCE at close with a fatal decoder, so a multibyte
    // character split across chunks decodes correctly and invalid UTF-8
    // refuses instead of substituting.
    const outChunks = [];
    let outBytes = 0;
    let done = false;
    let timer = null;
    try {
      timer = setTimeout(() => {
        done = true;
        try { child.kill(); } catch (ignored) {}
        finish({ ok: false, reason: 'isolated-bridge-timeout' });
      }, cfg.timeoutMs);
    } catch (ignored) {
      timer = null;
    }
    const clearTimer = () => {
      try { if (timer !== null) clearTimeout(timer); } catch (ignored) {}
      timer = null;
    };
    try { child.stderr.on('data', () => {}); } catch (ignored) {}
    try {
      child.stdout.on('data', (chunk) => {
        if (done) return;
        try {
          const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk), 'utf8');
          outBytes += buf.length;
          if (outBytes > 65536) {
            done = true;
            try { child.kill(); } catch (ignored) {}
            clearTimer();
            finish({ ok: false, reason: 'isolated-bridge-output-unbounded' });
            return;
          }
          outChunks.push(buf);
        } catch (ignored) {}
      });
    } catch (ignored) {}
    try {
      child.on('error', () => {
        if (done) return;
        done = true;
        clearTimer();
        finish({ ok: false, reason: 'isolated-bridge-spawn-failed' });
      });
    } catch (ignored) {}
    try {
      child.on('close', (code) => {
        if (done) return;
        done = true;
        clearTimer();
        if (code !== 0) {
          finish({ ok: false, reason: 'isolated-bridge-exit-refused' });
          return;
        }
        let stdout = '';
        try {
          stdout = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(outChunks));
        } catch (ignored) {
          finish({ ok: false, reason: 'isolated-bridge-output-invalid' });
          return;
        }
        finish({ ok: true, reason: '', stdout: stdout });
      });
    } catch (ignored) {}
    try {
      child.stdin.on('error', () => {
        if (done) return;
        done = true;
        clearTimer();
        try { child.kill(); } catch (ignored) {}
        finish({ ok: false, reason: 'isolated-bridge-stdin-failed' });
      });
    } catch (ignored) {}
    try {
      child.stdin.write(payload);
      child.stdin.end();
    } catch (ignored) {
      if (done) return;
      done = true;
      clearTimer();
      finish({ ok: false, reason: 'isolated-bridge-stdin-failed' });
    }
  });
}

/**
 * Strict parse of the bridge observation (R1). Requires the exact field
 * set with exact types - each hash must be typeof string (no String()
 * coercion, no one-element arrays) and match 32hex - the echoed binding
 * (identity + target + tool), false authority pins, the response hashes
 * equal to the setup-time context bindings, and the call_fingerprint
 * recomputed locally from call_binding_material. Anything else is an
 * uncovered condition (the caller denies).
 *
 * @param {unknown} stdout
 * @param {{ session_id: string, message_id: string, call_id: string,
 *             target_agent: string, tool: string, caller_agent?: string,
 *             idempotency_key?: string, prepared_fingerprint?: string }} binding
 * @returns {{ ok: boolean, reason: string, doc?: unknown }}
 */
function parseIsolatedClaimResponse(stdout, binding) {
  if (typeof stdout !== 'string' || stdout.length === 0 || stdout.length > 65536) {
    return { ok: false, reason: 'isolated-bridge-output-unbounded' };
  }
  let doc = null;
  try {
    doc = JSON.parse(stdout);
  } catch (ignored) {
    return { ok: false, reason: 'isolated-bridge-output-invalid' };
  }
  if (!isPlainObject(doc)) return { ok: false, reason: 'isolated-bridge-output-invalid' };
  // F1-S5: a missing projection is a projection error, not a generic
  // shape error (the caller denies on it either way).
  if (!Object.prototype.hasOwnProperty.call(doc, 'grant_projection')) {
    return { ok: false, reason: 'isolated-grant-projection-invalid' };
  }
  const want = ['schema_version', 'operation', 'ok', 'claimed', 'reason', 'idempotency_key', 'prepared_fingerprint', 'session_id', 'message_id', 'call_id', 'call_fingerprint', 'call_binding_material', 'target_agent', 'tool', 'grant_projection', 'grants_authority', 'verified_pass', 'done_approved'];
  const keys = Object.keys(doc);
  if (keys.length !== want.length) return { ok: false, reason: 'isolated-bridge-output-shape' };
  for (const k of want) {
    if (!Object.prototype.hasOwnProperty.call(doc, k)) {
      return { ok: false, reason: 'isolated-bridge-output-shape' };
    }
  }
  if (doc.schema_version !== 1) return { ok: false, reason: 'isolated-bridge-output-shape' };
  if (doc.operation !== 'claim') return { ok: false, reason: 'isolated-bridge-output-shape' };
  if (typeof doc.ok !== 'boolean' || typeof doc.claimed !== 'boolean') {
    return { ok: false, reason: 'isolated-bridge-output-shape' };
  }
  if (typeof doc.reason !== 'string') return { ok: false, reason: 'isolated-bridge-output-shape' };
  // R1: reject coercion - typeof must be string BEFORE any shape test.
  if (typeof doc.idempotency_key !== 'string' || typeof doc.prepared_fingerprint !== 'string' || typeof doc.call_fingerprint !== 'string') {
    return { ok: false, reason: 'isolated-bridge-output-shape' };
  }
  if (!/^[a-f0-9]{32}$/.test(doc.idempotency_key)) {
    return { ok: false, reason: 'isolated-bridge-output-shape' };
  }
  if (!/^[a-f0-9]{32}$/.test(doc.prepared_fingerprint)) {
    return { ok: false, reason: 'isolated-bridge-output-shape' };
  }
  if (!/^[a-f0-9]{32}$/.test(doc.call_fingerprint)) {
    return { ok: false, reason: 'isolated-bridge-output-shape' };
  }
  if (typeof doc.call_binding_material !== 'string' || doc.call_binding_material.length === 0 || doc.call_binding_material.length > 4096) {
    return { ok: false, reason: 'isolated-bridge-output-shape' };
  }
  // R1b: the material must BE the canonical serialization of this very
  // request (rebuilt locally from request + context bindings), not just
  // any string whose hash matches. Exact equality BEFORE hash validation.
  if (typeof binding.idempotency_key === 'string' && binding.idempotency_key !== '' && typeof binding.caller_agent === 'string' && binding.caller_agent !== '') {
    const expectedMaterial = buildIsolatedCallMaterial({
      sessionId: binding.session_id,
      messageId: binding.message_id,
      callId: binding.call_id,
      caller: binding.caller_agent,
      target: binding.target_agent,
      key: binding.idempotency_key,
    });
    if (doc.call_binding_material !== expectedMaterial) {
      return { ok: false, reason: 'isolated-material-mismatch' };
    }
  }
  // R1: recompute the fingerprint locally from the returned material with
  // node crypto (pure function; the bridge documents the SHA-256/UTF-8/
  // truncate-32 algorithm next to Get-NativeDispatchHash32).
  let recomputed = '';
  try {
    recomputed = require('node:crypto').createHash('sha256').update(doc.call_binding_material, 'utf8').digest('hex').slice(0, 32);
  } catch (ignored) {
    recomputed = '';
  }
  if (recomputed === '' || recomputed !== doc.call_fingerprint) {
    return { ok: false, reason: 'isolated-call-fingerprint-mismatch' };
  }
  if (doc.grants_authority !== false || doc.verified_pass !== false || doc.done_approved !== false) {
    return { ok: false, reason: 'isolated-authority-pin-violated' };
  }
  // F1-S5 grant projection (deny-only observation, additive): strict shape,
  // exact keys, authority===false, 32hex-or-empty revision, bounded deny
  // list. Any deviation refuses; the caller then denies fail-closed.
  const gp = doc.grant_projection;
  if (!isPlainObject(gp)) return { ok: false, reason: 'isolated-grant-projection-invalid' };
  const gpWant = ['ok', 'source_revision', 'denied', 'reason', 'authority'];
  const gpKeys = Object.keys(gp);
  if (gpKeys.length !== gpWant.length) return { ok: false, reason: 'isolated-grant-projection-invalid' };
  for (const k of gpWant) {
    if (!Object.prototype.hasOwnProperty.call(gp, k)) {
      return { ok: false, reason: 'isolated-grant-projection-invalid' };
    }
  }
  if (typeof gp.ok !== 'boolean') return { ok: false, reason: 'isolated-grant-projection-invalid' };
  if (typeof gp.source_revision !== 'string') return { ok: false, reason: 'isolated-grant-projection-invalid' };
  if (gp.source_revision !== '' && !/^[a-f0-9]{32}$/.test(gp.source_revision)) {
    return { ok: false, reason: 'isolated-grant-projection-invalid' };
  }
  if (typeof gp.reason !== 'string' || gp.reason.length === 0 || gp.reason.length > 128) {
    return { ok: false, reason: 'isolated-grant-projection-invalid' };
  }
  if (gp.authority !== false) return { ok: false, reason: 'isolated-grant-projection-invalid' };
  if (!Array.isArray(gp.denied) || gp.denied.length > 64) {
    return { ok: false, reason: 'isolated-grant-projection-invalid' };
  }
  for (const entry of gp.denied) {
    if (!isPlainObject(entry)) return { ok: false, reason: 'isolated-grant-projection-invalid' };
    const entryKeys = Object.keys(entry);
    if (entryKeys.length !== 2) return { ok: false, reason: 'isolated-grant-projection-invalid' };
    if (!Object.prototype.hasOwnProperty.call(entry, 'grant') || !Object.prototype.hasOwnProperty.call(entry, 'reason')) {
      return { ok: false, reason: 'isolated-grant-projection-invalid' };
    }
    if (typeof entry.grant !== 'string' || entry.grant.length === 0 || entry.grant.length > 128) {
      return { ok: false, reason: 'isolated-grant-projection-invalid' };
    }
    if (typeof entry.reason !== 'string' || entry.reason.length === 0 || entry.reason.length > 64) {
      return { ok: false, reason: 'isolated-grant-projection-invalid' };
    }
  }
  // R1: the response hashes must equal the setup-time context bindings.
  if (typeof binding.idempotency_key === 'string' && binding.idempotency_key !== '' && doc.idempotency_key !== binding.idempotency_key) {
    return { ok: false, reason: 'isolated-key-mismatch' };
  }
  if (typeof binding.prepared_fingerprint === 'string' && binding.prepared_fingerprint !== '' && doc.prepared_fingerprint !== binding.prepared_fingerprint) {
    return { ok: false, reason: 'isolated-fingerprint-mismatch' };
  }
  if (doc.session_id !== binding.session_id || doc.message_id !== binding.message_id || doc.call_id !== binding.call_id) {
    return { ok: false, reason: 'isolated-binding-mismatch' };
  }
  if (typeof doc.target_agent !== 'string' || doc.target_agent !== binding.target_agent) {
    return { ok: false, reason: 'isolated-binding-mismatch' };
  }
  if (typeof doc.tool !== 'string' || doc.tool !== binding.tool) {
    return { ok: false, reason: 'isolated-binding-mismatch' };
  }
  return { ok: true, reason: '', doc: doc };
}

/**
 * Conservative lower-bound byte measure of the request fields WITHOUT
 * serializing anything (R4b bonus). Sums exact UTF-8 bytes of every
 * scalar reached from the args tree; JSON punctuation only grows the
 * real payload, so exceeding the cap here proves oversize. Returns -1
 * for shapes JSON.stringify would drop or for runaway graphs.
 *
 * @param {{ sessionId: string, messageId: string, callId: string,
 *             caller: string, target: string, args: unknown }} inv
 * @returns {number}
 */
function measureIsolatedRequestBytes(inv) {
  try {
    let total = 0;
    total += Buffer.byteLength(String(inv.sessionId), 'utf8');
    total += Buffer.byteLength(String(inv.messageId), 'utf8');
    total += Buffer.byteLength(String(inv.callId), 'utf8');
    total += Buffer.byteLength(String(inv.caller), 'utf8');
    total += Buffer.byteLength(String(inv.target), 'utf8');
    const stack = [inv.args];
    let items = 0;
    while (stack.length > 0) {
      const v = stack.pop();
      if (typeof v === 'string') {
        total += Buffer.byteLength(v, 'utf8');
      } else if (Array.isArray(v)) {
        for (const e of v) stack.push(e);
      } else if (v !== null && typeof v === 'object') {
        for (const k of Object.keys(v)) {
          total += Buffer.byteLength(k, 'utf8');
          stack.push(v[k]);
        }
      } else if (typeof v === 'number' || typeof v === 'boolean' || v === null) {
        total += 0;
      } else {
        return -1;
      }
      items++;
      if (items > 100000) return -1;
      if (total > 65536) return total;
    }
    return total;
  } catch (ignored) {
    return -1;
  }
}

/**
 * Builds the deny-only execute.before handler. R2: the tool name is read
 * FIRST and a recognizably non-subagent tool abstains immediately (no
 * identity read, no spawn). Full identity is validated only on the
 * covered surface. The handler returns undefined (abstain) or throws a
 * sanitized error (refuse pre-effect); it never returns allow:true and
 * never touches the input.
 *
 * EXPLICIT LIMITATIONS: this gate observes the host-provided input and
 * trusts the fixture-owned bridge/context/shell files verified at setup.
 * A planted bridge runs with the host identity; context/authorization
 * files do not authenticate origin. A setup throw never proves the host
 * will refuse if it ignores the failure or loads this plugin late.
 *
 * @param {{ bridge: string, context: string, shell: string, timeoutMs: number,
 *             expectedIdempotencyKey?: string, expectedPreparedFingerprint?: string }} cfg
 * @param {{ spawnFn?: Function }} deps
 * @returns {(input: unknown) => Promise<undefined>}
 */
function makeIsolatedClaimHandler(cfg, deps) {
  const spawnFn = (deps && typeof deps.spawnFn === 'function') ? deps.spawnFn : null;
  return async function isolatedClaimBeforeExecute(input) {
    const toolName = extractIsolatedToolName(input);
    if (toolName === '') throw isolatedDeny('isolated-tool-unknown');
    if (toolName !== 'subagent') return undefined;
    const inv = readIsolatedInvocation(input);
    if (!inv.ok) throw isolatedDeny(inv.reason);
    // R4b bonus: cumulative byte size of the fields BEFORE serializing;
    // refuse past the cap without building the payload string. The
    // post-serialization byteLength check below stays as second barrier.
    const preBytes = measureIsolatedRequestBytes(inv);
    if (preBytes < 0 || preBytes > 65536) {
      throw isolatedDeny('isolated-request-unbounded');
    }
    let payload = '';
    try {
      payload = JSON.stringify({
        schema_version: 1,
        session_id: inv.sessionId,
        message_id: inv.messageId,
        call_id: inv.callId,
        caller_agent: inv.caller,
        target_agent: inv.target,
        tool: 'subagent',
        args: inv.args,
      });
    } catch (ignored) {
      throw isolatedDeny('isolated-args-unserializable');
    }
    // R4: measure serialized BYTES before spawning, never spawn past the
    // cap. Multibyte payloads are bounded by bytes, not characters.
    let payloadBytes = 0;
    try {
      payloadBytes = Buffer.byteLength(payload, 'utf8');
    } catch (ignored) {
      payloadBytes = 0;
    }
    if (payloadBytes === 0 || payloadBytes > 65536) {
      throw isolatedDeny('isolated-request-unbounded');
    }
    const res = await runIsolatedClaimBridge(cfg, payload, { spawnFn: spawnFn });
    if (!res.ok) throw isolatedDeny(res.reason);
    const parsed = parseIsolatedClaimResponse(res.stdout, {
      session_id: inv.sessionId,
      message_id: inv.messageId,
      call_id: inv.callId,
      target_agent: inv.target,
      caller_agent: inv.caller,
      tool: 'subagent',
      idempotency_key: (cfg && typeof cfg.expectedIdempotencyKey === 'string') ? cfg.expectedIdempotencyKey : '',
      prepared_fingerprint: (cfg && typeof cfg.expectedPreparedFingerprint === 'string') ? cfg.expectedPreparedFingerprint : '',
    });
    if (!parsed.ok) throw isolatedDeny(parsed.reason);
    // F1-S5: the claim refusal wins first (existing S1 behavior); then the
    // deny-only grant projection: unevaluated or denied projections refuse,
    // a clear projection abstains (the host permission policy decides; this
    // hook never returns allow:true).
    if (parsed.doc.ok !== true || parsed.doc.claimed !== true) {
      throw isolatedDeny('isolated-claim-refused-' + sanitizeIsolatedCode(parsed.doc.reason));
    }
    const gp = parsed.doc.grant_projection;
    if (!gp || gp.ok !== true) {
      const why = (gp && typeof gp.reason === 'string' && gp.reason !== '') ? gp.reason : 'unknown';
      throw isolatedDeny('isolated-grant-projection-' + sanitizeIsolatedCode(why));
    }
    if (Array.isArray(gp.denied) && gp.denied.length > 0) {
      throw isolatedDeny('isolated-grant-denied');
    }
    return undefined;
  };
}

/**
 * Registers the isolated execute.before gate. Returns true when enabled.
 * Throws on any incomplete setup (invalid fixture, never silent).
 *
 * @param {any} ctx
 * @returns {Promise<boolean>}
 */
async function setupIsolatedClaimBridge(ctx) {
  const env = (typeof process !== 'undefined' && process.env) ? process.env : {};
  if (!isIsolatedClaimEnabled(env)) return false;
  const cfg = readIsolatedClaimConfig(env);
  if (!cfg.ok) {
    throw new Error('g1-isolated-claim invalid fixture: ' + sanitizeIsolatedCode(cfg.reason));
  }
  try {
    assertIsolatedBridgeFiles(cfg);
  } catch (error) {
    throw new Error('g1-isolated-claim invalid fixture: isolated-bridge-files-unavailable');
  }
  // R1: bind the expected hashes at setup time from the fixture context.
  const bindings = readIsolatedContextBindings(cfg.context);
  if (!bindings.ok) {
    throw new Error('g1-isolated-claim invalid fixture: ' + sanitizeIsolatedCode(bindings.reason));
  }
  cfg.expectedIdempotencyKey = bindings.idempotencyKey;
  cfg.expectedPreparedFingerprint = bindings.preparedFingerprint;
  if (!ctx || !ctx.tool || typeof ctx.tool.hook !== 'function') {
    throw new Error('g1-isolated-claim invalid fixture: isolated-tool-hook-unavailable');
  }
  const handler = makeIsolatedClaimHandler(cfg, {});
  await ctx.tool.hook('execute.before', handler);
  return true;
}

/**
 * V2 host plugin shape: { id, setup }. Deny-by-default permission gate.
 * Every failure path denies; nothing throws to the runtime.
 */
const G1DispatchAdmission = {
  id: 'g1-dispatch-admission',
  /**
   * @param {any} ctx
   * @returns {Promise<(() => void) | void>}
   */
  async setup(ctx) {
    try {
      const permission = ctx && ctx.permission ? ctx.permission : null;
      // The permission.evaluate gate below is unchanged: it registers only
      // when the host offers it. No early return here: the F1-S1 isolated
      // tool.hook gate below must still be evaluated.
      if (permission !== null && typeof permission.hook === 'function') {
      permission.hook('evaluate', async (input) => {
        try {
          const inv = readInvocation(input);
          if (inv.tool !== 'subagent') {
            // Outside the covered surface: no opinion, no block.
            return;
          }
          const env = typeof process !== 'undefined' && process.env ? process.env : {};
          const admissionFile = asString(env.OPENCODE_G1_ADMISSION_FILE);
          if (admissionFile === '') return deny('admission-unconfigured');
          const loaded = readAdmissionFile(admissionFile);
          if (!loaded.ok) return deny(loaded.reason);
          // Recibo duravel: sem OPENCODE_G1_RECEIPT_FILE, modo
          // admission-only (residual documentado). Com o recibo
          // configurado, phase precisa ser exatamente 'claimed'.
          const receiptFile = asString(env.OPENCODE_G1_RECEIPT_FILE);
          if (receiptFile !== '') {
            const rc = readReceiptClaimed(receiptFile, {
              key: asString(loaded.admission.idempotency_key),
              goalId: asString(env.OPENCODE_G1_GOAL_ID),
            });
            if (!rc.ok) return deny(rc.reason);
            if (!rc.claimed) return deny('admission-receipt-not-claimed');
          }
          const expectedGeneration = Number(asString(env.OPENCODE_G1_EXPECTED_GENERATION) || 0);
          const verdict = decide(loaded.admission, {
            goalId: asString(env.OPENCODE_G1_GOAL_ID),
            sessionId: inv.sessionId,
            callId: inv.callId,
            agent: inv.agent,
            model: inv.model,
            provider: inv.provider,
            expectedGeneration: isNaN(expectedGeneration) ? 0 : expectedGeneration,
            expectedOwner: asString(env.OPENCODE_G1_EXPECTED_OWNER),
          });
          return verdict;
        } catch (error) {
          return deny('admission-internal-error');
        }
      });
      }
    } catch (error) {
      // Setup failure is silent: without the gate the PowerShell-side
      // admission lifecycle remains the authority for the covered surface.
    }
    // F1-S1 isolated CLAIM bridge (additive). Outside the isolated mode
    // this is a no-op and the behavior above is unchanged. Inside the
    // mode an incomplete setup is an invalid fixture and throws instead
    // of silently installing nothing.
    try {
      await setupIsolatedClaimBridge(ctx);
    } catch (error) {
      let enabled = false;
      try {
        enabled = (typeof process !== 'undefined' && process.env && typeof process.env === 'object') &&
          asString(process.env.OPENCODE_G1_ISOLATED_CLAIM) === '1';
      } catch (ignored) {
        enabled = false;
      }
      if (enabled) throw error;
    }
  },
};

// Exported for parity review: the PowerShell decision function
// `Test-NDAdmissionDecision` (scripts/v3/lib/OrchestrationNativeDispatch.ps1)
// is the canonical implementation, and this `decide` is its mirror. Any
// change to one must be replayed on the other by review (there is no
// automated cross-language harness for this file by design: the versioned
// plugin pipeline that builds .ts stays out of this additive slice).
module.exports = {
  G1DispatchAdmission,
  __g1DispatchAdmissionTest: { decide, readInvocation, readAdmissionFile, readReceiptClaimed, deny },
  __g1IsolatedClaimTest: {
    isIsolatedClaimEnabled,
    readIsolatedClaimConfig,
    readIsolatedInvocation,
    extractIsolatedToolName,
    readIsolatedContextBindings,
    buildIsolatedCallMaterial,
    measureIsolatedRequestBytes,
    sanitizeIsolatedCode,
    parseIsolatedClaimResponse,
    makeIsolatedClaimHandler,
    runIsolatedClaimBridge,
    setupIsolatedClaimBridge,
  },
};
