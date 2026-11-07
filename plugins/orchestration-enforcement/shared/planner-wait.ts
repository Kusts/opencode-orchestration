// shared/planner-wait.ts — PR181 Fatia A adapter logic (PURE).
// Single native custom tool (`orchestration_planner_wait`) that registers
// a Planner ROOT-session binding via Phase 32 CAS plus a GitHub CI/PR
// wait, by spawning the fixture-owned bridge
// scripts/v3/lib/OrchestrationPlannerWaitBridge.ps1.
//
// PURE: relative imports only (./identity for the canonical role lists).
// No node: imports, no runtime-package imports, no dynamic loading.
// Spawn and
// session lookup are injected as dependencies by the V2 adapter, so this
// module stays typecheckable and unit-testable without a host. The V2
// adapter typechecks the tool definition against the current registry pin
// (`ToolInfo`/`ToolContext`/`ToolEditor`); runtime observations remain 2.0.23 only.
// this module only defines the structural shapes those pinned types
// accept (name/input/description/execute, JSON-schema input, text
// content result).
import { PLANNER_AGENTS, WORKER_AGENTS, normalizeAgentName } from "./identity";

export const PLANNER_WAIT_TOOL_NAME = "orchestration_planner_wait";
export const PLANNER_WAIT_OPERATION = "bind-wait";
export const PLANNER_WAIT_SCHEMA_VERSION = 1;
export const PLANNER_WAIT_BRIDGE_MAX_BYTES = 65536;
export const PLANNER_WAIT_DEFAULT_TIMEOUT_MS = 30000;

export interface PlannerWaitBridgeConfig {
  bridge: string;
  shell: string;
  timeoutMs: number;
}

export interface PlannerWaitHostIdentity {
  sessionId: string;
  agent: string;
}

export interface PlannerWaitRequest {
  [key: string]: unknown;
}

// Minimal structural child-process shape (injected; never imported).
export interface PlannerWaitChildStdio {
  write: (chunk: unknown) => boolean;
  end: () => void;
  on: (event: string, cb: (...args: Array<any>) => void) => unknown;
}
export interface PlannerWaitChild {
  stdin?: PlannerWaitChildStdio | null;
  stdout?: { on: (event: string, cb: (...args: Array<any>) => void) => unknown } | null;
  stderr?: { on: (event: string, cb: (...args: Array<any>) => void) => unknown } | null;
  kill: () => unknown;
  on: (event: string, cb: (...args: Array<any>) => void) => unknown;
}
export type PlannerWaitSpawnFn = (
  exe: string,
  argv: Array<string>,
  opts: { shell: false; stdio: ["pipe", "pipe", "pipe"] },
) => PlannerWaitChild | null | undefined;
export type PlannerWaitSessionGet = (id: string) => Promise<unknown>;

function asString(value: unknown): string {
  try {
    if (typeof value !== "string") return "";
    return value.trim();
  } catch {
    return "";
  }
}

function isPlainObject(value: unknown): boolean {
  try {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  } catch {
    return false;
  }
}

