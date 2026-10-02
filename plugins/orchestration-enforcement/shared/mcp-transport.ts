// MCP transport envelope for already-classified MCP tool calls
// (Phase 28 slice 2: plan task 4, "Enforce call timeout in
// plugin/integration layer if native runtime cannot").
//
// Scope: this module NEVER routes or discovers tools. Only tool names
// matching the conservative embedded allowlist below are treated as
// MCP; anything else bypasses untouched (unknown is NEVER MCP).
// Generic `mcp_routing` stays OFF: this file never reads or writes
// source/registry/capability-flags.json.
//
// Modes: default SHADOW (observe only: records would-timeout /
// would-open telemetry, NEVER cancels the execution). ENFORCED mode
// applies the class deadline (the losing promise is abandoned SAFELY:
// its rejection handler is attached synchronously, so no unhandled
// rejection; the host process is never killed) and honors the circuit.
// Enforced is active ONLY after explicit operator opt-in via
// configureMcpTransport({ enforced: true }) or env
// OO_MCP_TRANSPORT_ENFORCED=1 (read lazily, trimmed, "1" only).
// A per-call request for "enforced" without the global opt-in is
// denied to shadow with an enforce-denied telemetry row.
//
// Policy: embedded defaults mirror
// source/registry/mcp-request-policy.json v1 EXACTLY (advisory 30s,
// memory 60s, remote 120s, connect budgets 10/15/20s, long_running
// execution 0 plus an explicit task contract, failure threshold
// exactly 2, cooldown exactly 300s, criticality optional|required
// defaulting to optional). The mirror is CANONICAL, not a range:
// the strict validator below accepts operator-supplied policy text
// ONLY when every one of those values matches exactly; anything
// absent, illegible or deviating falls back to the embedded
// defaults with a policy-fallback telemetry row (never silent
// divergence, never a throw). POLICY EVOLUTION RULE: if the
// canonical policy file ever changes, this mirror (embedded
// defaults plus the strict validator) MUST be updated in the same
// commit, or every new text will fail closed to the old mirror. A
// policy FILE is read only through an explicitly installed file
// reader (setMcpPolicyFileReader: absolute paths only, 64 KiB cap,
// the V2 adapter installs a bounded node:fs reader at setup);
// without one, no file access happens. File reads are re-read on
// every resolution (bounded and cheap), so they are always fresh;
// inline texts use a single-entry exact-content cache.
//
// Circuit: in-memory, per (server, class, planner-turn), plugin
// session scope (module-level map, bounded with oldest-first
// eviction). Two consecutive timeout/transport failures open the
// circuit; the cooldown is counted from the CONCLUSION of the second
// failure; after expiry exactly one half-open probe runs; success
// rearms to CLOSED. Semantics mirror the kernel S1 envelope.
//
// Results are structured and NEVER carry authority: optional plus
// unavailable maps to MCP_UNAVAILABLE (fallback_continue, never
// blocked); required plus unavailable maps to MCP_REQUIRED_BLOCKED
// (blocked) on EVERY unavailable branch, including input validation,
// long-running contract refusal, budget re-read and internal errors.
// mcpResultGrantsAuthority() denies every input, including null.
//
// Purity: only relative sibling imports (./sanitize, ./telemetry),
// no runtime package imports, no static node: imports (dual-runtime
// purity gate). ASCII-only. runMcpGuarded NEVER throws: internal
// errors become structured refusals (fail-closed for the engaged
// call); hook wrappers stay fail-open for the host.
import { sanitizeOpt } from "./sanitize";
import { mapSetBounded } from "./sanitize";
import type { RuntimeId } from "./types";
import { writeMcpEvent } from "./telemetry";

export type McpClass = "advisory" | "memory" | "remote" | "long_running";
export type McpCriticality = "optional" | "required";
export type McpMode = "shadow" | "enforced";

export interface McpClassification {
  server: string;
  mcpClass: McpClass;
}

export interface McpContract {
  id: string;
  budgetSeconds: number;
}

export interface McpGuardedOptions {
  tool: unknown;
  execute: () => Promise<unknown>;
  turn?: unknown;
  criticality?: unknown;
  classOverride?: unknown;
  contract?: McpContract | null;
  mode?: McpMode | unknown;
  policyText?: unknown;
  policyPath?: unknown;
  tightenBudgetMs?: unknown;
  signal?: AbortSignal | null;
  nowMs?: unknown;
}

export interface McpResult {
  ok: boolean;
  status: "OK" | "MCP_BYPASS_NOT_MCP" | "MCP_UNAVAILABLE" | "MCP_REQUIRED_BLOCKED";
  cause: string | null;
  blocked: boolean;
  fallback_continue: boolean;
  engaged: boolean;
  server: string | null;
  mcpClass: McpClass | null;
  criticality: McpCriticality;
  mode: McpMode;
  elapsedMs: number;
  value?: unknown;
}

// Embedded defaults: an EXACT mirror of
// source/registry/mcp-request-policy.json v1. Any drift between
// these numbers and the policy file is a defect; the strict
// validator below rejects deviating operator-supplied texts.
export const MCP_EMBEDDED_BUDGET_S: Record<string, number> = {
  advisory: 30,
  memory: 60,
  remote: 120,
};
export const MCP_EMBEDDED_LONG_RUNNING_EXEC_S = 0;
export const MCP_EMBEDDED_FAILURE_THRESHOLD = 2;
export const MCP_EMBEDDED_COOLDOWN_S = 300;
export const MCP_POLICY_TEXT_CAP = 65536;
export const MCP_POLICY_FILE_CAP = 65536;
export const MCP_CIRCUIT_CAP = 500;
export const MCP_LONG_RUNNING_MAX_BUDGET_S = 3600;

