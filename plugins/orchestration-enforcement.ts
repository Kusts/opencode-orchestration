import type { Plugin } from "@opencode-ai/plugin";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Substring covering both markers (planner/neutral + worker suffix).
const MARKER_SUBSTRING = "orchestration-enforcement:v1";
const PLANNER_MARKER = "[orchestration-enforcement:v1]";
const WORKER_MARKER = "[orchestration-enforcement:v1:worker]";

const WORKER_AGENTS = new Set([
  "explorer",
  "researcher",
  "coder",
  "tester",
  "reviewer",
  "debugger",
  "security-reviewer",
  "architect",
  "docs-manager",
  "frontend-engineer",
  "backend-engineer",
  "database-engineer",
  "ai-agent-engineer",
  "automation-engineer",
  "infra-engineer",
  "requirements-analyst",
  "engineering-advisor",
  "product-designer",
  "skeptic",
]);

const PLANNER_AGENTS = new Set(["build", "primary", "planner", "main"]);

const PLANNER_MANDATE = [
  "Mandatory orchestration preflight before the first action: classify the task as TRIVIAL_DIRECT (only with a closed reason token: DIRECT_TRIVIAL_LOCALIZED, DIRECT_READ_ONLY_POINT_LOOKUP, DIRECT_COSMETIC_NO_LOGIC, DIRECT_FORMATTING_ONLY), DELEGATED, DETERMINISTIC_FALLBACK, or BLOCKED.",
  "Non-trivial tasks require material participation of at least one suitable subagent; doing everything alone without a recorded decision is ORCHESTRATION_POLICY_BYPASS.",
  "For relevant changes, follow the coder → tester → reviewer cycle and integrate their syntheses. DONE requires observed worker participation on non-trivial work.",
  "",
  PLANNER_MARKER,
].join("\n");

const WORKER_MANDATE = [
  "You are a bounded specialist executing a delegated scope; do not orchestrate.",
  "Do not create or invoke other subagents (the task tool is unavailable/denied to you).",
  "Stay inside your delegated scope and preserve contracts and unrelated work.",
  "Return a compact structured result with STATUS, KEY_FINDINGS, EVIDENCE, VALIDATION, RISKS, RECOMMENDATION.",
  "",
  WORKER_MARKER,
].join("\n");

const NEUTRAL_MANDATE = [
  "Follow the project's orchestration policy for this session.",
  "Specialists never create subagents; the primary agent runs orchestration preflight for non-trivial work.",
  "",
  PLANNER_MARKER,
].join("\n");

type SessionType = "planner" | "worker" | "unknown";
type MandateKind = "planner" | "worker" | "neutral";
type IdentitySource = "session-map" | "input-probe" | "none";

interface SessionEntry {
  parentID?: string;
  agent?: string;
}

// Lifecycle session index: `event` hooks deliver session.created/updated
// with `{ info: Session }` where Session.agent/parentID reveal worker
// sessions (task-spawned subagents get parentID = parent sessionID). The
// typed system.transform input only exposes { sessionID?, model }, so this
// map is the primary identity signal; input probing stays as fallback.
//
// Bound: long-lived OpenCode processes create one entry per session, so both
// this map and `logged` below are capped at INDEX_CAP entries with
// oldest-first eviction (Map/Set preserve insertion order). Cap-only by
// choice: the session-termination event shape (`session.deleted` /
// `session.idle`) is uncertain across builds, so explicit cleanup would be
// clever and fragile — simple and correct wins (same guideline as before).
const INDEX_CAP = 5_000;

const sessionIndex = new Map<string, SessionEntry>();

// Bounded insert: evict the oldest entry when a NEW key arrives at capacity;
// updates to existing keys never grow the map. NEVER throws.
function indexSet(id: string, value: SessionEntry): void {
  try {
    if (!sessionIndex.has(id) && sessionIndex.size >= INDEX_CAP) {
      const oldest = sessionIndex.keys().next();
      if (!oldest.done) sessionIndex.delete(oldest.value);
    }
    sessionIndex.set(id, value);
  } catch {
    // Fail-open: indexing never breaks the session.
  }
}

// Fail-safe client capture. Reserved for a future one-shot
// client.session.get lookup — NOT used today: the event map alone is
// authoritative, and an extra fetch would add async failure modes inside
// the injection path for no guaranteed signal (client shape varies across
// 1.18.x builds). Simple and correct beats clever and fragile here.
let sessionClient: any = undefined;

// Priority: (a) explicit agent field on the hook input; (b) session/session-info/
// metadata nesting; (c) other runtime/context nesting on the same input object.
// The TYPED hook signature only exposes { sessionID?, model }, so every path
// below is best-effort probing of extra runtime fields; absence => unknown.
function readAgent(input: unknown): string | undefined {
  try {
    const v = input as any;
    if (!v || typeof v !== "object") return undefined;
    const direct = [v.agent, v.agentName, v.agent_name, v.agentID, v.agentId];
    for (const c of direct) {
      if (typeof c === "string" && c.trim().length > 0) return c.trim();
    }
    const nested = [v.session, v.sessionInfo, v.metadata, v.info, v.context, v.runtime];
    for (const n of nested) {
      if (!n || typeof n !== "object") continue;
      const c = n.agent ?? n.agentName ?? n.agent_name;
      if (typeof c === "string" && c.trim().length > 0) return c.trim();
    }
    return undefined;
  } catch {
    return undefined;
  }
}