export function sanitizePlannerWaitCode(value: unknown): string {
  try {
    const t = asString(value).toLowerCase();
    let out = "";
    for (let i = 0; i < t.length && out.length < 64; i++) {
      const c = t.charAt(i);
      if ((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c === "-" || c === "_") out += c;
      else out += "-";
    }
    if (out === "") return "unknown";
    return out;
  } catch {
    return "unknown";
  }
}

export function denyPlannerWait(reason: string): Error {
  const err = new Error("orchestration_planner_wait denied: " + sanitizePlannerWaitCode(reason));
  try {
    (err as unknown as Record<string, unknown>).code = "PLANNER_WAIT_DENY";
  } catch {
    // Fail-open: code tag is best-effort.
  }
  return err;
}

export type PlannerWaitRole = "planner" | "worker" | "unknown";

export function plannerWaitRoleOf(agent: unknown): PlannerWaitRole {
  try {
    const n = normalizeAgentName(agent);
    if (n === "") return "unknown";
    if (PLANNER_AGENTS.has(n)) return "planner";
    if (WORKER_AGENTS.has(n)) return "worker";
    return "unknown";
  } catch {
    return "unknown";
  }
}

// JSON-schema input: ONLY model-safe registration fields. Storage paths
// (goal_store_dir, tasks_dir, waits_dir, flags_path, repo_root) and
// authority inputs (owner, ownership_generation, lease_owner,
// lease_expires_utc) are NEVER model inputs: paths resolve to kernel
// defaults tied to the bundled library's repo root (plus fixed
// cache/runtime/github-waits), and the owner+generation+lease-expiry derive
// from the stored Goal ownership record with the canonical owner as wait
// lease owner. The host ToolContext
// (sessionID/agent) is the sole identity source; any model-supplied
// session key is refused by validatePlannerWaitArgs.
export const PLANNER_WAIT_INPUT_SCHEMA = {
  type: "object",
  properties: {
    task_id: { type: "string" },
    goal_id: { type: "string" },
    run_id: { type: "string" },
    repository: { type: "string" },
    pr_number: { type: "integer", minimum: 1 },
    branch: { type: "string" },
    expected_head_sha: { type: "string" },
    required_checks: { type: "array", items: { type: "string" }, maxItems: 32 },
    review_expectation: { type: "string", enum: ["APPROVED", "ANY"] },
    cursor: { type: "string" },
    deadline_utc: { type: "string" },
    retry_budget_max: { type: "integer", minimum: 0, maximum: 100 },
  },
  required: [
    "task_id",
    "goal_id",
    "repository",
    "pr_number",
    "branch",
    "expected_head_sha",
    "deadline_utc",
    "retry_budget_max",
  ],
  additionalProperties: false,
};

// Explicit runtime allowlist: enforced even if the host bypasses the JSON
// Schema above. Anything else (storage paths, authority inputs, unknown
// keys) is refused before any spawn. Session-like keys keep their own
// reason and are checked first.
export const PLANNER_WAIT_ARG_ALLOWLIST: ReadonlyArray<string> = [
  "task_id",
  "goal_id",
  "run_id",
  "repository",
  "pr_number",
  "branch",
  "expected_head_sha",
  "required_checks",
  "review_expectation",
  "cursor",
  "deadline_utc",
  "retry_budget_max",
];

const PLANNER_WAIT_ENV_KEYS = [
  "OPENCODE_PLANNER_WAIT_ENABLED",
  "OPENCODE_PLANNER_WAIT_BRIDGE",
  "OPENCODE_PLANNER_WAIT_SHELL",
  "OPENCODE_PLANNER_WAIT_TIMEOUT_MS",
];

export function readPlannerWaitEnv(source: unknown): Record<string, string | undefined> {
  const out: Record<string, string | undefined> = {};
  try {
    const e = source as Record<string, unknown>;
    if (!e || typeof e !== "object") return out;
    for (const k of PLANNER_WAIT_ENV_KEYS) {
      const v = (e as Record<string, unknown>)[k];
      out[k] = typeof v === "string" ? v : undefined;
    }
  } catch {
    // Fail-open: missing env means disabled.
  }
  return out;
}

export function isPlannerWaitEnabled(env: Record<string, string | undefined>): boolean {
  try {
    return asString(env["OPENCODE_PLANNER_WAIT_ENABLED"]) === "1";
  } catch {
    return false;
  }
}

export function readPlannerWaitBridgeConfig(env: Record<string, string | undefined>): {
  ok: boolean;
  reason: string;
  bridge: string;
  shell: string;
  timeoutMs: number;
} {
  const fail = (reason: string) => ({ ok: false, reason, bridge: "", shell: "", timeoutMs: 0 });
  try {
    const bridge = asString(env["OPENCODE_PLANNER_WAIT_BRIDGE"]);
    const shell = asString(env["OPENCODE_PLANNER_WAIT_SHELL"]);
    if (bridge === "" || shell === "") return fail("planner-wait-config-incomplete");
    const absRe = /^(?:\/|[A-Za-z]:[\\/])/;
    if (!absRe.test(bridge) || !absRe.test(shell)) return fail("planner-wait-config-not-absolute");
    let timeoutMs = PLANNER_WAIT_DEFAULT_TIMEOUT_MS;
    const raw = asString(env["OPENCODE_PLANNER_WAIT_TIMEOUT_MS"]);
    if (raw !== "") {
      if (!/^[0-9]{1,6}$/.test(raw)) return fail("planner-wait-timeout-invalid");
      timeoutMs = Number(raw);
      if (!(timeoutMs >= 1000 && timeoutMs <= 120000)) return fail("planner-wait-timeout-invalid");
    }
    return { ok: true, reason: "", bridge, shell, timeoutMs };
  } catch {
    return fail("planner-wait-config-invalid");
  }
}

export function readPlannerWaitHostContext(context: unknown): {
  ok: boolean;
  reason: string;
  sessionId: string;
  agent: string;
} {
  const fail = { ok: false, reason: "planner-wait-context-unknown", sessionId: "", agent: "" };
  try {
    if (!isPlainObject(context)) return fail;
    const c = context as Record<string, unknown>;
    // PR181-A-TOOLCONTEXT-STRICT: read ONLY canonical ToolContext fields;
    // typechecked at 2.2.6, runtime-observed only at 2.0.23 (sessionID, agent -
    // alongside messageID/id; execute(input, context) is host-supplied and
    // separate from model args). Alias keys (sessionId/session_id/agentName/
    // agent_name) are NOT read: accepting them would let a forged
    // model-adjacent shape bypass host authorization.
    const sessionId = asString(c["sessionID"]);
    const agent = asString(c["agent"]);
    if (sessionId === "" || agent === "") return fail;
    if (sessionId.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(sessionId)) return fail;
    return { ok: true, reason: "", sessionId, agent };
  } catch {
    return fail;
  }
}

export function validatePlannerWaitArgs(args: unknown): {
  ok: boolean;
  reason: string;
  request: PlannerWaitRequest;
} {
  const fail = (reason: string): { ok: boolean; reason: string; request: PlannerWaitRequest } => ({
    ok: false,
    reason,
    request: {},
  });
  try {
    if (!isPlainObject(args)) return fail("planner-wait-args-invalid");
    const a = args as Record<string, unknown>;
    for (const k of Object.keys(a)) {
      if (/session/i.test(k)) return fail("planner-wait-session-forbidden");
    }
    for (const k of Object.keys(a)) {
      if (PLANNER_WAIT_ARG_ALLOWLIST.indexOf(k) === -1) {
        return fail("planner-wait-args-unknown-field");
      }
    }
    const req: PlannerWaitRequest = {};
    const needStr = (name: string, max: number): string | null => {
      const v = a[name];
      if (typeof v !== "string" || asString(v) === "" || asString(v).length > max) return null;
      return asString(v);
    };
    const optStr = (name: string, max: number): string | null => {
      if (a[name] === undefined) return "";
      const v = a[name];
      if (typeof v !== "string" || asString(v).length > max) return null;
      return asString(v);
    };
    for (const name of [
      "task_id",
      "goal_id",
      "repository",
      "branch",
      "expected_head_sha",
      "deadline_utc",
    ]) {
      const v = needStr(name, 512);
      if (v === null) return fail("planner-wait-args-invalid");
      req[name] = v;
    }
    const pr = a["pr_number"];
    if (typeof pr !== "number" || !Number.isInteger(pr) || pr < 1) return fail("planner-wait-args-invalid");
    req["pr_number"] = pr;
    const rb = a["retry_budget_max"];
    if (typeof rb !== "number" || !Number.isInteger(rb) || rb < 0 || rb > 100) return fail("planner-wait-args-invalid");
    req["retry_budget_max"] = rb;
    const rev = a["review_expectation"] === undefined ? "APPROVED" : a["review_expectation"];
    if (rev !== "APPROVED" && rev !== "ANY") return fail("planner-wait-args-invalid");
    req["review_expectation"] = rev;
    const checks: Array<string> = [];
    if (a["required_checks"] !== undefined) {
      const rc = a["required_checks"];
      if (!Array.isArray(rc) || rc.length > 32) return fail("planner-wait-args-invalid");
      for (const c of rc) {
        if (typeof c !== "string" || asString(c) === "" || asString(c).length > 128) {
          return fail("planner-wait-args-invalid");
        }
        checks.push(asString(c));
      }
    }
    req["required_checks"] = checks;
    for (const name of ["run_id", "cursor"]) {
      const v = optStr(name, 1024);
      if (v === null) return fail("planner-wait-args-invalid");
      req[name] = v;
    }
    if (!/^[0-9a-fA-F]{40}$/.test(String(req["expected_head_sha"]))) return fail("planner-wait-args-invalid");
    for (const name of ["deadline_utc"]) {
      const v = String(req[name]);
      if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(v)) {
        return fail("planner-wait-args-invalid");
      }
      if (Number.isNaN(Date.parse(v))) return fail("planner-wait-args-invalid");
    }
    return { ok: true, reason: "", request: req };
  } catch {
    return fail("planner-wait-args-invalid");
  }
}