const CAUSES: ReadonlyArray<string> = [
  "MCP_TIMEOUT",
  "MCP_CIRCUIT_OPEN",
  "MCP_HALF_OPEN_BUSY",
  "MCP_ERROR",
  "MCP_LONG_RUNNING_REQUIRES_CONTRACT",
  "MCP_ABORTED",
  "MCP_INTERNAL",
];

function isCausalCode(v: unknown): v is string {
  try {
    return typeof v === "string" && (CAUSES as ReadonlyArray<string>).indexOf(v) >= 0;
  } catch {
    return false;
  }
}

function toBoundedInt(v: unknown, min: number, max: number, fallback: number): number {
  try {
    if (typeof v !== "number" || !isFinite(v)) return fallback;
    const n = Math.floor(v);
    if (n < min || n > max) return fallback;
    return n;
  } catch {
    return fallback;
  }
}

function safeLower(v: unknown, cap: number): string {
  try {
    if (typeof v !== "string") return "";
    const t = v.trim().toLowerCase();
    if (t.length === 0 || t.length > cap) return "";
    return t;
  } catch {
    return "";
  }
}

function isSafeServer(v: string): boolean {
  try {
    if (v.length === 0 || v.length > 64) return false;
    return /^[a-z0-9][a-z0-9._-]*$/.test(v);
  } catch {
    return false;
  }
}

// Conservative allowlist: known MCP tool shapes only. `mcp__server__tool`
// is the generic remote shape; jev/memory are the known servers (the
// jev->advisory alias mirrors policy class_aliases). Anything else is
// NOT MCP: no auto-discovery, no heuristics.
const SEPS = ["_", "-", ":", ".", "/"];

function withSep(base: string, name: string): boolean {
  try {
    if (name === base) return true;
    for (const s of SEPS) {
      if (name.length > base.length + 1 && name.indexOf(base + s) === 0) return true;
    }
    return false;
  } catch {
    return false;
  }
}

function serverAfter(base: string, name: string): string {
  try {
    // Skip every leading separator (covers the "mcp__server__tool"
    // double-underscore convention as well as single-sep shapes),
    // then take the segment up to the next separator.
    const rest = name.slice(base.length);
    let i = 0;
    while (i < rest.length && SEPS.indexOf(rest.charAt(i)) >= 0) i++;
    const tail = rest.slice(i);
    let end = tail.length;
    for (let j = 0; j < tail.length; j++) {
      if (SEPS.indexOf(tail.charAt(j)) >= 0) {
        end = j;
        break;
      }
    }
    const seg = tail.slice(0, end);
    if (isSafeServer(seg)) return seg;
    return "mcp";
  } catch {
    return "mcp";
  }
}

export function classifyMcpTool(tool: unknown): McpClassification | null {
  try {
    const name = safeLower(tool, 256);
    if (name.length === 0) return null;
    if (withSep("jev", name)) return { server: "jev", mcpClass: "advisory" };
    if (withSep("memory", name)) return { server: "memory", mcpClass: "memory" };
    if (withSep("ai-memory", name)) return { server: "ai-memory", mcpClass: "memory" };
    if (withSep("ai_memory", name)) return { server: "ai-memory", mcpClass: "memory" };
    if (name === "mcp") return { server: "mcp", mcpClass: "remote" };
    if (withSep("mcp", name)) return { server: serverAfter("mcp", name), mcpClass: "remote" };
    return null;
  } catch {
    return null;
  }
}

export function normalizeMcpClass(v: unknown): McpClass | null {
  try {
    const c = safeLower(v, 32);
    if (c === "jev") return "advisory";
    if (c === "advisory" || c === "memory" || c === "remote" || c === "long_running") {
      return c as McpClass;
    }
    return null;
  } catch {
    return null;
  }
}

export function normalizeMcpCriticality(v: unknown): McpCriticality {
  try {
    if (typeof v === "string" && v.trim().toLowerCase() === "required") return "required";
    return "optional";
  } catch {
    return "optional";
  }
}

export function normalizeMcpTurn(v: unknown): string {
  try {
    if (typeof v === "string") {
      const t = v.trim().toLowerCase();
      if (t.length >= 1 && t.length <= 64 && /^[a-z0-9][a-z0-9._-]*$/.test(t)) return t;
    }
    return "default-turn";
  } catch {
    return "default-turn";
  }
}

export interface McpResolvedPolicy {
  budgetsS: Record<string, number>;
  failureThreshold: number;
  cooldownS: number;
  source: "embedded-defaults" | "policy-text" | "policy-file";
  valid: boolean;
}

function embeddedPolicy(): McpResolvedPolicy {
  return {
    budgetsS: {
      advisory: MCP_EMBEDDED_BUDGET_S["advisory"] as number,
      memory: MCP_EMBEDDED_BUDGET_S["memory"] as number,
      remote: MCP_EMBEDDED_BUDGET_S["remote"] as number,
    },
    failureThreshold: MCP_EMBEDDED_FAILURE_THRESHOLD,
    cooldownS: MCP_EMBEDDED_COOLDOWN_S,
    source: "embedded-defaults",
    valid: true,
  };
}

function asRecord(v: unknown): Record<string, unknown> | null {
  try {
    if (!v || typeof v !== "object" || Array.isArray(v)) return null;
    return v as Record<string, unknown>;
  } catch {
    return null;
  }
}

function isExactInt(v: unknown, min: number, max: number): v is number {
  try {
    if (typeof v !== "number" || !isFinite(v)) return false;
    if (Math.floor(v) !== v) return false;
    return v >= min && v <= max;
  } catch {
    return false;
  }
}