function lookupSession(sessionId: string | undefined): SessionEntry | undefined {
  try {
    if (typeof sessionId !== "string" || sessionId.length === 0) return undefined;
    return sessionIndex.get(sessionId);
  } catch {
    return undefined;
  }
}

// Session-map resolution: parentID present => WORKER (subagent spawned with
// parentID = parent sessionID); otherwise a recognized agent name maps to
// its mandate. Unrecognized/absent => null (caller falls back to probing).
function resolveViaMap(entry: SessionEntry): {
  sessionType: SessionType;
  agent: string | undefined;
  mandate: string;
  mandateKind: MandateKind;
  markerUsed: string;
} | null {
  try {
    const parentID = typeof entry.parentID === "string" ? entry.parentID.trim() : "";
    if (parentID.length > 0) {
      return { sessionType: "worker", agent: entry.agent, mandate: WORKER_MANDATE, mandateKind: "worker", markerUsed: WORKER_MARKER };
    }
    const name = typeof entry.agent === "string" ? entry.agent.trim().toLowerCase() : "";
    if (name.length > 0 && PLANNER_AGENTS.has(name)) {
      return { sessionType: "planner", agent: entry.agent, mandate: PLANNER_MANDATE, mandateKind: "planner", markerUsed: PLANNER_MARKER };
    }
    if (name.length > 0 && WORKER_AGENTS.has(name)) {
      return { sessionType: "worker", agent: entry.agent, mandate: WORKER_MANDATE, mandateKind: "worker", markerUsed: WORKER_MARKER };
    }
    return null;
  } catch {
    return null;
  }
}

function classify(input: unknown, entry?: SessionEntry | undefined): {
  sessionType: SessionType;
  agent: string | undefined;
  mandate: string;
  mandateKind: MandateKind;
  markerUsed: string;
  identitySource: IdentitySource;
} {
  if (entry) {
    const viaMap = resolveViaMap(entry);
    if (viaMap) return { ...viaMap, identitySource: "session-map" as IdentitySource };
  }
  const agent = readAgent(input);
  const name = agent?.toLowerCase();
  if (name && PLANNER_AGENTS.has(name)) {
    return { sessionType: "planner", agent, mandate: PLANNER_MANDATE, mandateKind: "planner", markerUsed: PLANNER_MARKER, identitySource: "input-probe" };
  }
  if (name && WORKER_AGENTS.has(name)) {
    return { sessionType: "worker", agent, mandate: WORKER_MANDATE, mandateKind: "worker", markerUsed: WORKER_MARKER, identitySource: "input-probe" };
  }
  // Unknown agent (absent or unrecognized) => conservative neutral mandate.
  return { sessionType: "unknown", agent, mandate: NEUTRAL_MANDATE, mandateKind: "neutral", markerUsed: PLANNER_MARKER, identitySource: "none" };
}

function sessionID(input: unknown): string | undefined {
  try {
    const value = input as any;
    if (!value || typeof value !== "object") return undefined;
    const c = value.sessionID ?? value.sessionId ?? value.session_id ?? value?.info?.id;
    return typeof c === "string" && c.length > 0 ? c : undefined;
  } catch {
    return undefined;
  }
}

// Logged once per (session, marker) to avoid unbounded log growth; also
// capped at INDEX_CAP entries (same oldest-first eviction rationale as
// sessionIndex above). NEVER throws.
const logged = new Set<string>();

function loggedAdd(key: string): void {
  try {
    if (!logged.has(key) && logged.size >= INDEX_CAP) {
      const oldest = logged.values().next();
      if (!oldest.done) logged.delete(oldest.value);
    }
    logged.add(key);
  } catch {
    // Fail-open: bookkeeping never breaks the session.
  }
}

// Identifiers are untrusted probed input: only persist trimmed strings up to
// 64 chars in a safe charset; anything else is omitted from telemetry.
function isSafeId(v: unknown): v is string {
  if (typeof v !== "string") return false;
  const t = v.trim();
  if (t.length === 0 || t.length > 64) return false;
  return /^[A-Za-z0-9._:@-]*$/.test(t);
}