// Fail-closed Session.Info complete-shape gate; runtime-observed only at
// 2.0.23, not 2.2.6: required keys
// `id`, `projectID`, `cost`, `tokens`, `time`, `location` must EACH be an
// OWN property (inherited values do NOT count) with pinned types —
// canonical non-empty `id` matching `^ses`, non-empty `projectID`, number
// `cost`, `tokens` (TokenUsage.Info) with own numeric `input`/`output`/
// `reasoning` plus own `cache` object with own numeric `read`/`write`,
// `time` with own numeric `created`/`updated`, and `location` with own
// non-empty `directory`. Used for BOTH the direct candidate and the
// `{data}` inner candidate.
function isCompletePinnedSessionInfo(candidate: Record<string, unknown>): boolean {
  try {
    if (!Object.prototype.hasOwnProperty.call(candidate, "id")) return false;
    const id = candidate["id"];
    if (typeof id !== "string" || asString(id) === "") return false;
    if (!/^ses/.test(asString(id))) return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "projectID")) return false;
    const projectID = candidate["projectID"];
    if (typeof projectID !== "string" || asString(projectID) === "") return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "cost")) return false;
    const cost = candidate["cost"];
    if (typeof cost !== "number" || !Number.isFinite(cost as number)) return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "tokens")) return false;
    const tokens = candidate["tokens"];
    if (!isPlainObject(tokens)) return false;
    const tk = tokens as Record<string, unknown>;
    for (const f of ["input", "output", "reasoning"] as const) {
      if (!Object.prototype.hasOwnProperty.call(tk, f)) return false;
      if (typeof tk[f] !== "number" || !Number.isFinite(tk[f] as number)) return false;
    }
    if (!Object.prototype.hasOwnProperty.call(tk, "cache")) return false;
    const cache = tk["cache"];
    if (!isPlainObject(cache)) return false;
    const cc = cache as Record<string, unknown>;
    if (!Object.prototype.hasOwnProperty.call(cc, "read")) return false;
    if (!Object.prototype.hasOwnProperty.call(cc, "write")) return false;
    if (typeof cc["read"] !== "number" || !Number.isFinite(cc["read"] as number)) return false;
    if (typeof cc["write"] !== "number" || !Number.isFinite(cc["write"] as number)) return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "time")) return false;
    const time = candidate["time"];
    if (!isPlainObject(time)) return false;
    const t = time as Record<string, unknown>;
    if (!Object.prototype.hasOwnProperty.call(t, "created")) return false;
    if (!Object.prototype.hasOwnProperty.call(t, "updated")) return false;
    if (typeof t["created"] !== "number" || !Number.isFinite(t["created"] as number)) return false;
    if (typeof t["updated"] !== "number" || !Number.isFinite(t["updated"] as number)) return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "location")) return false;
    const location = candidate["location"];
    if (!isPlainObject(location)) return false;
    const l = location as Record<string, unknown>;
    if (!Object.prototype.hasOwnProperty.call(l, "directory")) return false;
    if (typeof l["directory"] !== "string" || asString(l["directory"]) === "") return false;
    return true;
  } catch {
    return false;
  }
}

