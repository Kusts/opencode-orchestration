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
  "For relevant changes, follow the coder \u2192 tester \u2192 reviewer cycle and integrate their syntheses. DONE requires observed worker participation on non-trivial work.",
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

function classify(input: unknown): {
  sessionType: SessionType;
  agent: string | undefined;
  mandate: string;
  mandateKind: MandateKind;
  markerUsed: string;
} {
  const agent = readAgent(input);
  const name = agent?.toLowerCase();
  if (name && PLANNER_AGENTS.has(name)) {
    return { sessionType: "planner", agent, mandate: PLANNER_MANDATE, mandateKind: "planner", markerUsed: PLANNER_MARKER };
  }
  if (name && WORKER_AGENTS.has(name)) {
    return { sessionType: "worker", agent, mandate: WORKER_MANDATE, mandateKind: "worker", markerUsed: WORKER_MARKER };
  }
  // Unknown agent (absent or unrecognized) => conservative neutral mandate.
  return { sessionType: "unknown", agent, mandate: NEUTRAL_MANDATE, mandateKind: "neutral", markerUsed: PLANNER_MARKER };
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

// Logged once per (session, marker) to avoid unbounded log growth.
const logged = new Set<string>();

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
    };
    if (agent) line["agent"] = agent;
    if (session) line["session"] = session;
    appendFileSync(join(dir, "session-injections.jsonl"), JSON.stringify(line) + "\n", "utf8");
    logged.add(key);
  } catch {
    // Fail-open: telemetry never breaks the session.
  }
}

export const OrchestrationEnforcement: Plugin = async () => {
  return {
    "experimental.chat.system.transform": async (input, output) => {
      let pending: {
        sessionType: SessionType;
        agent: string | undefined;
        mandateKind: MandateKind;
        markerUsed: string;
        session: string | undefined;
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
        // 2./3. Coalesce into system[0], or create the first entry.
        const c = classify(input);
        if (system.length === 0) {
          system.push(c.mandate);
        } else if (typeof system[0] === "string") {
          system[0] = system[0].length > 0 ? system[0] + "\n\n" + c.mandate : c.mandate;
        } else {
          return; // malformed first entry => fail-safe, no injection
        }
        pending = { sessionType: c.sessionType, agent: c.agent, mandateKind: c.mandateKind, markerUsed: c.markerUsed, session: sessionID(input) };
      } catch {
        return; // fail-safe silent: no injection, no crash
      }
      if (pending) telemetry(pending);
    },
  } as any;
};

export default OrchestrationEnforcement;