function telemetry(entry: {
  sessionType: SessionType;
  agent: string | undefined;
  mandateKind: MandateKind;
  markerUsed: string;
  session: string | undefined;
  identitySource: IdentitySource;
}): void {
  try {
    const agent = isSafeId(entry.agent) ? (entry.agent as string).trim() : undefined;
    const session = isSafeId(entry.session) ? (entry.session as string).trim() : undefined;
    const key = (session ?? "null") + "::" + entry.markerUsed;
    if (logged.has(key)) return;
    const dir = join(homedir(), ".opencode-orchestration", "evidence", "v3", "orchestration");
    mkdirSync(dir, { recursive: true });
    const line: Record<string, string> = {
      ts: new Date().toISOString(),
      sessionType: entry.sessionType,
      mandate: entry.mandateKind,
      markerUsed: entry.markerUsed,
      identity_source: entry.identitySource,
    };
    if (agent) line["agent"] = agent;
    if (session) line["session"] = session;
    appendFileSync(join(dir, "session-injections.jsonl"), JSON.stringify(line) + "\n", "utf8");
    loggedAdd(key);
  } catch {
    // Fail-open: telemetry never breaks the session.
  }
}

// Tolerant `event` envelope reader: accepts { event: { type, properties: { info } } },
// flattened { type, properties }, or direct { info } shapes. Unknown shapes => no-op.
// NEVER throws; session lifecycle events only populate the in-memory index.
function recordEvent(input: unknown): void {
  try {
    const v = input as any;
    if (!v || typeof v !== "object") return;
    const ev = v.event;
    const type =
      (ev && typeof ev.type === "string" ? (ev.type as string) : undefined) ??
      (typeof v.type === "string" ? (v.type as string) : undefined);
    if (type !== "session.created" && type !== "session.updated") return;
    const props = (ev && typeof ev === "object" ? ev.properties : undefined) ?? v.properties;
    const info = props?.info ?? props?.session ?? v?.info ?? v?.session;
    if (!info || typeof info !== "object") return;
    const id: unknown = info.id ?? info.sessionID ?? info.sessionId ?? info.session_id;
    if (typeof id !== "string" || id.length === 0) return;
    const rawParent: unknown = info.parentID ?? info.parentId ?? info.parent_id;
    const rawAgent: unknown = info.agent ?? info.agentName ?? info.agent_name;
    const next: SessionEntry = {};
    if (typeof rawParent === "string" && rawParent.length > 0) next.parentID = rawParent;
    if (typeof rawAgent === "string" && rawAgent.length > 0) next.agent = rawAgent;
    const prev = sessionIndex.get(id);
    if (prev) {
      if (next.parentID !== undefined) prev.parentID = next.parentID;
      if (next.agent !== undefined) prev.agent = next.agent;
      indexSet(id, prev);
    } else {
      indexSet(id, next);
    }
  } catch {
    // Fail-open: event indexing never breaks the session.
  }
}

export const OrchestrationEnforcement: Plugin = async (ctx: any) => {
  try {
    const c = (ctx as any)?.client;
    if (c) sessionClient = c;
  } catch {
    // Fail-safe: run without a client (event-map + input-probe modes).
  }
  void sessionClient;
  return {
    event: async (input: any, _output: any) => {
      try {
        recordEvent(input);
      } catch {
        // NEVER throw out of a lifecycle hook.
      }
    },
    "experimental.chat.system.transform": async (input: any, output: any) => {
      let pending: {
        sessionType: SessionType;
        agent: string | undefined;
        mandateKind: MandateKind;
        markerUsed: string;
        session: string | undefined;
        identitySource: IdentitySource;
      } | null = null;
      try {
        const out = output as any;
        if (!out || typeof out !== "object") return;
        const inp = input as any;
        if (!inp || typeof inp !== "object" || Array.isArray(inp)) return; // malformed/array hook input => fail-safe
        const system = out.system;
        if (!Array.isArray(system)) return;
        // Fail-safe: every system entry must be a string BEFORE any mutation.
        if (!system.every((item: unknown) => typeof item === "string")) return;
        // 1. Idempotence: any entry already carrying a marker => no-op.
        for (const item of system) {
          if ((item as string).includes(MARKER_SUBSTRING)) return;
        }
        // 2./3. Identity: session-map first, input-probe fallback, else neutral.
        // Coalesce into system[0], or create the first entry.
        const sid = sessionID(input);
        const c = classify(input, lookupSession(sid));
        if (system.length === 0) {
          system.push(c.mandate);
        } else if (typeof system[0] === "string") {
          system[0] = system[0].length > 0 ? system[0] + "\n\n" + c.mandate : c.mandate;
        } else {
          return; // malformed first entry => fail-safe, no injection
        }
        pending = { sessionType: c.sessionType, agent: c.agent, mandateKind: c.mandateKind, markerUsed: c.markerUsed, session: sid, identitySource: c.identitySource };
      } catch {
        return; // fail-safe silent: no injection, no crash
      }
      if (pending) telemetry(pending);
    },
  } as any;
};

export default OrchestrationEnforcement;

// Test-only introspection for the harness (additive export; no runtime effect).
export const __orchestrationEnforcementTest = {
  cap: INDEX_CAP,
  sessionIndexSize: (): number => {
    try {
      return sessionIndex.size;
    } catch {
      return -1;
    }
  },
  loggedSize: (): number => {
    try {
      return logged.size;
    } catch {
      return -1;
    }
  },
};