// Strict canonical validator for policy v1: accepts ONLY the exact
// values of source/registry/mcp-request-policy.json v1 (execution
// budgets advisory 30 / memory 60 / remote 120, connect budgets
// advisory 10 / memory 15 / remote 20 / long_running 20,
// long_running execution 0 plus requires_explicit_task_contract,
// failure_threshold exactly 2, cooldown exactly 300, jev alias to
// advisory, criticality exactly {optional, required} defaulting to
// optional). Anything else => null (caller falls back to the
// embedded defaults, never to partial values). See POLICY EVOLUTION
// RULE in the header: a policy change without a same-commit mirror
// update fails closed to the old mirror by design.
function parseStrictPolicyText(text: string): McpResolvedPolicy | null {
  try {
    if (text.length === 0 || text.length > MCP_POLICY_TEXT_CAP) return null;
    let doc: unknown = null;
    try {
      doc = JSON.parse(text);
    } catch {
      return null;
    }
    const root = asRecord(doc);
    if (!root) return null;
    if (root["version"] !== 1) return null;
    const classes = asRecord(root["classes"]);
    if (!classes) return null;
    const wantExec: Record<string, number> = { advisory: 30, memory: 60, remote: 120 };
    const wantConn: Record<string, number> = { advisory: 10, memory: 15, remote: 20 };
    const budgets: Record<string, number> = {};
    for (const k of ["advisory", "memory", "remote"]) {
      const slot = asRecord(classes[k]);
      if (!slot) return null;
      const ex = slot["execution_timeout_seconds"];
      if (ex !== wantExec[k]) return null;
      const co = slot["connect_timeout_seconds"];
      if (co !== wantConn[k]) return null;
      budgets[k] = ex as number;
    }
    const lr = asRecord(classes["long_running"]);
    if (!lr) return null;
    if (lr["execution_timeout_seconds"] !== 0) return null;
    if (lr["requires_explicit_task_contract"] !== true) return null;
    if (lr["connect_timeout_seconds"] !== 20) return null;
    const aliases = asRecord(root["class_aliases"]);
    if (!aliases || aliases["jev"] !== "advisory") return null;
    if (root["failure_threshold"] !== 2) return null;
    const circuit = asRecord(root["circuit"]);
    if (!circuit) return null;
    const cd = circuit["cooldown_seconds"];
    if (cd !== 300) return null;
    const crit = asRecord(root["criticality"]);
    if (!crit) return null;
    const allowed = crit["allowed"];
    if (!Array.isArray(allowed) || allowed.length !== 2) return null;
    if (allowed.indexOf("optional") < 0 || allowed.indexOf("required") < 0) return null;
    if (crit["default"] !== "optional") return null;
    return {
      budgetsS: budgets,
      failureThreshold: 2,
      cooldownS: cd as number,
      source: "policy-text",
      valid: true,
    };
  } catch {
    return null;
  }
}

export function resolveMcpPolicy(policyText: unknown): McpResolvedPolicy {
  try {
    if (typeof policyText === "string" && policyText.length > 0) {
      const parsed = parseStrictPolicyText(policyText);
      if (parsed) return parsed;
    }
    return embeddedPolicy();
  } catch {
    return embeddedPolicy();
  }
}

// Global operator config. Default is shadow-only. Enforced mode
// requires explicit opt-in (configureMcpTransport or env).
interface McpTransportConfig {
  enforced: boolean;
  policyText: string | null;
  policyPath: string | null;
}

let transportConfig: McpTransportConfig = { enforced: false, policyText: null, policyPath: null };
// Single-entry cache for INLINE policy texts, keyed by exact content
// equality (no truncation, no hash: a hit compares the full stored
// text, so collisions are impossible by construction). File reads
// are NEVER cached: every resolution re-reads through the installed
// reader (bounded 64 KiB, cheap), so file edits take effect without
// invalidation races.
let inlinePolicyCache: { text: string; result: McpResolvedPolicy } | null = null;
let policyFileReader: ((absPath: string) => string | null) | null = null;

function readEnvFlag(name: string): boolean {
  try {
    const g = globalThis as unknown as { process?: { env?: Record<string, string | undefined> } };
    const env = g && g.process && g.process.env ? g.process.env : null;
    if (!env) return false;
    const v = env[name];
    return typeof v === "string" && v.trim() === "1";
  } catch {
    return false;
  }
}

function readEnvText(name: string, cap: number): string | null {
  try {
    const g = globalThis as unknown as { process?: { env?: Record<string, string | undefined> } };
    const env = g && g.process && g.process.env ? g.process.env : null;
    if (!env) return null;
    const v = env[name];
    if (typeof v !== "string") return null;
    const t = v.trim();
    if (t.length === 0 || t.length > cap) return null;
    return t;
  } catch {
    return null;
  }
}

export function configureMcpTransport(cfg: {
  enforced?: unknown;
  policyText?: unknown;
  policyPath?: unknown;
} | null): void {
  try {
    if (!cfg || typeof cfg !== "object") {
      transportConfig = { enforced: false, policyText: null, policyPath: null };
    } else {
      transportConfig = {
        enforced: cfg["enforced"] === true,
        policyText: typeof cfg["policyText"] === "string" ? (cfg["policyText"] as string) : null,
        policyPath: typeof cfg["policyPath"] === "string" ? (cfg["policyPath"] as string) : null,
      };
    }
    clearPolicyCache();
  } catch {
    transportConfig = { enforced: false, policyText: null, policyPath: null };
    clearPolicyCache();
  }
}

export function getMcpTransportConfig(): { enforced: boolean; hasPolicyText: boolean; hasPolicyPath: boolean } {
  try {
    return {
      enforced: transportConfig.enforced === true,
      hasPolicyText: typeof transportConfig.policyText === "string",
      hasPolicyPath: typeof transportConfig.policyPath === "string",
    };
  } catch {
    return { enforced: false, hasPolicyText: false, hasPolicyPath: false };
  }
}

function clearPolicyCache(): void {
  try {
    inlinePolicyCache = null;
  } catch {
    // Fail-open.
  }
}

