// Single rule set for agent identity shared by both runtime adapters.
// PURE: imports only sibling shared modules, never a runtime package.
// The canonical 19-worker list lives HERE; adapters must not restate it.
import type { IdentitySource, Role, RoleResolution, SessionEntry } from "./types";
import { mapSetBounded } from "./sanitize";

// Long-lived host processes create one entry per session: cap the index
// with oldest-first eviction. Cap-only by choice: session-termination
// event shapes are uncertain across builds, so explicit cleanup would be
// clever and fragile. Same guideline as the V1 original.
export const INDEX_CAP = 5000;

export const WORKER_AGENT_NAMES: ReadonlyArray<string> = [
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
];

export const WORKER_AGENTS: ReadonlySet<string> = new Set(WORKER_AGENT_NAMES);
export const PLANNER_AGENTS: ReadonlySet<string> = new Set(["build", "primary", "planner", "main"]);

export function normalizeAgentName(v: unknown): string {
  try {
    if (typeof v !== "string") return "";
    return v.trim().toLowerCase();
  } catch {
    return "";
  }
}

export function roleFromAgentName(name: string | undefined): Role | null {
  try {
    const n = normalizeAgentName(name);
    if (n.length === 0) return null;
    if (PLANNER_AGENTS.has(n)) return "planner";
    if (WORKER_AGENTS.has(n)) return "worker";
    return null;
  } catch {
    return null;
  }
}

// Session-map resolution: parentID present => worker (a subagent session
// spawned with parentID = parent sessionID); otherwise a recognized agent
// name maps to its role. Unrecognized/absent => null (caller falls back
// to probing the hook input).
export function roleFromSessionEntry(entry: SessionEntry): Role | null {
  try {
    const parentID = typeof entry.parentID === "string" ? entry.parentID.trim() : "";
    if (parentID.length > 0) return "worker";
    return roleFromAgentName(entry.agent);
  } catch {
    return null;
  }
}

// Priority: (a) explicit agent field on the hook input; (b) session /
// session-info / metadata nesting; (c) other runtime/context nesting on
// the same input object. Every path below is best-effort probing of extra
// runtime fields; absence => undefined.
export function readAgent(input: unknown): string | undefined {
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

export function readSessionID(input: unknown): string | undefined {
  try {
    const v = input as any;
    if (!v || typeof v !== "object") return undefined;
    const c = v.sessionID ?? v.sessionId ?? v.session_id ?? v?.info?.id;
    return typeof c === "string" && c.length > 0 ? c : undefined;
  } catch {
    return undefined;
  }
}

export function lookupSession(
  map: Map<string, SessionEntry>,
  sessionId: string | undefined,
): SessionEntry | undefined {
  try {
    if (typeof sessionId !== "string" || sessionId.length === 0) return undefined;
    return map.get(sessionId);
  } catch {
    return undefined;
  }
}

export function indexSession(map: Map<string, SessionEntry>, id: string, value: SessionEntry): void {
  mapSetBounded(map, id, value, INDEX_CAP);
}

// Full identity chain: session-map first, hook-input probe fallback,
// conservative neutral otherwise. Mirrors the V1 original exactly.
export function resolveRole(
  entry: SessionEntry | undefined,
  probeAgent: string | undefined,
): RoleResolution {
  try {
    if (entry) {
      const viaMap = roleFromSessionEntry(entry);
      if (viaMap === "worker") {
        return { role: "worker", agent: entry.agent, source: "session-map" as IdentitySource };
      }
      if (viaMap === "planner") {
        return { role: "planner", agent: entry.agent, source: "session-map" as IdentitySource };
      }
    }
    const viaProbe = roleFromAgentName(probeAgent);
    if (viaProbe === "planner") {
      return { role: "planner", agent: probeAgent, source: "input-probe" as IdentitySource };
    }
    if (viaProbe === "worker") {
      return { role: "worker", agent: probeAgent, source: "input-probe" as IdentitySource };
    }
    return { role: "neutral", agent: probeAgent, source: "none" as IdentitySource };
  } catch {
    return { role: "neutral", agent: undefined, source: "none" as IdentitySource };
  }
}

// Tolerant `event` envelope reader: accepts { event: { type, properties:
// { info } } }, flattened { type, properties }, or direct { info } shapes.
// Unknown shapes => no-op. NEVER throws; lifecycle events only populate
// the in-memory index passed in.
export function recordSessionEvent(map: Map<string, SessionEntry>, input: unknown): void {
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
    const prev = map.get(id);
    if (prev) {
      if (next.parentID !== undefined) prev.parentID = next.parentID;
      if (next.agent !== undefined) prev.agent = next.agent;
      indexSession(map, id, prev);
    } else {
      indexSession(map, id, next);
    }
  } catch {
    // Fail-open: event indexing never breaks the session.
  }
}