export async function checkPlannerWaitRootProvenance(
  sessionGet: PlannerWaitSessionGet | null | undefined,
  sessionID: string,
): Promise<{ ok: boolean; reason: string }> {
  try {
    if (typeof sessionGet !== "function") return { ok: false, reason: "planner-wait-provenance-unavailable" };
    if (typeof sessionID !== "string" || sessionID === "") {
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    }
    const doc = await sessionGet(sessionID);
    if (!isPlainObject(doc)) return { ok: false, reason: "planner-wait-provenance-unavailable" };
    const d = doc as Record<string, unknown>;
    // Prior 2.0.23 runtime-observed shape: session.get resolves to a DIRECT
    // SessionInfo; the 2.2.6 runtime shape remains unobserved.
    // ({id, projectID, time, ...}; root has no parentID, child has
    // parentID === root id). The Promise adapter unwraps the transport
    // `{data: SessionInfo}` envelope, but a raw envelope may still surface;
    // unwrap exactly one `{data}` level. `{info}`/`{session}` wrappers are
    // lifecycle-event shapes, NOT session.get evidence: no fallback reads
    // them (a truncated {info:{id}} is incomplete => unavailable).
    let candidate: Record<string, unknown> | null = null;
    const rawData = d["data"];
    const idKeys = ["id", "sessionID", "sessionId", "session_id"];
    const parentKeys = ["parentID", "parentId", "parent_id", "parent"];
    // Fail-closed envelope rule (reviewer MEDIUM): when `data` is present it
    // is authoritative transport evidence. The inner object MUST carry the
    // canonical valid SessionInfo id — never fall back to the outer object.
    // Every present identity value across outer + inner (all aliases) must
    // be a non-empty string, unique, and equal to the host sessionID;
    // malformed/empty/ambiguous/conflicting ids => unavailable. Parents are
    // inspected across BOTH scopes: malformed => unavailable, any non-empty
    // => not-root. Own `data` presence (even null/undefined/scalar/array)
    // is an envelope claim: only a plain object with canonical id passes.
    const hasDataKey = Object.prototype.hasOwnProperty.call(d, "data");
    if (hasDataKey) {
      if (!isPlainObject(rawData)) {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      const rd = rawData as Record<string, unknown>;
      // Inner MUST carry the canonical SessionInfo id; never fall back to
      // the outer envelope object (an id-less nested child must not inherit
      // a complete outer root identity).
      const innerCanonicalId = rd["id"];
      if (typeof innerCanonicalId !== "string" || asString(innerCanonicalId) === "") {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      const seen: Array<string> = [];
      const scopes: Array<Record<string, unknown>> = [d, rd];
      for (const scope of scopes) {
        for (const k of idKeys) {
          if (!Object.prototype.hasOwnProperty.call(scope, k)) continue;
          const v = scope[k];
          // Fail-closed: any OWN alias key — including null/undefined —
          // must be a non-empty string; skipped values would hide
          // ambiguous/conflicting identity evidence.
          if (typeof v !== "string" || asString(v) === "") {
            return { ok: false, reason: "planner-wait-provenance-unavailable" };
          }
          const t = asString(v);
          if (seen.indexOf(t) === -1) seen.push(t);
        }
      }
      if (seen.length !== 1) return { ok: false, reason: "planner-wait-provenance-unavailable" };
      if ((seen[0] as string) !== sessionID) return { ok: false, reason: "planner-wait-provenance-mismatch" };
      // Optional parents across BOTH scopes: the actual root OMITS every
      // parent key. Any OWN parent key — null/undefined/empty/malformed —
      // refuses unavailable; only a non-empty valid string parent continues
      // as not-root.
      let hasParent = false;
      for (const scope of scopes) {
        for (const k of parentKeys) {
          if (!Object.prototype.hasOwnProperty.call(scope, k)) continue;
          const v = scope[k];
          if (typeof v !== "string" || asString(v) === "") {
            return { ok: false, reason: "planner-wait-provenance-unavailable" };
          }
          hasParent = true;
        }
      }
      if (hasParent) return { ok: false, reason: "planner-wait-not-root" };
      // Same complete-shape gate as the direct candidate (pinned required
      // keys with own-property checks), applied to the authoritative inner.
      if (!isCompletePinnedSessionInfo(rd)) {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      return { ok: true, reason: "" };
    } else {
      candidate = d;
    }
    // Identity (direct SessionInfo): any OWN alias key — including
    // null/undefined — must be a non-empty string; multiple distinct values
    // => ambiguous => unavailable. Skipped null/undefined would hide
    // ambiguous identity evidence.
    const seen: Array<string> = [];
    for (const k of idKeys) {
      if (!Object.prototype.hasOwnProperty.call(candidate as Record<string, unknown>, k)) continue;
      const v = (candidate as Record<string, unknown>)[k];
      if (typeof v !== "string" || asString(v) === "") {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      const t = asString(v);
      if (seen.indexOf(t) === -1) seen.push(t);
    }
    if (seen.length === 0) return { ok: false, reason: "planner-wait-provenance-unavailable" };
    if (seen.length > 1) return { ok: false, reason: "planner-wait-provenance-unavailable" };
    const id = seen[0] as string;
    if (id !== sessionID) return { ok: false, reason: "planner-wait-provenance-mismatch" };
    // Optional parent: the actual root OMITS every parent key. Any OWN
    // parent key — null/undefined/empty/malformed — refuses unavailable;
    // only a non-empty valid string parent continues as not-root. Checked
    // before completeness: a parent pin alone proves non-root even on a
    // truncated doc.
    let hasParent = false;
    for (const k of parentKeys) {
      if (!Object.prototype.hasOwnProperty.call(candidate, k)) continue;
      const v = (candidate as Record<string, unknown>)[k];
      if (typeof v !== "string" || asString(v as string) === "") {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      hasParent = true;
    }
    if (hasParent) return { ok: false, reason: "planner-wait-not-root" };
    // Completeness: same pinned gate as the `{data}` inner candidate — each
    // required SessionInfo key as an OWN property with pinned types. A bare
    // {id} (or inherited projectID/time) is NOT a SessionInfo.
    if (!isCompletePinnedSessionInfo(candidate as Record<string, unknown>)) {
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    }
    return { ok: true, reason: "" };
  } catch {
    return { ok: false, reason: "planner-wait-provenance-unavailable" };
  }
}

export interface PlannerWaitStatResult {
  isSymbolicLink(): boolean;
  isFile(): boolean;
  size: number;
}

export type PlannerWaitLstatFn = (p: string) => PlannerWaitStatResult;

// Fixture validator seam: lstat (never stat) BOTH bridge and shell so a
// symlink at either path denies, even when it points at a regular file.
// Missing/unreadable/non-file/oversized also deny (fail-closed). The V2
// adapter passes node:lstatSync; the mock passes stubs (no real symlinks
// needed, portable across platforms).
// Residual (documented, not claimed): lstat-then-spawn is not atomic; a
// swap between this check and the bridge spawn (TOCTOU) is not detected
// here. The bridge response is still strictly parsed and authority pins
// stay false.
export function checkPlannerWaitFixtureFiles(
  lstat: PlannerWaitLstatFn | null | undefined,
  bridge: string,
  shell: string,
  shellLstat?: PlannerWaitLstatFn | null | undefined,
): { ok: boolean; reason: string } {
  const fail = (reason: string): { ok: boolean; reason: string } => ({ ok: false, reason });
  try {
    if (typeof lstat !== "function") return fail("planner-wait-fixture-unavailable");
    const lstatShell = typeof shellLstat === "function" ? shellLstat : lstat;
    if (typeof bridge !== "string" || bridge === "" || typeof shell !== "string" || shell === "") {
      return fail("planner-wait-fixture-invalid");
    }
    let b: PlannerWaitStatResult;
    try {
      b = lstat(bridge);
    } catch {
      return fail("planner-wait-fixture-unreadable");
    }
    if (!b || b.isSymbolicLink()) return fail("planner-wait-fixture-symlink");
    if (!b.isFile() || b.size <= 0 || b.size > PLANNER_WAIT_BRIDGE_MAX_BYTES) {
      return fail("planner-wait-fixture-invalid");
    }
    let s: PlannerWaitStatResult;
    try {
      s = lstatShell(shell);
    } catch {
      return fail("planner-wait-fixture-unreadable");
    }
    if (!s || s.isSymbolicLink()) return fail("planner-wait-fixture-symlink");
    if (!s.isFile()) return fail("planner-wait-fixture-invalid");
    return { ok: true, reason: "" };
  } catch {
    return fail("planner-wait-fixture-invalid");
  }
}

export function runPlannerWaitBridge(
  cfg: PlannerWaitBridgeConfig,
  payload: string,
  deps: { spawnFn?: PlannerWaitSpawnFn | null },
): Promise<{ ok: boolean; reason: string; stdout: string }> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result: { ok: boolean; reason: string; stdout: string }): void => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    const bad = (reason: string): void => finish({ ok: false, reason, stdout: "" });
    let spawnFn: PlannerWaitSpawnFn | null | undefined = null;
    try {
      if (deps && typeof deps.spawnFn === "function") spawnFn = deps.spawnFn;
    } catch {
      spawnFn = null;
    }
    if (typeof spawnFn !== "function") {
      bad("planner-wait-bridge-spawn-unavailable");
      return;
    }
    let child: PlannerWaitChild | null | undefined = null;
    try {
      child = spawnFn(cfg.shell, ["-NoProfile", "-NonInteractive", "-File", cfg.bridge], {
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch {
      child = null;
    }
    if (!child || !child.stdin || !child.stdout || !child.stderr) {
      bad("planner-wait-bridge-spawn-failed");
      return;
    }
    const outChunks: Array<Uint8Array> = [];
    let outBytes = 0;
    let done = false;
    let timer: unknown = null;
    try {
      timer = setTimeout(() => {
        done = true;
        try {
          child?.kill();
        } catch {
          // Fail-open: kill is best-effort.
        }
        bad("planner-wait-bridge-timeout");
      }, cfg.timeoutMs);
    } catch {
      timer = null;
    }
    const clearTimer = (): void => {
      try {
        if (timer !== null) clearTimeout(timer as unknown as ReturnType<typeof setTimeout>);
      } catch {
        // Fail-open.
      }
      timer = null;
    };
    try {
      (child.stderr as { on: (e: string, cb: () => void) => unknown }).on("data", () => undefined);
    } catch {
      // Fail-open: stderr drain is best-effort.
    }
    try {
      (child.stdout as { on: (e: string, cb: (c: unknown) => void) => unknown }).on("data", (chunk: unknown) => {
        if (done) return;
        try {
          let buf: Uint8Array;
          if (chunk instanceof Uint8Array) buf = chunk;
          else buf = new TextEncoder().encode(String(chunk));
          outBytes += buf.length;
          if (outBytes > PLANNER_WAIT_BRIDGE_MAX_BYTES) {
            done = true;
            try {
              child?.kill();
            } catch {
              // Fail-open.
            }
            clearTimer();
            bad("planner-wait-bridge-output-unbounded");
            return;
          }
          outChunks.push(buf);
        } catch {
          // Fail-open: one bad chunk never breaks the read.
        }
      });
    } catch {
      // Fail-open.
    }
    try {
      child.on("error", () => {
        if (done) return;
        done = true;
        clearTimer();
        bad("planner-wait-bridge-spawn-failed");
      });
    } catch {
      // Fail-open.
    }
    try {
      child.on("close", (code: unknown) => {
        if (done) return;
        done = true;
        clearTimer();
        if (code !== 0) {
          bad("planner-wait-bridge-refused");
          return;
        }
        let stdout = "";
        try {
          let total = 0;
          for (const b of outChunks) total += b.length;
          const flat = new Uint8Array(total);
          let off = 0;
          for (const b of outChunks) {
            flat.set(b, off);
            off += b.length;
          }
          stdout = new TextDecoder("utf-8", { fatal: true }).decode(flat);
        } catch {
          bad("planner-wait-bridge-output-invalid");
          return;
        }
        finish({ ok: true, reason: "", stdout });
      });
    } catch {
      // Fail-open.
    }
    try {
      (child.stdin as PlannerWaitChildStdio).on("error", () => {
        if (done) return;
        done = true;
        clearTimer();
        try {
          child?.kill();
        } catch {
          // Fail-open.
        }
        bad("planner-wait-bridge-stdin-failed");
      });
    } catch {
      // Fail-open.
    }
    try {
      (child.stdin as PlannerWaitChildStdio).write(payload);
      (child.stdin as PlannerWaitChildStdio).end();
    } catch {
      if (done) return;
      done = true;
      clearTimer();
      bad("planner-wait-bridge-stdin-failed");
    }
  });
}

const PLANNER_WAIT_BRIDGE_WANT = [
  "schema_version",
  "operation",
  "ok",
  "reason",
  "run_id",
  "revision",
  "binding",
  "wait_reused",
  "wait_file",
  "dedup_key",
  "task_mutated",
  "grants_authority",
  "done_approved",
];

export function parsePlannerWaitBridgeResponse(stdout: unknown): {
  ok: boolean;
  reason: string;
  doc: Record<string, unknown> | null;
} {
  const fail = (reason: string): { ok: boolean; reason: string; doc: Record<string, unknown> | null } => ({
    ok: false,
    reason,
    doc: null,
  });
  try {
    if (typeof stdout !== "string" || stdout.length === 0 || stdout.length > PLANNER_WAIT_BRIDGE_MAX_BYTES) {
      return fail("planner-wait-bridge-output-unbounded");
    }
    let doc: unknown = null;
    try {
      doc = JSON.parse(stdout) as unknown;
    } catch {
      return fail("planner-wait-bridge-output-invalid");
    }
    if (!isPlainObject(doc)) return fail("planner-wait-bridge-output-invalid");
    const d = doc as Record<string, unknown>;
    const keys = Object.keys(d);
    if (keys.length !== PLANNER_WAIT_BRIDGE_WANT.length) return fail("planner-wait-bridge-output-shape");
    for (const k of PLANNER_WAIT_BRIDGE_WANT) {
      if (!Object.prototype.hasOwnProperty.call(d, k)) return fail("planner-wait-bridge-output-shape");
    }
    if (d["schema_version"] !== PLANNER_WAIT_SCHEMA_VERSION) return fail("planner-wait-bridge-output-shape");
    if (d["operation"] !== PLANNER_WAIT_OPERATION) return fail("planner-wait-bridge-output-shape");
    if (typeof d["ok"] !== "boolean") return fail("planner-wait-bridge-output-shape");
    if (typeof d["reason"] !== "string" || (d["reason"] as string).length === 0 || (d["reason"] as string).length > 128) {
      return fail("planner-wait-bridge-output-shape");
    }
    if (!/^[a-z0-9-]+$/.test(d["reason"] as string)) return fail("planner-wait-bridge-output-shape");
    if (typeof d["run_id"] !== "string") return fail("planner-wait-bridge-output-shape");
    if (typeof d["revision"] !== "number" || !Number.isInteger(d["revision"])) {
      return fail("planner-wait-bridge-output-shape");
    }
    if (typeof d["binding"] !== "string") return fail("planner-wait-bridge-output-shape");
    if (typeof d["wait_reused"] !== "boolean") return fail("planner-wait-bridge-output-shape");
    if (typeof d["wait_file"] !== "string" || typeof d["dedup_key"] !== "string") {
      return fail("planner-wait-bridge-output-shape");
    }
    if (typeof d["task_mutated"] !== "boolean") return fail("planner-wait-bridge-output-shape");
    if (d["grants_authority"] !== false || d["done_approved"] !== false) {
      return fail("planner-wait-authority-pin-violated");
    }
    return { ok: true, reason: "", doc: d };
  } catch {
    return fail("planner-wait-bridge-output-invalid");
  }
}

export interface PlannerWaitExecuteDeps {
  spawnFn?: PlannerWaitSpawnFn | null;
  sessionGet?: PlannerWaitSessionGet | null;
}

export function makePlannerWaitExecute(
  cfg: PlannerWaitBridgeConfig,
  deps: PlannerWaitExecuteDeps,
): (args: unknown, context: unknown) => Promise<{ content: Array<{ type: "text"; text: string }> }> {
  const spawnFn = deps && typeof deps.spawnFn === "function" ? deps.spawnFn : null;
  const sessionGet =
    deps && typeof deps.sessionGet === "function" ? (deps.sessionGet as PlannerWaitSessionGet) : null;
  return async function plannerWaitExecute(
    args: unknown,
    context: unknown,
  ): Promise<{ content: Array<{ type: "text"; text: string }> }> {
    const host = readPlannerWaitHostContext(context);
    if (!host.ok) throw denyPlannerWait(host.reason);
    const role = plannerWaitRoleOf(host.agent);
    if (role === "worker") throw denyPlannerWait("planner-wait-worker-denied");
    if (role !== "planner") throw denyPlannerWait("planner-wait-agent-unknown");
    const checked = validatePlannerWaitArgs(args);
    if (!checked.ok) {
      // Propagate the validator's own reason: it only ever emits
      // planner-wait-* codes (session-forbidden, args-unknown-field,
      // args-invalid), and deny() sanitizes again. No masking: the caller
      // (and tests) can distinguish forged-session vs unknown-field.
      if (/^planner-wait-[a-z-]+$/.test(checked.reason)) throw denyPlannerWait(checked.reason);
      throw denyPlannerWait("planner-wait-args-invalid");
    }
    const prov = await checkPlannerWaitRootProvenance(sessionGet, host.sessionId);
    if (!prov.ok) throw denyPlannerWait(prov.reason);
    let payload = "";
    try {
      payload = JSON.stringify({
        schema_version: PLANNER_WAIT_SCHEMA_VERSION,
        request: { ...(checked.request as Record<string, unknown>), session_id: host.sessionId },
      });
    } catch {
      throw denyPlannerWait("planner-wait-args-invalid");
    }
    let payloadBytes = 0;
    try {
      payloadBytes = new TextEncoder().encode(payload).length;
    } catch {
      payloadBytes = 0;
    }
    if (payloadBytes === 0 || payloadBytes > PLANNER_WAIT_BRIDGE_MAX_BYTES) {
      throw denyPlannerWait("planner-wait-request-unbounded");
    }
    const res = await runPlannerWaitBridge(cfg, payload, { spawnFn });
    if (!res.ok) throw denyPlannerWait(res.reason);
    const parsed = parsePlannerWaitBridgeResponse(res.stdout);
    if (!parsed.ok) throw denyPlannerWait(parsed.reason);
    const doc = parsed.doc as Record<string, unknown>;
    if (doc["ok"] !== true) throw denyPlannerWait("planner-wait-bridge-refused-" + sanitizePlannerWaitCode(doc["reason"]));
    return { content: [{ type: "text" as const, text: JSON.stringify(doc) }] };
  };
}