export function setMcpPolicyFileReader(
  reader: ((absPath: string) => string | null) | null,
): void {
  try {
    if (typeof reader === "function") {
      policyFileReader = reader as (absPath: string) => string | null;
    } else {
      policyFileReader = null;
    }
    clearPolicyCache();
  } catch {
    policyFileReader = null;
  }
}

export type McpPolicyOrigin = "call" | "configure" | "policy-file";

interface EffectivePolicy {
  policy: McpResolvedPolicy;
  // Set when an operator-supplied text (inline or file) was present
  // but invalid, so the embedded defaults apply: the caller emits a
  // policy-fallback telemetry row naming this origin.
  invalidOrigin: McpPolicyOrigin | null;
}

function effectivePolicy(callText: unknown, callPath: unknown): EffectivePolicy {
  try {
    const hasCallText = typeof callText === "string" && (callText as string).length > 0;
    const hasConfigText = typeof transportConfig.policyText === "string";
    const text = hasCallText
      ? (callText as string)
      : (hasConfigText ? (transportConfig.policyText as string) : null);
    if (text !== null) {
      try {
        if (inlinePolicyCache && inlinePolicyCache.text === text) {
          return { policy: inlinePolicyCache.result, invalidOrigin: null };
        }
      } catch {
        // Fail-open: cache miss on bookkeeping trouble.
      }
      const parsed = parseStrictPolicyText(text);
      if (parsed) {
        try {
          inlinePolicyCache = { text, result: parsed };
        } catch {
          // Fail-open: caching is best-effort.
        }
        return { policy: parsed, invalidOrigin: null };
      }
      return { policy: embeddedPolicy(), invalidOrigin: hasCallText ? "call" : "configure" };
    }
    const path = typeof callPath === "string" && (callPath as string).length > 0
      ? (callPath as string)
      : (typeof transportConfig.policyPath === "string"
        ? (transportConfig.policyPath as string)
        : readEnvText("OO_MCP_TRANSPORT_POLICY_PATH", 512));
    if (path !== null && policyFileReader !== null) {
      let fileText: string | null = null;
      try {
        fileText = policyFileReader(path);
      } catch {
        fileText = null;
      }
      if (typeof fileText === "string" && fileText.length > 0) {
        const parsed = parseStrictPolicyText(fileText);
        if (parsed) {
          parsed.source = "policy-file";
          return { policy: parsed, invalidOrigin: null };
        }
      }
      return { policy: embeddedPolicy(), invalidOrigin: "policy-file" };
    }
    return { policy: embeddedPolicy(), invalidOrigin: null };
  } catch {
    return { policy: embeddedPolicy(), invalidOrigin: null };
  }
}

function globalEnforced(): boolean {
  try {
    if (transportConfig.enforced === true) return true;
    return readEnvFlag("OO_MCP_TRANSPORT_ENFORCED");
  } catch {
    return false;
  }
}

export function effectiveMcpMode(requested: unknown): { mode: McpMode; denied: boolean } {
  try {
    const r = typeof requested === "string" ? requested.trim().toLowerCase() : "";
    if (r === "shadow") return { mode: "shadow", denied: false };
    if (globalEnforced()) return { mode: "enforced", denied: false };
    if (r === "enforced") return { mode: "shadow", denied: true };
    return { mode: "shadow", denied: false };
  } catch {
    return { mode: "shadow", denied: false };
  }
}

// Circuit store: key = server + "\0" + class + "\0" + turn.
interface CircuitEntry {
  consecutive: number;
  open: boolean;
  openedAtMs: number;
  probeInFlight: boolean;
}

const circuitStore = new Map<string, CircuitEntry>();

// Key components never contain "|" (server/turn charsets exclude it,
// class is a fixed set), so "|" separates unambiguously.
function circuitKey(server: string, mcpClass: McpClass, turn: string): string {
  return server + "|" + mcpClass + "|" + turn;
}

function readEntry(key: string): CircuitEntry | null {
  try {
    const e = circuitStore.get(key);
    if (!e || typeof e !== "object") return null;
    return e;
  } catch {
    return null;
  }
}

function writeEntry(key: string, e: CircuitEntry): void {
  try {
    mapSetBounded(circuitStore, key, e, MCP_CIRCUIT_CAP);
  } catch {
    // Fail-open bookkeeping: circuit write never breaks the call.
  }
}

// Releases a half-open probe reservation WITHOUT counting a
// failure: operator aborts and internal envelope errors are not
// server failures, so the streak and the cooldown origin are left
// untouched and the key is ready for the next probe once the
// cooldown expires. NEVER throws.
function releaseProbe(key: string): void {
  try {
    const e = readEntry(key);
    if (e && e.open && e.probeInFlight) {
      e.probeInFlight = false;
      writeEntry(key, e);
    }
  } catch {
    // Fail-open bookkeeping.
  }
}

// HOLD (documented residual, R-M1): the circuit store is bounded
// (MCP_CIRCUIT_CAP, oldest-first eviction). Evicting an OPEN entry
// loses its protection and the key reads CLOSED again. Loss of
// protection fails toward availability, never toward a stuck-open
// denial; the next two consecutive failures re-open normally.

export function getMcpCircuitSnapshot(
  server: unknown,
  mcpClass: unknown,
  turn: unknown,
  nowMs?: unknown,
): { state: "CLOSED" | "OPEN" | "HALF_OPEN" | "UNKNOWN"; consecutive: number } {
  try {
    const cls = normalizeMcpClass(mcpClass);
    if (cls === null) return { state: "UNKNOWN", consecutive: 0 };
    const srv = typeof server === "string" && isSafeServer(server.trim().toLowerCase())
      ? server.trim().toLowerCase()
      : "mcp";
    const key = circuitKey(srv, cls, normalizeMcpTurn(turn));
    const e = readEntry(key);
    if (!e) return { state: "CLOSED", consecutive: 0 };
    if (!e.open) return { state: "CLOSED", consecutive: e.consecutive };
    const now = toBoundedInt(nowMs, 0, 9007199254740991, Date.now());
    if (now >= e.openedAtMs + MCP_EMBEDDED_COOLDOWN_S * 1000) {
      return { state: "HALF_OPEN", consecutive: e.consecutive };
    }
    return { state: "OPEN", consecutive: e.consecutive };
  } catch {
    return { state: "UNKNOWN", consecutive: 0 };
  }
}

