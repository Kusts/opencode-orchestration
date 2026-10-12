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
 */
function readInvocation(input) {
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
      if (permission === null || typeof permission.hook !== 'function') {
        return;
      }
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
    } catch (error) {
      // Setup failure is silent: without the gate the PowerShell-side
      // admission lifecycle remains the authority for the covered surface.
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
};