export function resetMcpTransport(): void {
  try {
    circuitStore.clear();
  } catch {
    // Fail-open.
  }
  try {
    transportConfig = { enforced: false, policyText: null, policyPath: null };
    clearPolicyCache();
    policyFileReader = null;
  } catch {
    // Fail-open.
  }
}

function nowOf(v: unknown): number {
  return toBoundedInt(v, 0, 9007199254740991, Date.now());
}

function validContract(c: McpContract | null | undefined): { ok: boolean; budgetS: number } {
  try {
    if (!c || typeof c !== "object") return { ok: false, budgetS: 0 };
    const id = (c as McpContract).id;
    if (typeof id !== "string" || id.trim().length === 0 || id.length > 128) {
      return { ok: false, budgetS: 0 };
    }
    const b = (c as McpContract).budgetSeconds;
    if (!isExactInt(b, 1, MCP_LONG_RUNNING_MAX_BUDGET_S)) return { ok: false, budgetS: 0 };
    return { ok: true, budgetS: b as number };
  } catch {
    return { ok: false, budgetS: 0 };
  }
}

function mapUnavailable(
  cause: string,
  criticality: McpCriticality,
  base: {
    engaged: boolean;
    server: string | null;
    mcpClass: McpClass | null;
    mode: McpMode;
    elapsedMs: number;
  },
): McpResult {
  const safeCause = isCausalCode(cause) ? cause : "MCP_INTERNAL";
  if (criticality === "required") {
    return {
      ok: false,
      status: "MCP_REQUIRED_BLOCKED",
      cause: safeCause,
      blocked: true,
      fallback_continue: false,
      engaged: base.engaged,
      server: base.server,
      mcpClass: base.mcpClass,
      criticality,
      mode: base.mode,
      elapsedMs: base.elapsedMs,
    };
  }
  return {
    ok: true,
    status: "MCP_UNAVAILABLE",
    cause: safeCause,
    blocked: false,
    fallback_continue: true,
    engaged: base.engaged,
    server: base.server,
    mcpClass: base.mcpClass,
    criticality,
    mode: base.mode,
    elapsedMs: base.elapsedMs,
  };
}

// Authority guard: no circuit or policy output ever grants, widens or
// carries permission. Any attempt to feed an MCP result into a grant
// path is denied. NEVER throws; denies every input including null.
export function mcpResultGrantsAuthority(_result: unknown): {
  granted: false;
  widened: false;
  status: "MCP_RESULT_CANNOT_GRANT";
} {
  return { granted: false, widened: false, status: "MCP_RESULT_CANNOT_GRANT" };
}

// Pre-execution observation for hook wiring (V2 execute.before):
// classifies the tool and reports whether the circuit WOULD block,
// without blocking, mutating state or throwing. The hook itself
// remains non-blocking; enforcement lives in runMcpGuarded.
export function observeMcpBeforeExecute(
  runtime: RuntimeId,
  fields: { tool: unknown; turn?: unknown; criticality?: unknown },
): { mcp: boolean; wouldBlock: boolean } {
  try {
    const c = classifyMcpTool(fields ? fields.tool : null);
    if (!c) return { mcp: false, wouldBlock: false };
    const turn = normalizeMcpTurn(fields ? fields.turn : null);
    const key = circuitKey(c.server, c.mcpClass, turn);
    const e = readEntry(key);
    let wouldBlock = false;
    let state = "CLOSED";
    try {
      if (e && e.open) {
        const now = Date.now();
        if (now < e.openedAtMs + MCP_EMBEDDED_COOLDOWN_S * 1000) {
          wouldBlock = true;
          state = "OPEN";
        } else if (e.probeInFlight) {
          wouldBlock = true;
          state = "HALF_OPEN_BUSY";
        } else {
          state = "HALF_OPEN";
        }
      }
    } catch {
      wouldBlock = false;
    }
    if (wouldBlock) {
      writeMcpEvent(runtime, {
        event: "would-block-circuit-open",
        server: c.server,
        mcpClass: c.mcpClass,
        criticality: normalizeMcpCriticality(fields ? fields.criticality : null),
        mode: "shadow",
        cause: "MCP_CIRCUIT_OPEN",
        turnLen: turn.length,
      });
    }
    void state;
    return { mcp: true, wouldBlock };
  } catch {
    return { mcp: false, wouldBlock: false };
  }
}

// Cancellable class deadline. The losing timer is ALWAYS cleared
// once any other outcome wins (no orphan timers pinning the event
// loop for 30/60/120s), with a guarded unref() as a complementary
// defense so a pending deadline alone never keeps the process
// alive. activeDeadlines is observability for tests (it must return
// to zero after every settled call). NEVER throws.
let activeDeadlines = 0;

export function pendingMcpDeadlines(): number {
  try {
    return activeDeadlines;
  } catch {
    return -1;
  }
}

function startDeadline(ms: number): { fired: Promise<boolean>; cancel: () => void } {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let done = false;
  const settle = (): void => {
    try {
      if (!done) {
        done = true;
        activeDeadlines = Math.max(0, activeDeadlines - 1);
      }
    } catch {
      // Fail-open accounting.
    }
  };
  try {
    activeDeadlines = activeDeadlines + 1;
  } catch {
    // Fail-open accounting.
  }
  const fired: Promise<boolean> = new Promise((resolve) => {
    const onFire = (): void => {
      timer = null;
      settle();
      try {
        resolve(true);
      } catch {
        // Fail-open.
      }
    };
    try {
      timer = setTimeout(onFire, ms);
    } catch {
      timer = null;
      settle();
      try {
        resolve(true);
      } catch {
        // Fail-open.
      }
      return;
    }
    try {
      const u = timer as unknown as { unref?: unknown };
      if (u && typeof u.unref === "function") {
        (u.unref as () => void).call(timer);
      }
    } catch {
      // Fail-open: unref is a best-effort defense only.
    }
  });
  const cancel = (): void => {
    try {
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
    } catch {
      // Fail-open.
    } finally {
      settle();
    }
  };
  return { fired, cancel };
}

export async function runMcpGuarded(opts: McpGuardedOptions): Promise<McpResult> {
  const wallStart = Date.now();
  // Conservative until the call's own criticality is normalized: an
  // irrecoverable input (null opts, hostile getters before the
  // criticality read) stays required and therefore fail-closed.
  // probeKey tracks a reserved half-open probe so ANY abnormal exit
  // can release it without counting a server failure.
  let callCriticality: McpCriticality = "required";
  let probeKey: string | null = null;
  try {
    if (!opts || typeof opts !== "object" || typeof opts.execute !== "function") {
      return {
        ok: false,
        status: "MCP_REQUIRED_BLOCKED",
        cause: "MCP_INTERNAL",
        blocked: true,
        fallback_continue: false,
        engaged: true,
        server: null,
        mcpClass: null,
        criticality: "required",
        mode: "shadow",
        elapsedMs: 0,
      };
    }
    // R1: unknown tools are NEVER MCP: transparent pass-through, the
    // envelope does not engage (no timeout, no circuit, no shaping).
    // Returned WITHOUT await so a rejection propagates exactly as
    // the host would see it without the envelope (the outer catch
    // below must not reshape foreign failures).
    const classification = classifyMcpTool(opts.tool);
    if (!classification) {
      return opts.execute().then((value: unknown) => {
        return {
          ok: true,
          status: "MCP_BYPASS_NOT_MCP",
          cause: null,
          blocked: false,
          fallback_continue: false,
          engaged: false,
          server: null,
          mcpClass: null,
          criticality: normalizeMcpCriticality(opts.criticality),
          mode: "shadow",
          elapsedMs: Math.max(0, Date.now() - wallStart),
          value,
        } as McpResult;
      });
    }
    const server = classification.server;
    const criticality = normalizeMcpCriticality(opts.criticality);
    callCriticality = criticality;
    const turn = normalizeMcpTurn(opts.turn);
    const eff = effectiveMcpMode(opts.mode);
    const mode = eff.mode;
    const effPolicy = effectivePolicy(opts.policyText, opts.policyPath);
    const policy = effPolicy.policy;
    if (effPolicy.invalidOrigin !== null) {
      try {
        writeMcpEvent("v2", {
          event: "policy-fallback",
          server,
          mcpClass: classification.mcpClass,
          criticality,
          mode,
          turnLen: turn.length,
          origin: effPolicy.invalidOrigin,
        });
      } catch {
        // Fail-open telemetry.
      }
    }
    const mcpClass: McpClass = normalizeMcpClass(opts.classOverride) ?? classification.mcpClass;
    const base = {
      engaged: true,
      server,
      mcpClass,
      mode,
      elapsedMs: 0,
    };
    if (eff.denied) {
      try {
        writeMcpEvent("v2", {
          event: "enforce-denied-shadow",
          server,
          mcpClass,
          criticality,
          mode,
          turnLen: turn.length,
        });
      } catch {
        // Fail-open telemetry.
      }
    }
    // Long-running calls carry no default budget: without an
    // explicit task contract, ENFORCED mode refuses structurally
    // before executing, while SHADOW only observes (would-refuse
    // telemetry) and lets the call proceed with no deadline
    // envelope, per the shadow contract of never altering
    // admission.
    let budgetMs = 0;
    let unbounded = false;
    if (mcpClass === "long_running") {
      const vc = validContract(opts.contract === undefined ? null : opts.contract);
      if (!vc.ok) {
        if (mode === "shadow") {
          try {
            writeMcpEvent("v2", {
              event: "would-refuse-long-running",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_LONG_RUNNING_REQUIRES_CONTRACT",
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
          unbounded = true;
          budgetMs = 86400000;
        } else {
          try {
            writeMcpEvent("v2", {
              event: "refusal-long-running",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_LONG_RUNNING_REQUIRES_CONTRACT",
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
          const r = mapUnavailable("MCP_LONG_RUNNING_REQUIRES_CONTRACT", criticality, base);
          r.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r;
        }
      } else {
        budgetMs = vc.budgetS * 1000;
      }
    } else {
      const perClass = policy.budgetsS[mcpClass];
      const secs = typeof perClass === "number" ? perClass : 120;
      budgetMs = secs * 1000;
    }
    // A caller-supplied tightening only narrows a real budget,
    // never widens it; unbounded shadow long-running calls skip it
    // so no deadline envelope applies.
    if (!unbounded) {
      const tight = toBoundedInt(opts.tightenBudgetMs, 1, budgetMs, budgetMs);
      budgetMs = tight;
    }
    const key = circuitKey(server, mcpClass, turn);
    const nowAdm = nowOf(opts.nowMs);
    const cooldownMs = policy.cooldownS * 1000;
    const threshold = policy.failureThreshold;
    // Admission (ENFORCED only): OPEN inside cooldown fast-fails
    // without executing; past cooldown exactly one half-open probe
    // runs while concurrent contenders fast-fail. SHADOW never
    // cancels: it records would-block and executes anyway.
    let isProbe = false;
    if (mode === "enforced") {
      const e = readEntry(key);
      if (e && e.open) {
        if (nowAdm < e.openedAtMs + cooldownMs) {
          try {
            writeMcpEvent("v2", {
              event: "circuit-block",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_CIRCUIT_OPEN",
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
          const r = mapUnavailable("MCP_CIRCUIT_OPEN", criticality, base);
          r.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r;
        }
        if (e.probeInFlight) {
          try {
            writeMcpEvent("v2", {
              event: "circuit-block",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_HALF_OPEN_BUSY",
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
          const r = mapUnavailable("MCP_CIRCUIT_OPEN", criticality, base);
          r.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r;
        }
        e.probeInFlight = true;
        writeEntry(key, e);
        isProbe = true;
        probeKey = key;
        try {
          writeMcpEvent("v2", {
            event: "half-open-probe",
            server,
            mcpClass,
            criticality,
            mode,
            turnLen: turn.length,
          });
        } catch {
          // Fail-open telemetry.
        }
      }
    } else {
      const e = readEntry(key);
      if (e && e.open) {
        const busy = nowAdm < e.openedAtMs + cooldownMs || e.probeInFlight;
        void busy;
        try {
          writeMcpEvent("v2", {
            event: "would-block-circuit-open",
            server,
            mcpClass,
            criticality,
            mode,
            cause: "MCP_CIRCUIT_OPEN",
            turnLen: turn.length,
          });
        } catch {
          // Fail-open telemetry.
        }
      }
    }
    // Abort-safe: a pre-aborted signal refuses WITHOUT executing in
    // ENFORCED mode (and without touching the circuit: operator
    // abort is not server failure), while SHADOW only observes
    // (would-refuse telemetry) and lets the call proceed: the host
    // owns the abort and the envelope never interferes with
    // admission. A mid-flight abort abandons like a timeout but
    // also leaves the circuit untouched.
    try {
      const sig = opts.signal;
      if (sig && typeof sig === "object" && (sig as AbortSignal).aborted === true) {
        if (mode === "shadow") {
          try {
            writeMcpEvent("v2", {
              event: "would-refuse-aborted",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_ABORTED",
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
        } else {
          try {
            writeMcpEvent("v2", {
              event: "refusal-aborted",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_ABORTED",
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
          if (isProbe) {
            releaseProbe(key);
          }
          const r = mapUnavailable("MCP_ABORTED", criticality, base);
          r.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r;
        }
      }
    } catch {
      // Fail-open: a hostile signal object never breaks admission.
    }
    // Conclusion clock: an injected nowMs pins both admission and
    // conclusion (deterministic cooldown tests); otherwise the wall
    // clock is read at conclusion, so the cooldown is always measured
    // from the CONCLUSION of the failing call, never its start.
    const conclusionNow = (): number => {
      try {
        if (opts.nowMs !== undefined) return nowAdm;
        return nowOf(Date.now());
      } catch {
        return nowAdm;
      }
    };
    const recordSuccess = (concludedAt: number): void => {      try {
        const prev = readEntry(key);
        const wasProbe = isProbe || (prev !== null && prev.open);
        writeEntry(key, { consecutive: 0, open: false, openedAtMs: 0, probeInFlight: false });
        if (wasProbe) {
          try {
            writeMcpEvent("v2", {
              event: "rearm",
              server,
              mcpClass,
              criticality,
              mode,
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
        }
        void concludedAt;
      } catch {
        // Fail-open bookkeeping.
      }
    };
    const recordFailure = (concludedAt: number): void => {
      try {
        const prev = readEntry(key);
        const consecutive = (prev ? prev.consecutive : 0) + 1;
        if (consecutive >= threshold) {
          writeEntry(key, {
            consecutive,
            open: true,
            openedAtMs: concludedAt,
            probeInFlight: false,
          });
          try {
            writeMcpEvent("v2", {
              event: "circuit-open",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_TIMEOUT",
              turnLen: turn.length,
            });
          } catch {
            // Fail-open telemetry.
          }
        } else {
          writeEntry(key, {
            consecutive,
            open: prev ? prev.open : false,
            openedAtMs: prev ? prev.openedAtMs : 0,
            probeInFlight: false,
          });
        }
      } catch {
        // Fail-open bookkeeping.
      }
    };
    if (mode === "shadow") {
      // Shadow observes: the execution is NEVER cancelled. An overrun
      // is recorded as a would-timeout (same circuit weight as a
      // timeout) but the underlying outcome is returned as-is.
      const t0 = Date.now();
      let value: unknown = undefined;
      let failed = false;
      try {
        value = await opts.execute();
      } catch {
        failed = true;
      }
      const elapsed = Math.max(0, Date.now() - t0);
      const concluded = nowOf(opts.nowMs !== undefined ? opts.nowMs : Date.now());
      if (failed) {
        recordFailure(concluded);
        const r = mapUnavailable("MCP_ERROR", criticality, base);
        r.elapsedMs = elapsed;
        return r;
      }
      // Unbounded shadow long-running calls never trip the
      // would-timeout comparison: there is no budget to overrun.
      if (!unbounded && elapsed > budgetMs) {
        recordFailure(concluded);
        try {
          writeMcpEvent("v2", {
            event: "would-timeout",
            server,
            mcpClass,
            criticality,
            mode,
            cause: "MCP_TIMEOUT",
            turnLen: turn.length,
            elapsedMs: elapsed,
            budgetMs,
          });
        } catch {
          // Fail-open telemetry.
        }
      } else {
        recordSuccess(concluded);
      }
      return {
        ok: true,
        status: "OK",
        cause: null,
        blocked: false,
        fallback_continue: false,
        engaged: true,
        server,
        mcpClass,
        criticality,
        mode,
        elapsedMs: elapsed,
        value,
      };
    }
    // Enforced: race the execution against the class deadline. The
    // execution promise is wrapped so it can NEVER reject unobserved:
    // on overrun it is abandoned (no rollback: already-started native
    // work may still complete its effects) with its settlement
    // handler attached synchronously at creation.
    type Settled = { kind: "value"; value: unknown } | { kind: "error" } | { kind: "timeout" } | { kind: "aborted" };
    let abortListener: (() => void) | null = null;
    const execP: Promise<Settled> = (async (): Promise<Settled> => {
      try {
        const v = await opts.execute();
        return { kind: "value", value: v };
      } catch {
        return { kind: "error" };
      }
    })();
    // The deadline is cancellable: whichever outcome wins clears
    // the loser timer, so no orphan timer pins the event loop.
    const deadline = startDeadline(budgetMs);
    let settled: Settled = { kind: "error" };
    try {
      const timerP: Promise<Settled> = deadline.fired.then((): Settled => ({ kind: "timeout" }));
      let raceP: Promise<Settled> = Promise.race([execP, timerP]);
      const sig = opts.signal;
      if (sig && typeof sig === "object" && typeof (sig as AbortSignal).addEventListener === "function") {
        const abortP: Promise<Settled> = new Promise((resolve) => {
          abortListener = () => {
            try {
              resolve({ kind: "aborted" });
            } catch {
              // Fail-open.
            }
          };
          try {
            (sig as AbortSignal).addEventListener("abort", abortListener as () => void, { once: true });
          } catch {
            // Fail-open: signal without listener support.
          }
        });
        raceP = Promise.race([execP, timerP, abortP]);
      }
      try {
        settled = await raceP;
      } catch {
        settled = { kind: "error" };
      }
    } finally {
      // Guaranteed cleanup on EVERY exit past timer creation
      // (value, timeout, abort, or an internal throw such as a
      // hostile signal getter): the loser timer is cancelled and
      // the abort listener detached. Cancel-on-settle plus the
      // guarded unref at creation is preserved.
      try {
        deadline.cancel();
      } catch {
        // Fail-open: the timer is unref'd, so a missed cancel only
        // wastes one bounded wait, never the process.
      }
      try {
        const s = opts.signal;
        if (s && typeof s === "object" && abortListener !== null && typeof (s as AbortSignal).removeEventListener === "function") {
          (s as AbortSignal).removeEventListener("abort", abortListener as () => void);
        }
      } catch {
        // Fail-open listener cleanup.
      }
    }
    // Swallow a late abort after the race already settled.
    void abortListener;
    const elapsed = Math.max(0, Date.now() - wallStart);
    if (settled.kind === "value") {
      recordSuccess(conclusionNow());
      return {
        ok: true,
        status: "OK",
        cause: null,
        blocked: false,
        fallback_continue: false,
        engaged: true,
        server,
        mcpClass,
        criticality,
        mode,
        elapsedMs: elapsed,
        value: (settled as { kind: "value"; value: unknown }).value,
      };
    }
    if (settled.kind === "aborted") {
      // A mid-flight abort abandons like a timeout but is NOT a
      // server failure: the probe reservation (if any) is released
      // without touching the streak or the cooldown origin.
      if (isProbe) {
        releaseProbe(key);
      }
      try {
        writeMcpEvent("v2", {
          event: "refusal-aborted",
          server,
          mcpClass,
          criticality,
          mode,
          cause: "MCP_ABORTED",
          turnLen: turn.length,
        });
      } catch {
        // Fail-open telemetry.
      }
      const r = mapUnavailable("MCP_ABORTED", criticality, base);
      r.elapsedMs = elapsed;
      return r;
    }
    if (settled.kind === "timeout") {
      recordFailure(conclusionNow());
      try {
        writeMcpEvent("v2", {
          event: "timeout",
          server,
          mcpClass,
          criticality,
          mode,
          cause: "MCP_TIMEOUT",
          turnLen: turn.length,
          elapsedMs: elapsed,
          budgetMs,
        });
      } catch {
        // Fail-open telemetry.
      }
    } else {
      recordFailure(conclusionNow());
    }
    const cause = settled.kind === "timeout" ? "MCP_TIMEOUT" : "MCP_ERROR";
    const r = mapUnavailable(cause, criticality, base);
    r.elapsedMs = elapsed;
    return r;
  } catch {
    // The envelope NEVER throws. An internal error releases any
    // reserved probe WITHOUT counting a server failure, then
    // returns a structured refusal (fail-closed for the engaged
    // call; hook wrappers stay fail-open for the host by swallowing
    // everything themselves). The call's own criticality is
    // preserved when it could be normalized (optional stays a
    // fallback); only a truly irrecoverable input keeps the
    // conservative required default.
    try {
      if (probeKey !== null) {
        try {
          releaseProbe(probeKey);
        } catch {
          // Fail-open.
        }
      }
    } catch {
      // Fail-open.
    }
    try {
      const r = mapUnavailable("MCP_INTERNAL", callCriticality, {
        engaged: true,
        server: null,
        mcpClass: null,
        mode: "shadow",
        elapsedMs: Math.max(0, Date.now() - wallStart),
      });
      return r;
    } catch {
      return {
        ok: false,
        status: "MCP_REQUIRED_BLOCKED",
        cause: "MCP_INTERNAL",
        blocked: true,
        fallback_continue: false,
        engaged: true,
        server: null,
        mcpClass: null,
        criticality: "required",
        mode: "shadow",
        elapsedMs: 0,
      };
    }
  }
}

// Test-only introspection (additive; no runtime effect).
export const __mcpTransportTest = {
  circuitSize: (): number => {
    try {
      return circuitStore.size;
    } catch {
      return -1;
    }
  },
  pendingDeadlines: (): number => {
    try {
      return pendingMcpDeadlines();
    } catch {
      return -1;
    }
  },
  reset: (): void => {
    resetMcpTransport();
  },
};
