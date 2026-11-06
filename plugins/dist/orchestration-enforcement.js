// plugins/orchestration-enforcement/shared/sanitize.ts
function isSafeId(v) {
  if (typeof v !== "string")
    return false;
  const t = v.trim();
  if (t.length === 0 || t.length > 64)
    return false;
  return /^[A-Za-z0-9._:@-]*$/.test(t);
}
function sanitizeOpt(v) {
  try {
    if (!isSafeId(v))
      return;
    return v.trim();
  } catch {
    return;
  }
}
function evictOldestMap(map, cap) {
  try {
    if (map.size < cap)
      return;
    const oldest = map.keys().next();
    if (!oldest.done)
      map.delete(oldest.value);
  } catch {}
}
function evictOldestSet(set, cap) {
  try {
    if (set.size < cap)
      return;
    const oldest = set.values().next();
    if (!oldest.done)
      set.delete(oldest.value);
  } catch {}
}
function setAddBounded(set, key, cap) {
  try {
    if (!set.has(key) && set.size >= cap)
      evictOldestSet(set, cap);
    set.add(key);
  } catch {}
}
function mapSetBounded(map, key, value, cap) {
  try {
    if (!map.has(key) && map.size >= cap)
      evictOldestMap(map, cap);
    map.set(key, value);
  } catch {}
}

// plugins/orchestration-enforcement/shared/identity.ts
var INDEX_CAP = 5000;
var WORKER_AGENT_NAMES = [
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
  "skeptic"
];
var WORKER_AGENTS = new Set(WORKER_AGENT_NAMES);
var PLANNER_AGENTS = new Set(["build", "primary", "planner", "main"]);
function normalizeAgentName(v) {
  try {
    if (typeof v !== "string")
      return "";
    return v.trim().toLowerCase();
  } catch {
    return "";
  }
}
function roleFromAgentName(name) {
  try {
    const n = normalizeAgentName(name);
    if (n.length === 0)
      return null;
    if (PLANNER_AGENTS.has(n))
      return "planner";
    if (WORKER_AGENTS.has(n))
      return "worker";
    return null;
  } catch {
    return null;
  }
}
function roleFromSessionEntry(entry) {
  try {
    const parentID = typeof entry.parentID === "string" ? entry.parentID.trim() : "";
    if (parentID.length > 0)
      return "worker";
    return roleFromAgentName(entry.agent);
  } catch {
    return null;
  }
}
function readAgent(input) {
  try {
    const v = input;
    if (!v || typeof v !== "object")
      return;
    const direct = [v.agent, v.agentName, v.agent_name, v.agentID, v.agentId];
    for (const c of direct) {
      if (typeof c === "string" && c.trim().length > 0)
        return c.trim();
    }
    const nested = [v.session, v.sessionInfo, v.metadata, v.info, v.context, v.runtime];
    for (const n of nested) {
      if (!n || typeof n !== "object")
        continue;
      const c = n.agent ?? n.agentName ?? n.agent_name;
      if (typeof c === "string" && c.trim().length > 0)
        return c.trim();
    }
    return;
  } catch {
    return;
  }
}
function readSessionID(input) {
  try {
    const v = input;
    if (!v || typeof v !== "object")
      return;
    const c = v.sessionID ?? v.sessionId ?? v.session_id ?? v?.info?.id;
    return typeof c === "string" && c.length > 0 ? c : undefined;
  } catch {
    return;
  }
}
function lookupSession(map, sessionId) {
  try {
    if (typeof sessionId !== "string" || sessionId.length === 0)
      return;
    return map.get(sessionId);
  } catch {
    return;
  }
}
function indexSession(map, id, value) {
  mapSetBounded(map, id, value, INDEX_CAP);
}
function resolveRole(entry, probeAgent) {
  try {
    if (entry) {
      const viaMap = roleFromSessionEntry(entry);
      if (viaMap === "worker") {
        return { role: "worker", agent: entry.agent, source: "session-map" };
      }
      if (viaMap === "planner") {
        return { role: "planner", agent: entry.agent, source: "session-map" };
      }
    }
    const viaProbe = roleFromAgentName(probeAgent);
    if (viaProbe === "planner") {
      return { role: "planner", agent: probeAgent, source: "input-probe" };
    }
    if (viaProbe === "worker") {
      return { role: "worker", agent: probeAgent, source: "input-probe" };
    }
    return { role: "neutral", agent: probeAgent, source: "none" };
  } catch {
    return { role: "neutral", agent: undefined, source: "none" };
  }
}
function recordSessionEvent(map, input) {
  try {
    const v = input;
    if (!v || typeof v !== "object")
      return;
    const ev = v.event;
    const type = (ev && typeof ev.type === "string" ? ev.type : undefined) ?? (typeof v.type === "string" ? v.type : undefined);
    if (type !== "session.created" && type !== "session.updated")
      return;
    const props = (ev && typeof ev === "object" ? ev.properties : undefined) ?? v.properties;
    const info = props?.info ?? props?.session ?? v?.info ?? v?.session;
    if (!info || typeof info !== "object")
      return;
    const id = info.id ?? info.sessionID ?? info.sessionId ?? info.session_id;
    if (typeof id !== "string" || id.length === 0)
      return;
    const rawParent = info.parentID ?? info.parentId ?? info.parent_id;
    const rawAgent = info.agent ?? info.agentName ?? info.agent_name;
    const next = {};
    if (typeof rawParent === "string" && rawParent.length > 0)
      next.parentID = rawParent;
    if (typeof rawAgent === "string" && rawAgent.length > 0)
      next.agent = rawAgent;
    const prev = map.get(id);
    if (prev) {
      if (next.parentID !== undefined)
        prev.parentID = next.parentID;
      if (next.agent !== undefined)
        prev.agent = next.agent;
      indexSession(map, id, prev);
    } else {
      indexSession(map, id, next);
    }
  } catch {}
}

// plugins/orchestration-enforcement/shared/mandate.ts
var MARKER_SUBSTRING = "orchestration-enforcement:";
var PLANNER_LINES = [
  "Mandatory orchestration preflight before the first action: classify the task as SINGLE_WORKER, MULTI_WORKER, PERSISTENT_GOAL, DETERMINISTIC_FALLBACK, or BLOCKED. SINGLE_WORKER is full orchestration (Planner -> one cheap worker -> Planner); the Planner never performs the user's operational work directly when a suitable worker exists.",
  "Non-trivial tasks require material participation of at least one suitable subagent; doing everything alone without a recorded decision is ORCHESTRATION_POLICY_BYPASS.",
  "For relevant changes, follow the coder → tester → reviewer cycle and integrate their syntheses. DONE requires observed worker participation on non-trivial work.",
  ""
];
var V2_PLANNER_LINES = [
  "Clear, low-risk, local, reversible work may be executed directly by you: inspect, make the smallest correct change, and run focused validation. No preflight, worker, Kernel task, review cycle, worktree, or PR is mandatory for that class of work.",
  "Preflight (scripts/v3/orchestration-preflight.ps1) remains available when the route is uncertain or when risk/state warrants it; if it returns DIRECT_VERIFIED, honor it as zero workers. Delegate substantive work when delegation has a concrete benefit (specialization, independent review, volume, parallelism); do not call every agent by default.",
  "Keep the Task Kernel and its authority boundaries for durable, shared, concurrent, or external-effect work, and for destructive actions, production changes, secrets, or sensitive data: grants, leases, evidence, review, and confirmation stay as they are. A direct route grants no authority.",
  "Direct functional code is limited to one micro-fix with both one file and one code unit (a function, branch, condition, or expression) explicitly named in the objective, plus a focused test (TaskType=trivial, Domain=code, Risk=low, ReadWrite=write): if preflight is invoked it must return DIRECT_VERIFIED and you honor zero workers. Never route direct for money, payment, billing, pricing, permission, auth, security, secrets, credentials, production, sensitive, destructive actions, architecture, broad or multi-file scope, new features, refactors, substantive or non-trivial work, uncertainty, concurrency, or Kernel-owned work; those keep delegation, Kernel, and authority contracts, and routine substantive code work stays with the T2 coder.",
  ""
];
var WORKER_LINES = [
  "You are a bounded specialist executing a delegated scope; do not orchestrate.",
  "Do not create or invoke other subagents (the task tool is unavailable/denied to you).",
  "Stay inside your delegated scope and preserve contracts and unrelated work.",
  "Return a compact structured result with STATUS, KEY_FINDINGS, EVIDENCE, VALIDATION, RISKS, RECOMMENDATION.",
  ""
];
var NEUTRAL_LINES = [
  "Follow the project's orchestration policy for this session.",
  "Specialists never create subagents; the primary agent runs orchestration preflight for non-trivial work.",
  ""
];
function markerFor(kind, generation) {
  if (kind === "worker")
    return "[orchestration-enforcement:" + generation + ":worker]";
  return "[orchestration-enforcement:" + generation + "]";
}
function kindForRole(role) {
  if (role === "planner")
    return "planner";
  if (role === "worker")
    return "worker";
  return "neutral";
}
function mandateFor(role, generation) {
  const kind = kindForRole(role);
  const marker = markerFor(kind, generation);
  const lines = kind === "worker" ? WORKER_LINES : kind === "planner" ? generation === "v1" ? PLANNER_LINES : V2_PLANNER_LINES : NEUTRAL_LINES;
  return { text: [...lines, marker].join(`
`), kind, marker };
}
function hasMarker(entries) {
  try {
    if (!Array.isArray(entries))
      return false;
    for (const item of entries) {
      if (typeof item === "string") {
        if (item.includes(MARKER_SUBSTRING))
          return true;
        continue;
      }
      if (item && typeof item === "object") {
        const t = item.text;
        if (typeof t === "string" && t.includes(MARKER_SUBSTRING))
          return true;
      }
    }
    return false;
  } catch {
    return false;
  }
}
function coalesceString(system, text) {
  try {
    if (system.length === 0) {
      system.push(text);
      return true;
    }
    if (typeof system[0] === "string") {
      system[0] = system[0].length > 0 ? system[0] + `

` + text : text;
      return true;
    }
    return false;
  } catch {
    return false;
  }
}
function appendTextPart(system, text) {
  try {
    if (!Array.isArray(system))
      return false;
    if (typeof text !== "string")
      return false;
    const arr = system;
    if (arr.length === 0) {
      arr.push({ type: "text", text });
      return true;
    }
    let strings = 0;
    let parts = 0;
    let other = 0;
    for (const item of arr) {
      if (typeof item === "string") {
        strings += 1;
        continue;
      }
      if (item && typeof item === "object" && item.type === "text" && typeof item.text === "string") {
        parts += 1;
        continue;
      }
      other += 1;
    }
    if (strings > 0 && parts === 0 && other === 0) {
      arr.push(text);
      return true;
    }
    if (parts > 0 && strings === 0 && other === 0) {
      arr.push({ type: "text", text });
      return true;
    }
    if (strings === 0 && parts === 0)
      return false;
    if (strings > parts) {
      arr.push(text);
      return true;
    }
    if (parts > strings) {
      arr.push({ type: "text", text });
      return true;
    }
    if (typeof arr[0] === "string") {
      arr.push(text);
      return true;
    }
    arr.push({ type: "text", text });
    return true;
  } catch {
    return false;
  }
}

// plugins/orchestration-enforcement/shared/telemetry.ts
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
var logged = new Set;
function loggedSize() {
  try {
    return logged.size;
  } catch {
    return -1;
  }
}
function telemetryPath() {
  try {
    const dir = join(homedir(), ".opencode-orchestration", "evidence", "v3", "orchestration");
    mkdirSync(dir, { recursive: true });
    return join(dir, "session-injections.jsonl");
  } catch {
    return null;
  }
}
function writeInjection(runtime, rec) {
  try {
    const agent = sanitizeOpt(rec.agent);
    const session = sanitizeOpt(rec.session);
    const key = runtime + "::" + (session ?? "null") + "::" + rec.markerUsed;
    if (logged.has(key))
      return;
    const path = telemetryPath();
    if (path === null)
      return;
    const line = {
      ts: new Date().toISOString(),
      runtime,
      sessionType: rec.sessionType,
      mandate: rec.mandateKind,
      markerUsed: rec.markerUsed,
      identity_source: rec.identitySource
    };
    if (agent)
      line["agent"] = agent;
    if (session)
      line["session"] = session;
    appendFileSync(path, JSON.stringify(line) + `
`, "utf8");
    setAddBounded(logged, key, INDEX_CAP);
  } catch {}
}
function writeUnavailable(runtime, reason) {
  try {
    const r = (reason || "").trim();
    if (r.length === 0)
      return;
    const key = runtime + "::hooks-unavailable::" + r;
    if (logged.has(key))
      return;
    const path = telemetryPath();
    if (path === null)
      return;
    const line = {
      ts: new Date().toISOString(),
      runtime,
      kind: "hooks-unavailable",
      reason: r
    };
    appendFileSync(path, JSON.stringify(line) + `
`, "utf8");
    setAddBounded(logged, key, INDEX_CAP);
  } catch {}
}
var MCP_EVENT_ALLOWLIST = [
  "would-timeout",
  "timeout",
  "would-block-circuit-open",
  "circuit-block",
  "circuit-open",
  "half-open-probe",
  "rearm",
  "refusal-long-running",
  "would-refuse-long-running",
  "refusal-aborted",
  "would-refuse-aborted",
  "policy-fallback",
  "enforce-denied-shadow"
];
var MCP_CAUSE_ALLOWLIST = [
  "MCP_TIMEOUT",
  "MCP_CIRCUIT_OPEN",
  "MCP_HALF_OPEN_BUSY",
  "MCP_ERROR",
  "MCP_LONG_RUNNING_REQUIRES_CONTRACT",
  "MCP_ABORTED",
  "MCP_INTERNAL"
];
var MCP_ORIGIN_ALLOWLIST = [
  "call",
  "configure",
  "policy-file"
];
function allowlisted(value, list) {
  try {
    if (typeof value === "string" && list.indexOf(value) >= 0)
      return value;
    return "unknown";
  } catch {
    return "unknown";
  }
}
function boundedMs(value) {
  try {
    if (typeof value !== "number" || !isFinite(value))
      return;
    const n = Math.floor(value);
    if (n < 0 || n > 86400000)
      return;
    return n;
  } catch {
    return;
  }
}
function writeMcpEvent(runtime, fields) {
  try {
    const f = fields;
    if (!f || typeof f !== "object")
      return;
    const event = allowlisted(f.event, MCP_EVENT_ALLOWLIST);
    const server = sanitizeOpt(f.server);
    const mcpClass = sanitizeOpt(f.mcpClass);
    const criticality = sanitizeOpt(f.criticality);
    const mode = sanitizeOpt(f.mode);
    const cause = allowlisted(f.cause, MCP_CAUSE_ALLOWLIST);
    const origin = allowlisted(f.origin, MCP_ORIGIN_ALLOWLIST);
    const key = runtime + "::mcp::" + event + "::" + (server ?? "null") + "::" + (mcpClass ?? "null");
    if (logged.has(key))
      return;
    const path = telemetryPath();
    if (path === null)
      return;
    const line = {
      ts: new Date().toISOString(),
      runtime,
      kind: "mcp-transport",
      event
    };
    if (server)
      line["server"] = server;
    if (mcpClass)
      line["class"] = mcpClass;
    if (criticality)
      line["criticality"] = criticality;
    if (mode)
      line["mode"] = mode;
    if (cause !== "unknown")
      line["cause"] = cause;
    if (origin !== "unknown")
      line["origin"] = origin;
    const turnLen = boundedMs(f.turnLen);
    if (turnLen !== undefined)
      line["turn_len"] = "len:" + String(turnLen);
    const elapsedMs = boundedMs(f.elapsedMs);
    if (elapsedMs !== undefined)
      line["elapsed_ms"] = "len:" + String(elapsedMs);
    const budgetMs = boundedMs(f.budgetMs);
    if (budgetMs !== undefined)
      line["budget_ms"] = "len:" + String(budgetMs);
    appendFileSync(path, JSON.stringify(line) + `
`, "utf8");
    setAddBounded(logged, key, INDEX_CAP);
  } catch {}
}
function writeToolEvent(runtime, fields) {
  try {
    const tool = sanitizeOpt(fields.tool);
    const session = sanitizeOpt(fields.session);
    const agent = sanitizeOpt(fields.agent);
    const key = runtime + "::tool::" + (session ?? "null") + "::" + (tool ?? "null");
    if (logged.has(key))
      return;
    const path = telemetryPath();
    if (path === null)
      return;
    const line = {
      ts: new Date().toISOString(),
      runtime,
      kind: "tool-event",
      identity_source: "input-probe"
    };
    if (tool)
      line["tool"] = tool;
    if (session)
      line["session"] = session;
    if (agent)
      line["agent"] = agent;
    appendFileSync(path, JSON.stringify(line) + `
`, "utf8");
    setAddBounded(logged, key, INDEX_CAP);
  } catch {}
}

// plugins/orchestration-enforcement/v1.ts
var sessionIndex = new Map;
var sessionClient = undefined;
var OrchestrationEnforcement = async (ctx) => {
  try {
    const c = ctx?.client;
    if (c)
      sessionClient = c;
  } catch {}
  return {
    event: async (input, _output) => {
      try {
        recordSessionEvent(sessionIndex, input);
      } catch {}
    },
    "experimental.chat.system.transform": async (input, output) => {
      let pending = null;
      try {
        const out = output;
        if (!out || typeof out !== "object")
          return;
        const inp = input;
        if (!inp || typeof inp !== "object" || Array.isArray(inp))
          return;
        const system = out.system;
        if (!Array.isArray(system))
          return;
        if (!system.every((item) => typeof item === "string"))
          return;
        if (hasMarker(system))
          return;
        const sid = readSessionID(input);
        const r = resolveRole(lookupSession(sessionIndex, sid), readAgent(input));
        const m = mandateFor(r.role, "v1");
        if (!coalesceString(system, m.text))
          return;
        const sessionType = r.role === "neutral" ? "unknown" : r.role;
        pending = {
          sessionType,
          agent: r.agent,
          mandateKind: m.kind,
          markerUsed: m.marker,
          session: sid,
          identitySource: r.source
        };
      } catch {
        return;
      }
      if (pending)
        writeInjection("v1", pending);
    }
  };
};
var __orchestrationEnforcementTest = {
  cap: INDEX_CAP,
  sessionIndexSize: () => {
    try {
      return sessionIndex.size;
    } catch {
      return -1;
    }
  },
  loggedSize: () => {
    try {
      return loggedSize();
    } catch {
      return -1;
    }
  }
};

// plugins/orchestration-enforcement/v2.ts
import { lstatSync, readFileSync, statSync } from "node:fs";
import { spawn as spawnBridgeProcess } from "node:child_process";

// plugins/orchestration-enforcement/shared/planner-wait.ts
var PLANNER_WAIT_TOOL_NAME = "orchestration_planner_wait";
var PLANNER_WAIT_OPERATION = "bind-wait";
var PLANNER_WAIT_SCHEMA_VERSION = 1;
var PLANNER_WAIT_BRIDGE_MAX_BYTES = 65536;
var PLANNER_WAIT_DEFAULT_TIMEOUT_MS = 30000;
function asString(value) {
  try {
    if (typeof value !== "string")
      return "";
    return value.trim();
  } catch {
    return "";
  }
}
function isPlainObject(value) {
  try {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  } catch {
    return false;
  }
}
function sanitizePlannerWaitCode(value) {
  try {
    const t = asString(value).toLowerCase();
    let out = "";
    for (let i = 0;i < t.length && out.length < 64; i++) {
      const c = t.charAt(i);
      if (c >= "a" && c <= "z" || c >= "0" && c <= "9" || c === "-" || c === "_")
        out += c;
      else
        out += "-";
    }
    if (out === "")
      return "unknown";
    return out;
  } catch {
    return "unknown";
  }
}
function denyPlannerWait(reason) {
  const err = new Error("orchestration_planner_wait denied: " + sanitizePlannerWaitCode(reason));
  try {
    err.code = "PLANNER_WAIT_DENY";
  } catch {}
  return err;
}
function plannerWaitRoleOf(agent) {
  try {
    const n = normalizeAgentName(agent);
    if (n === "")
      return "unknown";
    if (PLANNER_AGENTS.has(n))
      return "planner";
    if (WORKER_AGENTS.has(n))
      return "worker";
    return "unknown";
  } catch {
    return "unknown";
  }
}
var PLANNER_WAIT_INPUT_SCHEMA = {
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
    retry_budget_max: { type: "integer", minimum: 0, maximum: 100 }
  },
  required: [
    "task_id",
    "goal_id",
    "repository",
    "pr_number",
    "branch",
    "expected_head_sha",
    "deadline_utc",
    "retry_budget_max"
  ],
  additionalProperties: false
};
var PLANNER_WAIT_ARG_ALLOWLIST = [
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
  "retry_budget_max"
];
var PLANNER_WAIT_ENV_KEYS = [
  "OPENCODE_PLANNER_WAIT_ENABLED",
  "OPENCODE_PLANNER_WAIT_BRIDGE",
  "OPENCODE_PLANNER_WAIT_SHELL",
  "OPENCODE_PLANNER_WAIT_TIMEOUT_MS"
];
function readPlannerWaitEnv(source) {
  const out = {};
  try {
    const e = source;
    if (!e || typeof e !== "object")
      return out;
    for (const k of PLANNER_WAIT_ENV_KEYS) {
      const v = e[k];
      out[k] = typeof v === "string" ? v : undefined;
    }
  } catch {}
  return out;
}
function isPlannerWaitEnabled(env) {
  try {
    return asString(env["OPENCODE_PLANNER_WAIT_ENABLED"]) === "1";
  } catch {
    return false;
  }
}
function readPlannerWaitBridgeConfig(env) {
  const fail = (reason) => ({ ok: false, reason, bridge: "", shell: "", timeoutMs: 0 });
  try {
    const bridge = asString(env["OPENCODE_PLANNER_WAIT_BRIDGE"]);
    const shell = asString(env["OPENCODE_PLANNER_WAIT_SHELL"]);
    if (bridge === "" || shell === "")
      return fail("planner-wait-config-incomplete");
    const absRe = /^(?:\/|[A-Za-z]:[\\/])/;
    if (!absRe.test(bridge) || !absRe.test(shell))
      return fail("planner-wait-config-not-absolute");
    let timeoutMs = PLANNER_WAIT_DEFAULT_TIMEOUT_MS;
    const raw = asString(env["OPENCODE_PLANNER_WAIT_TIMEOUT_MS"]);
    if (raw !== "") {
      if (!/^[0-9]{1,6}$/.test(raw))
        return fail("planner-wait-timeout-invalid");
      timeoutMs = Number(raw);
      if (!(timeoutMs >= 1000 && timeoutMs <= 120000))
        return fail("planner-wait-timeout-invalid");
    }
    return { ok: true, reason: "", bridge, shell, timeoutMs };
  } catch {
    return fail("planner-wait-config-invalid");
  }
}
function readPlannerWaitHostContext(context) {
  const fail = { ok: false, reason: "planner-wait-context-unknown", sessionId: "", agent: "" };
  try {
    if (!isPlainObject(context))
      return fail;
    const c = context;
    const sessionId = asString(c["sessionID"]);
    const agent = asString(c["agent"]);
    if (sessionId === "" || agent === "")
      return fail;
    if (sessionId.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(sessionId))
      return fail;
    return { ok: true, reason: "", sessionId, agent };
  } catch {
    return fail;
  }
}
function validatePlannerWaitArgs(args) {
  const fail = (reason) => ({
    ok: false,
    reason,
    request: {}
  });
  try {
    if (!isPlainObject(args))
      return fail("planner-wait-args-invalid");
    const a = args;
    for (const k of Object.keys(a)) {
      if (/session/i.test(k))
        return fail("planner-wait-session-forbidden");
    }
    for (const k of Object.keys(a)) {
      if (PLANNER_WAIT_ARG_ALLOWLIST.indexOf(k) === -1) {
        return fail("planner-wait-args-unknown-field");
      }
    }
    const req = {};
    const needStr = (name, max) => {
      const v = a[name];
      if (typeof v !== "string" || asString(v) === "" || asString(v).length > max)
        return null;
      return asString(v);
    };
    const optStr = (name, max) => {
      if (a[name] === undefined)
        return "";
      const v = a[name];
      if (typeof v !== "string" || asString(v).length > max)
        return null;
      return asString(v);
    };
    for (const name of [
      "task_id",
      "goal_id",
      "repository",
      "branch",
      "expected_head_sha",
      "deadline_utc"
    ]) {
      const v = needStr(name, 512);
      if (v === null)
        return fail("planner-wait-args-invalid");
      req[name] = v;
    }
    const pr = a["pr_number"];
    if (typeof pr !== "number" || !Number.isInteger(pr) || pr < 1)
      return fail("planner-wait-args-invalid");
    req["pr_number"] = pr;
    const rb = a["retry_budget_max"];
    if (typeof rb !== "number" || !Number.isInteger(rb) || rb < 0 || rb > 100)
      return fail("planner-wait-args-invalid");
    req["retry_budget_max"] = rb;
    const rev = a["review_expectation"] === undefined ? "APPROVED" : a["review_expectation"];
    if (rev !== "APPROVED" && rev !== "ANY")
      return fail("planner-wait-args-invalid");
    req["review_expectation"] = rev;
    const checks = [];
    if (a["required_checks"] !== undefined) {
      const rc = a["required_checks"];
      if (!Array.isArray(rc) || rc.length > 32)
        return fail("planner-wait-args-invalid");
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
      if (v === null)
        return fail("planner-wait-args-invalid");
      req[name] = v;
    }
    if (!/^[0-9a-fA-F]{40}$/.test(String(req["expected_head_sha"])))
      return fail("planner-wait-args-invalid");
    for (const name of ["deadline_utc"]) {
      const v = String(req[name]);
      if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(v)) {
        return fail("planner-wait-args-invalid");
      }
      if (Number.isNaN(Date.parse(v)))
        return fail("planner-wait-args-invalid");
    }
    return { ok: true, reason: "", request: req };
  } catch {
    return fail("planner-wait-args-invalid");
  }
}
function isCompletePinnedSessionInfo(candidate) {
  try {
    if (!Object.prototype.hasOwnProperty.call(candidate, "id"))
      return false;
    const id = candidate["id"];
    if (typeof id !== "string" || asString(id) === "")
      return false;
    if (!/^ses/.test(asString(id)))
      return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "projectID"))
      return false;
    const projectID = candidate["projectID"];
    if (typeof projectID !== "string" || asString(projectID) === "")
      return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "cost"))
      return false;
    const cost = candidate["cost"];
    if (typeof cost !== "number" || !Number.isFinite(cost))
      return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "tokens"))
      return false;
    const tokens = candidate["tokens"];
    if (!isPlainObject(tokens))
      return false;
    const tk = tokens;
    for (const f of ["input", "output", "reasoning"]) {
      if (!Object.prototype.hasOwnProperty.call(tk, f))
        return false;
      if (typeof tk[f] !== "number" || !Number.isFinite(tk[f]))
        return false;
    }
    if (!Object.prototype.hasOwnProperty.call(tk, "cache"))
      return false;
    const cache = tk["cache"];
    if (!isPlainObject(cache))
      return false;
    const cc = cache;
    if (!Object.prototype.hasOwnProperty.call(cc, "read"))
      return false;
    if (!Object.prototype.hasOwnProperty.call(cc, "write"))
      return false;
    if (typeof cc["read"] !== "number" || !Number.isFinite(cc["read"]))
      return false;
    if (typeof cc["write"] !== "number" || !Number.isFinite(cc["write"]))
      return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "time"))
      return false;
    const time = candidate["time"];
    if (!isPlainObject(time))
      return false;
    const t = time;
    if (!Object.prototype.hasOwnProperty.call(t, "created"))
      return false;
    if (!Object.prototype.hasOwnProperty.call(t, "updated"))
      return false;
    if (typeof t["created"] !== "number" || !Number.isFinite(t["created"]))
      return false;
    if (typeof t["updated"] !== "number" || !Number.isFinite(t["updated"]))
      return false;
    if (!Object.prototype.hasOwnProperty.call(candidate, "location"))
      return false;
    const location = candidate["location"];
    if (!isPlainObject(location))
      return false;
    const l = location;
    if (!Object.prototype.hasOwnProperty.call(l, "directory"))
      return false;
    if (typeof l["directory"] !== "string" || asString(l["directory"]) === "")
      return false;
    return true;
  } catch {
    return false;
  }
}
async function checkPlannerWaitRootProvenance(sessionGet, sessionID) {
  try {
    if (typeof sessionGet !== "function")
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    if (typeof sessionID !== "string" || sessionID === "") {
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    }
    const doc = await sessionGet(sessionID);
    if (!isPlainObject(doc))
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    const d = doc;
    let candidate = null;
    const rawData = d["data"];
    const idKeys = ["id", "sessionID", "sessionId", "session_id"];
    const parentKeys = ["parentID", "parentId", "parent_id", "parent"];
    const hasDataKey = Object.prototype.hasOwnProperty.call(d, "data");
    if (hasDataKey) {
      if (!isPlainObject(rawData)) {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      const rd = rawData;
      const innerCanonicalId = rd["id"];
      if (typeof innerCanonicalId !== "string" || asString(innerCanonicalId) === "") {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      const seen2 = [];
      const scopes = [d, rd];
      for (const scope of scopes) {
        for (const k of idKeys) {
          if (!Object.prototype.hasOwnProperty.call(scope, k))
            continue;
          const v = scope[k];
          if (typeof v !== "string" || asString(v) === "") {
            return { ok: false, reason: "planner-wait-provenance-unavailable" };
          }
          const t = asString(v);
          if (seen2.indexOf(t) === -1)
            seen2.push(t);
        }
      }
      if (seen2.length !== 1)
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      if (seen2[0] !== sessionID)
        return { ok: false, reason: "planner-wait-provenance-mismatch" };
      let hasParent2 = false;
      for (const scope of scopes) {
        for (const k of parentKeys) {
          if (!Object.prototype.hasOwnProperty.call(scope, k))
            continue;
          const v = scope[k];
          if (typeof v !== "string" || asString(v) === "") {
            return { ok: false, reason: "planner-wait-provenance-unavailable" };
          }
          hasParent2 = true;
        }
      }
      if (hasParent2)
        return { ok: false, reason: "planner-wait-not-root" };
      if (!isCompletePinnedSessionInfo(rd)) {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      return { ok: true, reason: "" };
    } else {
      candidate = d;
    }
    const seen = [];
    for (const k of idKeys) {
      if (!Object.prototype.hasOwnProperty.call(candidate, k))
        continue;
      const v = candidate[k];
      if (typeof v !== "string" || asString(v) === "") {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      const t = asString(v);
      if (seen.indexOf(t) === -1)
        seen.push(t);
    }
    if (seen.length === 0)
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    if (seen.length > 1)
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    const id = seen[0];
    if (id !== sessionID)
      return { ok: false, reason: "planner-wait-provenance-mismatch" };
    let hasParent = false;
    for (const k of parentKeys) {
      if (!Object.prototype.hasOwnProperty.call(candidate, k))
        continue;
      const v = candidate[k];
      if (typeof v !== "string" || asString(v) === "") {
        return { ok: false, reason: "planner-wait-provenance-unavailable" };
      }
      hasParent = true;
    }
    if (hasParent)
      return { ok: false, reason: "planner-wait-not-root" };
    if (!isCompletePinnedSessionInfo(candidate)) {
      return { ok: false, reason: "planner-wait-provenance-unavailable" };
    }
    return { ok: true, reason: "" };
  } catch {
    return { ok: false, reason: "planner-wait-provenance-unavailable" };
  }
}
function checkPlannerWaitFixtureFiles(lstat, bridge, shell, shellLstat) {
  const fail = (reason) => ({ ok: false, reason });
  try {
    if (typeof lstat !== "function")
      return fail("planner-wait-fixture-unavailable");
    const lstatShell = typeof shellLstat === "function" ? shellLstat : lstat;
    if (typeof bridge !== "string" || bridge === "" || typeof shell !== "string" || shell === "") {
      return fail("planner-wait-fixture-invalid");
    }
    let b;
    try {
      b = lstat(bridge);
    } catch {
      return fail("planner-wait-fixture-unreadable");
    }
    if (!b || b.isSymbolicLink())
      return fail("planner-wait-fixture-symlink");
    if (!b.isFile() || b.size <= 0 || b.size > PLANNER_WAIT_BRIDGE_MAX_BYTES) {
      return fail("planner-wait-fixture-invalid");
    }
    let s;
    try {
      s = lstatShell(shell);
    } catch {
      return fail("planner-wait-fixture-unreadable");
    }
    if (!s || s.isSymbolicLink())
      return fail("planner-wait-fixture-symlink");
    if (!s.isFile())
      return fail("planner-wait-fixture-invalid");
    return { ok: true, reason: "" };
  } catch {
    return fail("planner-wait-fixture-invalid");
  }
}
function runPlannerWaitBridge(cfg, payload, deps) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled)
        return;
      settled = true;
      resolve(result);
    };
    const bad = (reason) => finish({ ok: false, reason, stdout: "" });
    let spawnFn = null;
    try {
      if (deps && typeof deps.spawnFn === "function")
        spawnFn = deps.spawnFn;
    } catch {
      spawnFn = null;
    }
    if (typeof spawnFn !== "function") {
      bad("planner-wait-bridge-spawn-unavailable");
      return;
    }
    let child = null;
    try {
      child = spawnFn(cfg.shell, ["-NoProfile", "-NonInteractive", "-File", cfg.bridge], {
        shell: false,
        stdio: ["pipe", "pipe", "pipe"]
      });
    } catch {
      child = null;
    }
    if (!child || !child.stdin || !child.stdout || !child.stderr) {
      bad("planner-wait-bridge-spawn-failed");
      return;
    }
    const outChunks = [];
    let outBytes = 0;
    let done = false;
    let timer = null;
    try {
      timer = setTimeout(() => {
        done = true;
        try {
          child?.kill();
        } catch {}
        bad("planner-wait-bridge-timeout");
      }, cfg.timeoutMs);
    } catch {
      timer = null;
    }
    const clearTimer = () => {
      try {
        if (timer !== null)
          clearTimeout(timer);
      } catch {}
      timer = null;
    };
    try {
      child.stderr.on("data", () => {
        return;
      });
    } catch {}
    try {
      child.stdout.on("data", (chunk) => {
        if (done)
          return;
        try {
          let buf;
          if (chunk instanceof Uint8Array)
            buf = chunk;
          else
            buf = new TextEncoder().encode(String(chunk));
          outBytes += buf.length;
          if (outBytes > PLANNER_WAIT_BRIDGE_MAX_BYTES) {
            done = true;
            try {
              child?.kill();
            } catch {}
            clearTimer();
            bad("planner-wait-bridge-output-unbounded");
            return;
          }
          outChunks.push(buf);
        } catch {}
      });
    } catch {}
    try {
      child.on("error", () => {
        if (done)
          return;
        done = true;
        clearTimer();
        bad("planner-wait-bridge-spawn-failed");
      });
    } catch {}
    try {
      child.on("close", (code) => {
        if (done)
          return;
        done = true;
        clearTimer();
        if (code !== 0) {
          bad("planner-wait-bridge-refused");
          return;
        }
        let stdout = "";
        try {
          let total = 0;
          for (const b of outChunks)
            total += b.length;
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
    } catch {}
    try {
      child.stdin.on("error", () => {
        if (done)
          return;
        done = true;
        clearTimer();
        try {
          child?.kill();
        } catch {}
        bad("planner-wait-bridge-stdin-failed");
      });
    } catch {}
    try {
      child.stdin.write(payload);
      child.stdin.end();
    } catch {
      if (done)
        return;
      done = true;
      clearTimer();
      bad("planner-wait-bridge-stdin-failed");
    }
  });
}
var PLANNER_WAIT_BRIDGE_WANT = [
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
  "done_approved"
];
function parsePlannerWaitBridgeResponse(stdout) {
  const fail = (reason) => ({
    ok: false,
    reason,
    doc: null
  });
  try {
    if (typeof stdout !== "string" || stdout.length === 0 || stdout.length > PLANNER_WAIT_BRIDGE_MAX_BYTES) {
      return fail("planner-wait-bridge-output-unbounded");
    }
    let doc = null;
    try {
      doc = JSON.parse(stdout);
    } catch {
      return fail("planner-wait-bridge-output-invalid");
    }
    if (!isPlainObject(doc))
      return fail("planner-wait-bridge-output-invalid");
    const d = doc;
    const keys = Object.keys(d);
    if (keys.length !== PLANNER_WAIT_BRIDGE_WANT.length)
      return fail("planner-wait-bridge-output-shape");
    for (const k of PLANNER_WAIT_BRIDGE_WANT) {
      if (!Object.prototype.hasOwnProperty.call(d, k))
        return fail("planner-wait-bridge-output-shape");
    }
    if (d["schema_version"] !== PLANNER_WAIT_SCHEMA_VERSION)
      return fail("planner-wait-bridge-output-shape");
    if (d["operation"] !== PLANNER_WAIT_OPERATION)
      return fail("planner-wait-bridge-output-shape");
    if (typeof d["ok"] !== "boolean")
      return fail("planner-wait-bridge-output-shape");
    if (typeof d["reason"] !== "string" || d["reason"].length === 0 || d["reason"].length > 128) {
      return fail("planner-wait-bridge-output-shape");
    }
    if (!/^[a-z0-9-]+$/.test(d["reason"]))
      return fail("planner-wait-bridge-output-shape");
    if (typeof d["run_id"] !== "string")
      return fail("planner-wait-bridge-output-shape");
    if (typeof d["revision"] !== "number" || !Number.isInteger(d["revision"])) {
      return fail("planner-wait-bridge-output-shape");
    }
    if (typeof d["binding"] !== "string")
      return fail("planner-wait-bridge-output-shape");
    if (typeof d["wait_reused"] !== "boolean")
      return fail("planner-wait-bridge-output-shape");
    if (typeof d["wait_file"] !== "string" || typeof d["dedup_key"] !== "string") {
      return fail("planner-wait-bridge-output-shape");
    }
    if (typeof d["task_mutated"] !== "boolean")
      return fail("planner-wait-bridge-output-shape");
    if (d["grants_authority"] !== false || d["done_approved"] !== false) {
      return fail("planner-wait-authority-pin-violated");
    }
    return { ok: true, reason: "", doc: d };
  } catch {
    return fail("planner-wait-bridge-output-invalid");
  }
}
function makePlannerWaitExecute(cfg, deps) {
  const spawnFn = deps && typeof deps.spawnFn === "function" ? deps.spawnFn : null;
  const sessionGet = deps && typeof deps.sessionGet === "function" ? deps.sessionGet : null;
  return async function plannerWaitExecute(args, context) {
    const host = readPlannerWaitHostContext(context);
    if (!host.ok)
      throw denyPlannerWait(host.reason);
    const role = plannerWaitRoleOf(host.agent);
    if (role === "worker")
      throw denyPlannerWait("planner-wait-worker-denied");
    if (role !== "planner")
      throw denyPlannerWait("planner-wait-agent-unknown");
    const checked = validatePlannerWaitArgs(args);
    if (!checked.ok) {
      if (/^planner-wait-[a-z-]+$/.test(checked.reason))
        throw denyPlannerWait(checked.reason);
      throw denyPlannerWait("planner-wait-args-invalid");
    }
    const prov = await checkPlannerWaitRootProvenance(sessionGet, host.sessionId);
    if (!prov.ok)
      throw denyPlannerWait(prov.reason);
    let payload = "";
    try {
      payload = JSON.stringify({
        schema_version: PLANNER_WAIT_SCHEMA_VERSION,
        request: { ...checked.request, session_id: host.sessionId }
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
    if (!res.ok)
      throw denyPlannerWait(res.reason);
    const parsed = parsePlannerWaitBridgeResponse(res.stdout);
    if (!parsed.ok)
      throw denyPlannerWait(parsed.reason);
    const doc = parsed.doc;
    if (doc["ok"] !== true)
      throw denyPlannerWait("planner-wait-bridge-refused-" + sanitizePlannerWaitCode(doc["reason"]));
    return { content: [{ type: "text", text: JSON.stringify(doc) }] };
  };
}

// plugins/orchestration-enforcement/shared/mcp-transport.ts
var MCP_EMBEDDED_BUDGET_S = {
  advisory: 30,
  memory: 60,
  remote: 120
};
var MCP_EMBEDDED_FAILURE_THRESHOLD = 2;
var MCP_EMBEDDED_COOLDOWN_S = 300;
var MCP_POLICY_TEXT_CAP = 65536;
var MCP_CIRCUIT_CAP = 500;
var MCP_LONG_RUNNING_MAX_BUDGET_S = 3600;
var CAUSES = [
  "MCP_TIMEOUT",
  "MCP_CIRCUIT_OPEN",
  "MCP_HALF_OPEN_BUSY",
  "MCP_ERROR",
  "MCP_LONG_RUNNING_REQUIRES_CONTRACT",
  "MCP_ABORTED",
  "MCP_INTERNAL"
];
function isCausalCode(v) {
  try {
    return typeof v === "string" && CAUSES.indexOf(v) >= 0;
  } catch {
    return false;
  }
}
function toBoundedInt(v, min, max, fallback) {
  try {
    if (typeof v !== "number" || !isFinite(v))
      return fallback;
    const n = Math.floor(v);
    if (n < min || n > max)
      return fallback;
    return n;
  } catch {
    return fallback;
  }
}
function safeLower(v, cap) {
  try {
    if (typeof v !== "string")
      return "";
    const t = v.trim().toLowerCase();
    if (t.length === 0 || t.length > cap)
      return "";
    return t;
  } catch {
    return "";
  }
}
function isSafeServer(v) {
  try {
    if (v.length === 0 || v.length > 64)
      return false;
    return /^[a-z0-9][a-z0-9._-]*$/.test(v);
  } catch {
    return false;
  }
}
var SEPS = ["_", "-", ":", ".", "/"];
function withSep(base, name) {
  try {
    if (name === base)
      return true;
    for (const s of SEPS) {
      if (name.length > base.length + 1 && name.indexOf(base + s) === 0)
        return true;
    }
    return false;
  } catch {
    return false;
  }
}
function serverAfter(base, name) {
  try {
    const rest = name.slice(base.length);
    let i = 0;
    while (i < rest.length && SEPS.indexOf(rest.charAt(i)) >= 0)
      i++;
    const tail = rest.slice(i);
    let end = tail.length;
    for (let j = 0;j < tail.length; j++) {
      if (SEPS.indexOf(tail.charAt(j)) >= 0) {
        end = j;
        break;
      }
    }
    const seg = tail.slice(0, end);
    if (isSafeServer(seg))
      return seg;
    return "mcp";
  } catch {
    return "mcp";
  }
}
function classifyMcpTool(tool) {
  try {
    const name = safeLower(tool, 256);
    if (name.length === 0)
      return null;
    if (withSep("jev", name))
      return { server: "jev", mcpClass: "advisory" };
    if (withSep("memory", name))
      return { server: "memory", mcpClass: "memory" };
    if (withSep("ai-memory", name))
      return { server: "ai-memory", mcpClass: "memory" };
    if (withSep("ai_memory", name))
      return { server: "ai-memory", mcpClass: "memory" };
    if (name === "mcp")
      return { server: "mcp", mcpClass: "remote" };
    if (withSep("mcp", name))
      return { server: serverAfter("mcp", name), mcpClass: "remote" };
    return null;
  } catch {
    return null;
  }
}
function normalizeMcpClass(v) {
  try {
    const c = safeLower(v, 32);
    if (c === "jev")
      return "advisory";
    if (c === "advisory" || c === "memory" || c === "remote" || c === "long_running") {
      return c;
    }
    return null;
  } catch {
    return null;
  }
}
function normalizeMcpCriticality(v) {
  try {
    if (typeof v === "string" && v.trim().toLowerCase() === "required")
      return "required";
    return "optional";
  } catch {
    return "optional";
  }
}
function normalizeMcpTurn(v) {
  try {
    if (typeof v === "string") {
      const t = v.trim().toLowerCase();
      if (t.length >= 1 && t.length <= 64 && /^[a-z0-9][a-z0-9._-]*$/.test(t))
        return t;
    }
    return "default-turn";
  } catch {
    return "default-turn";
  }
}
function embeddedPolicy() {
  return {
    budgetsS: {
      advisory: MCP_EMBEDDED_BUDGET_S["advisory"],
      memory: MCP_EMBEDDED_BUDGET_S["memory"],
      remote: MCP_EMBEDDED_BUDGET_S["remote"]
    },
    failureThreshold: MCP_EMBEDDED_FAILURE_THRESHOLD,
    cooldownS: MCP_EMBEDDED_COOLDOWN_S,
    source: "embedded-defaults",
    valid: true
  };
}
function asRecord(v) {
  try {
    if (!v || typeof v !== "object" || Array.isArray(v))
      return null;
    return v;
  } catch {
    return null;
  }
}
function isExactInt(v, min, max) {
  try {
    if (typeof v !== "number" || !isFinite(v))
      return false;
    if (Math.floor(v) !== v)
      return false;
    return v >= min && v <= max;
  } catch {
    return false;
  }
}
function parseStrictPolicyText(text) {
  try {
    if (text.length === 0 || text.length > MCP_POLICY_TEXT_CAP)
      return null;
    let doc = null;
    try {
      doc = JSON.parse(text);
    } catch {
      return null;
    }
    const root = asRecord(doc);
    if (!root)
      return null;
    if (root["version"] !== 1)
      return null;
    const classes = asRecord(root["classes"]);
    if (!classes)
      return null;
    const wantExec = { advisory: 30, memory: 60, remote: 120 };
    const wantConn = { advisory: 10, memory: 15, remote: 20 };
    const budgets = {};
    for (const k of ["advisory", "memory", "remote"]) {
      const slot = asRecord(classes[k]);
      if (!slot)
        return null;
      const ex = slot["execution_timeout_seconds"];
      if (ex !== wantExec[k])
        return null;
      const co = slot["connect_timeout_seconds"];
      if (co !== wantConn[k])
        return null;
      budgets[k] = ex;
    }
    const lr = asRecord(classes["long_running"]);
    if (!lr)
      return null;
    if (lr["execution_timeout_seconds"] !== 0)
      return null;
    if (lr["requires_explicit_task_contract"] !== true)
      return null;
    if (lr["connect_timeout_seconds"] !== 20)
      return null;
    const aliases = asRecord(root["class_aliases"]);
    if (!aliases || aliases["jev"] !== "advisory")
      return null;
    if (root["failure_threshold"] !== 2)
      return null;
    const circuit = asRecord(root["circuit"]);
    if (!circuit)
      return null;
    const cd = circuit["cooldown_seconds"];
    if (cd !== 300)
      return null;
    const crit = asRecord(root["criticality"]);
    if (!crit)
      return null;
    const allowed = crit["allowed"];
    if (!Array.isArray(allowed) || allowed.length !== 2)
      return null;
    if (allowed.indexOf("optional") < 0 || allowed.indexOf("required") < 0)
      return null;
    if (crit["default"] !== "optional")
      return null;
    return {
      budgetsS: budgets,
      failureThreshold: 2,
      cooldownS: cd,
      source: "policy-text",
      valid: true
    };
  } catch {
    return null;
  }
}
function resolveMcpPolicy(policyText) {
  try {
    if (typeof policyText === "string" && policyText.length > 0) {
      const parsed = parseStrictPolicyText(policyText);
      if (parsed)
        return parsed;
    }
    return embeddedPolicy();
  } catch {
    return embeddedPolicy();
  }
}
var transportConfig = { enforced: false, policyText: null, policyPath: null };
var inlinePolicyCache = null;
var policyFileReader = null;
function readEnvFlag(name) {
  try {
    const g = globalThis;
    const env = g && g.process && g.process.env ? g.process.env : null;
    if (!env)
      return false;
    const v = env[name];
    return typeof v === "string" && v.trim() === "1";
  } catch {
    return false;
  }
}
function readEnvText(name, cap) {
  try {
    const g = globalThis;
    const env = g && g.process && g.process.env ? g.process.env : null;
    if (!env)
      return null;
    const v = env[name];
    if (typeof v !== "string")
      return null;
    const t = v.trim();
    if (t.length === 0 || t.length > cap)
      return null;
    return t;
  } catch {
    return null;
  }
}
function configureMcpTransport(cfg) {
  try {
    if (!cfg || typeof cfg !== "object") {
      transportConfig = { enforced: false, policyText: null, policyPath: null };
    } else {
      transportConfig = {
        enforced: cfg["enforced"] === true,
        policyText: typeof cfg["policyText"] === "string" ? cfg["policyText"] : null,
        policyPath: typeof cfg["policyPath"] === "string" ? cfg["policyPath"] : null
      };
    }
    clearPolicyCache();
  } catch {
    transportConfig = { enforced: false, policyText: null, policyPath: null };
    clearPolicyCache();
  }
}
function getMcpTransportConfig() {
  try {
    return {
      enforced: transportConfig.enforced === true,
      hasPolicyText: typeof transportConfig.policyText === "string",
      hasPolicyPath: typeof transportConfig.policyPath === "string"
    };
  } catch {
    return { enforced: false, hasPolicyText: false, hasPolicyPath: false };
  }
}
function clearPolicyCache() {
  try {
    inlinePolicyCache = null;
  } catch {}
}
function setMcpPolicyFileReader(reader) {
  try {
    if (typeof reader === "function") {
      policyFileReader = reader;
    } else {
      policyFileReader = null;
    }
    clearPolicyCache();
  } catch {
    policyFileReader = null;
  }
}
function effectivePolicy(callText, callPath) {
  try {
    const hasCallText = typeof callText === "string" && callText.length > 0;
    const hasConfigText = typeof transportConfig.policyText === "string";
    const text = hasCallText ? callText : hasConfigText ? transportConfig.policyText : null;
    if (text !== null) {
      try {
        if (inlinePolicyCache && inlinePolicyCache.text === text) {
          return { policy: inlinePolicyCache.result, invalidOrigin: null };
        }
      } catch {}
      const parsed = parseStrictPolicyText(text);
      if (parsed) {
        try {
          inlinePolicyCache = { text, result: parsed };
        } catch {}
        return { policy: parsed, invalidOrigin: null };
      }
      return { policy: embeddedPolicy(), invalidOrigin: hasCallText ? "call" : "configure" };
    }
    const path = typeof callPath === "string" && callPath.length > 0 ? callPath : typeof transportConfig.policyPath === "string" ? transportConfig.policyPath : readEnvText("OO_MCP_TRANSPORT_POLICY_PATH", 512);
    if (path !== null && policyFileReader !== null) {
      let fileText = null;
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
function globalEnforced() {
  try {
    if (transportConfig.enforced === true)
      return true;
    return readEnvFlag("OO_MCP_TRANSPORT_ENFORCED");
  } catch {
    return false;
  }
}
function effectiveMcpMode(requested) {
  try {
    const r = typeof requested === "string" ? requested.trim().toLowerCase() : "";
    if (r === "shadow")
      return { mode: "shadow", denied: false };
    if (globalEnforced())
      return { mode: "enforced", denied: false };
    if (r === "enforced")
      return { mode: "shadow", denied: true };
    return { mode: "shadow", denied: false };
  } catch {
    return { mode: "shadow", denied: false };
  }
}
var circuitStore = new Map;
function circuitKey(server, mcpClass, turn) {
  return server + "|" + mcpClass + "|" + turn;
}
function readEntry(key) {
  try {
    const e = circuitStore.get(key);
    if (!e || typeof e !== "object")
      return null;
    return e;
  } catch {
    return null;
  }
}
function writeEntry(key, e) {
  try {
    mapSetBounded(circuitStore, key, e, MCP_CIRCUIT_CAP);
  } catch {}
}
function releaseProbe(key) {
  try {
    const e = readEntry(key);
    if (e && e.open && e.probeInFlight) {
      e.probeInFlight = false;
      writeEntry(key, e);
    }
  } catch {}
}
function getMcpCircuitSnapshot(server, mcpClass, turn, nowMs) {
  try {
    const cls = normalizeMcpClass(mcpClass);
    if (cls === null)
      return { state: "UNKNOWN", consecutive: 0 };
    const srv = typeof server === "string" && isSafeServer(server.trim().toLowerCase()) ? server.trim().toLowerCase() : "mcp";
    const key = circuitKey(srv, cls, normalizeMcpTurn(turn));
    const e = readEntry(key);
    if (!e)
      return { state: "CLOSED", consecutive: 0 };
    if (!e.open)
      return { state: "CLOSED", consecutive: e.consecutive };
    const now = toBoundedInt(nowMs, 0, 9007199254740991, Date.now());
    if (now >= e.openedAtMs + MCP_EMBEDDED_COOLDOWN_S * 1000) {
      return { state: "HALF_OPEN", consecutive: e.consecutive };
    }
    return { state: "OPEN", consecutive: e.consecutive };
  } catch {
    return { state: "UNKNOWN", consecutive: 0 };
  }
}
function resetMcpTransport() {
  try {
    circuitStore.clear();
  } catch {}
  try {
    transportConfig = { enforced: false, policyText: null, policyPath: null };
    clearPolicyCache();
    policyFileReader = null;
  } catch {}
}
function nowOf(v) {
  return toBoundedInt(v, 0, 9007199254740991, Date.now());
}
function validContract(c) {
  try {
    if (!c || typeof c !== "object")
      return { ok: false, budgetS: 0 };
    const id = c.id;
    if (typeof id !== "string" || id.trim().length === 0 || id.length > 128) {
      return { ok: false, budgetS: 0 };
    }
    const b = c.budgetSeconds;
    if (!isExactInt(b, 1, MCP_LONG_RUNNING_MAX_BUDGET_S))
      return { ok: false, budgetS: 0 };
    return { ok: true, budgetS: b };
  } catch {
    return { ok: false, budgetS: 0 };
  }
}
function mapUnavailable(cause, criticality, base) {
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
      elapsedMs: base.elapsedMs
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
    elapsedMs: base.elapsedMs
  };
}
function mcpResultGrantsAuthority(_result) {
  return { granted: false, widened: false, status: "MCP_RESULT_CANNOT_GRANT" };
}
function observeMcpBeforeExecute(runtime, fields) {
  try {
    const c = classifyMcpTool(fields ? fields.tool : null);
    if (!c)
      return { mcp: false, wouldBlock: false };
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
        turnLen: turn.length
      });
    }
    return { mcp: true, wouldBlock };
  } catch {
    return { mcp: false, wouldBlock: false };
  }
}
var activeDeadlines = 0;
function pendingMcpDeadlines() {
  try {
    return activeDeadlines;
  } catch {
    return -1;
  }
}
function startDeadline(ms) {
  let timer = null;
  let done = false;
  const settle = () => {
    try {
      if (!done) {
        done = true;
        activeDeadlines = Math.max(0, activeDeadlines - 1);
      }
    } catch {}
  };
  try {
    activeDeadlines = activeDeadlines + 1;
  } catch {}
  const fired = new Promise((resolve) => {
    const onFire = () => {
      timer = null;
      settle();
      try {
        resolve(true);
      } catch {}
    };
    try {
      timer = setTimeout(onFire, ms);
    } catch {
      timer = null;
      settle();
      try {
        resolve(true);
      } catch {}
      return;
    }
    try {
      const u = timer;
      if (u && typeof u.unref === "function") {
        u.unref.call(timer);
      }
    } catch {}
  });
  const cancel = () => {
    try {
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
    } catch {} finally {
      settle();
    }
  };
  return { fired, cancel };
}
async function runMcpGuarded(opts) {
  const wallStart = Date.now();
  let callCriticality = "required";
  let probeKey = null;
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
        elapsedMs: 0
      };
    }
    const classification = classifyMcpTool(opts.tool);
    if (!classification) {
      return opts.execute().then((value) => {
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
          value
        };
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
          origin: effPolicy.invalidOrigin
        });
      } catch {}
    }
    const mcpClass = normalizeMcpClass(opts.classOverride) ?? classification.mcpClass;
    const base = {
      engaged: true,
      server,
      mcpClass,
      mode,
      elapsedMs: 0
    };
    if (eff.denied) {
      try {
        writeMcpEvent("v2", {
          event: "enforce-denied-shadow",
          server,
          mcpClass,
          criticality,
          mode,
          turnLen: turn.length
        });
      } catch {}
    }
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
              turnLen: turn.length
            });
          } catch {}
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
              turnLen: turn.length
            });
          } catch {}
          const r2 = mapUnavailable("MCP_LONG_RUNNING_REQUIRES_CONTRACT", criticality, base);
          r2.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r2;
        }
      } else {
        budgetMs = vc.budgetS * 1000;
      }
    } else {
      const perClass = policy.budgetsS[mcpClass];
      const secs = typeof perClass === "number" ? perClass : 120;
      budgetMs = secs * 1000;
    }
    if (!unbounded) {
      const tight = toBoundedInt(opts.tightenBudgetMs, 1, budgetMs, budgetMs);
      budgetMs = tight;
    }
    const key = circuitKey(server, mcpClass, turn);
    const nowAdm = nowOf(opts.nowMs);
    const cooldownMs = policy.cooldownS * 1000;
    const threshold = policy.failureThreshold;
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
              turnLen: turn.length
            });
          } catch {}
          const r2 = mapUnavailable("MCP_CIRCUIT_OPEN", criticality, base);
          r2.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r2;
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
              turnLen: turn.length
            });
          } catch {}
          const r2 = mapUnavailable("MCP_CIRCUIT_OPEN", criticality, base);
          r2.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r2;
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
            turnLen: turn.length
          });
        } catch {}
      }
    } else {
      const e = readEntry(key);
      if (e && e.open) {
        const busy = nowAdm < e.openedAtMs + cooldownMs || e.probeInFlight;
        try {
          writeMcpEvent("v2", {
            event: "would-block-circuit-open",
            server,
            mcpClass,
            criticality,
            mode,
            cause: "MCP_CIRCUIT_OPEN",
            turnLen: turn.length
          });
        } catch {}
      }
    }
    try {
      const sig = opts.signal;
      if (sig && typeof sig === "object" && sig.aborted === true) {
        if (mode === "shadow") {
          try {
            writeMcpEvent("v2", {
              event: "would-refuse-aborted",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_ABORTED",
              turnLen: turn.length
            });
          } catch {}
        } else {
          try {
            writeMcpEvent("v2", {
              event: "refusal-aborted",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_ABORTED",
              turnLen: turn.length
            });
          } catch {}
          if (isProbe) {
            releaseProbe(key);
          }
          const r2 = mapUnavailable("MCP_ABORTED", criticality, base);
          r2.elapsedMs = Math.max(0, Date.now() - wallStart);
          return r2;
        }
      }
    } catch {}
    const conclusionNow = () => {
      try {
        if (opts.nowMs !== undefined)
          return nowAdm;
        return nowOf(Date.now());
      } catch {
        return nowAdm;
      }
    };
    const recordSuccess = (concludedAt) => {
      try {
        const prev = readEntry(key);
        const wasProbe = isProbe || prev !== null && prev.open;
        writeEntry(key, { consecutive: 0, open: false, openedAtMs: 0, probeInFlight: false });
        if (wasProbe) {
          try {
            writeMcpEvent("v2", {
              event: "rearm",
              server,
              mcpClass,
              criticality,
              mode,
              turnLen: turn.length
            });
          } catch {}
        }
      } catch {}
    };
    const recordFailure = (concludedAt) => {
      try {
        const prev = readEntry(key);
        const consecutive = (prev ? prev.consecutive : 0) + 1;
        if (consecutive >= threshold) {
          writeEntry(key, {
            consecutive,
            open: true,
            openedAtMs: concludedAt,
            probeInFlight: false
          });
          try {
            writeMcpEvent("v2", {
              event: "circuit-open",
              server,
              mcpClass,
              criticality,
              mode,
              cause: "MCP_TIMEOUT",
              turnLen: turn.length
            });
          } catch {}
        } else {
          writeEntry(key, {
            consecutive,
            open: prev ? prev.open : false,
            openedAtMs: prev ? prev.openedAtMs : 0,
            probeInFlight: false
          });
        }
      } catch {}
    };
    if (mode === "shadow") {
      const t0 = Date.now();
      let value = undefined;
      let failed = false;
      try {
        value = await opts.execute();
      } catch {
        failed = true;
      }
      const elapsed2 = Math.max(0, Date.now() - t0);
      const concluded = nowOf(opts.nowMs !== undefined ? opts.nowMs : Date.now());
      if (failed) {
        recordFailure(concluded);
        const r2 = mapUnavailable("MCP_ERROR", criticality, base);
        r2.elapsedMs = elapsed2;
        return r2;
      }
      if (!unbounded && elapsed2 > budgetMs) {
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
            elapsedMs: elapsed2,
            budgetMs
          });
        } catch {}
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
        elapsedMs: elapsed2,
        value
      };
    }
    let abortListener = null;
    const execP = (async () => {
      try {
        const v = await opts.execute();
        return { kind: "value", value: v };
      } catch {
        return { kind: "error" };
      }
    })();
    const deadline = startDeadline(budgetMs);
    let settled = { kind: "error" };
    try {
      const timerP = deadline.fired.then(() => ({ kind: "timeout" }));
      let raceP = Promise.race([execP, timerP]);
      const sig = opts.signal;
      if (sig && typeof sig === "object" && typeof sig.addEventListener === "function") {
        const abortP = new Promise((resolve) => {
          abortListener = () => {
            try {
              resolve({ kind: "aborted" });
            } catch {}
          };
          try {
            sig.addEventListener("abort", abortListener, { once: true });
          } catch {}
        });
        raceP = Promise.race([execP, timerP, abortP]);
      }
      try {
        settled = await raceP;
      } catch {
        settled = { kind: "error" };
      }
    } finally {
      try {
        deadline.cancel();
      } catch {}
      try {
        const s = opts.signal;
        if (s && typeof s === "object" && abortListener !== null && typeof s.removeEventListener === "function") {
          s.removeEventListener("abort", abortListener);
        }
      } catch {}
    }
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
        value: settled.value
      };
    }
    if (settled.kind === "aborted") {
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
          turnLen: turn.length
        });
      } catch {}
      const r2 = mapUnavailable("MCP_ABORTED", criticality, base);
      r2.elapsedMs = elapsed;
      return r2;
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
          budgetMs
        });
      } catch {}
    } else {
      recordFailure(conclusionNow());
    }
    const cause = settled.kind === "timeout" ? "MCP_TIMEOUT" : "MCP_ERROR";
    const r = mapUnavailable(cause, criticality, base);
    r.elapsedMs = elapsed;
    return r;
  } catch {
    try {
      if (probeKey !== null) {
        try {
          releaseProbe(probeKey);
        } catch {}
      }
    } catch {}
    try {
      const r = mapUnavailable("MCP_INTERNAL", callCriticality, {
        engaged: true,
        server: null,
        mcpClass: null,
        mode: "shadow",
        elapsedMs: Math.max(0, Date.now() - wallStart)
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
        elapsedMs: 0
      };
    }
  }
}
var __mcpTransportTest = {
  circuitSize: () => {
    try {
      return circuitStore.size;
    } catch {
      return -1;
    }
  },
  pendingDeadlines: () => {
    try {
      return pendingMcpDeadlines();
    } catch {
      return -1;
    }
  },
  reset: () => {
    resetMcpTransport();
  }
};

// plugins/orchestration-enforcement/v2.ts
var V2_ID = "orchestration-enforcement";
function readMcpPolicyFileBounded(absPath) {
  try {
    if (typeof absPath !== "string")
      return null;
    const t = absPath.trim();
    if (t.length === 0 || t.length > 512)
      return null;
    const isAbs = t.charAt(0) === "/" || /^[A-Za-z]:[\\/]/.test(t);
    if (!isAbs)
      return null;
    let size = -1;
    let isFile = false;
    try {
      const st = statSync(t);
      isFile = st.isFile();
      size = st.size;
    } catch {
      return null;
    }
    if (!isFile)
      return null;
    if (size <= 0 || size > 65536)
      return null;
    let text = "";
    try {
      text = readFileSync(t, "utf8");
    } catch {
      return null;
    }
    if (text.length === 0 || text.length > 65536)
      return null;
    return text;
  } catch {
    return null;
  }
}
var sessionIndex2 = new Map;
async function subscribe(registrations, owner, name, callback) {
  try {
    if (!owner || typeof owner.hook !== "function")
      return;
    const reg = await owner.hook.call(owner, name, callback);
    if (reg && typeof reg.dispose === "function")
      registrations.push(reg);
  } catch {}
}
async function setupPlannerWaitTool(tool, session, env, registrations) {
  try {
    if (!isPlannerWaitEnabled(env))
      return;
    const cfg = readPlannerWaitBridgeConfig(env);
    const t = tool;
    if (!cfg.ok || !t || typeof t.transform !== "function") {
      try {
        writeUnavailable("v2", "planner-wait unavailable");
      } catch {}
      return;
    }
    let fixtureOk = false;
    try {
      const checked = checkPlannerWaitFixtureFiles(lstatSync, cfg.bridge, cfg.shell);
      fixtureOk = !!checked && checked.ok === true;
    } catch {
      fixtureOk = false;
    }
    if (!fixtureOk) {
      try {
        writeUnavailable("v2", "planner-wait unavailable");
      } catch {}
      return;
    }
    let sessionGet;
    try {
      const get = session?.get;
      if (typeof get === "function") {
        const bound = get.bind(session);
        sessionGet = (id) => bound({ sessionID: id });
      }
    } catch {
      sessionGet = undefined;
    }
    const fullCfg = { bridge: cfg.bridge, shell: cfg.shell, timeoutMs: cfg.timeoutMs };
    const handler = makePlannerWaitExecute(fullCfg, {
      spawnFn: (exe, argv, opts) => spawnBridgeProcess(exe, argv, opts),
      sessionGet
    });
    const toolDef = {
      name: PLANNER_WAIT_TOOL_NAME,
      description: "Registers the Planner root-session binding (Phase 32 CAS) and a GitHub CI/PR wait. Planner root sessions only.",
      input: PLANNER_WAIT_INPUT_SCHEMA,
      execute: async (args, context) => handler(args, context)
    };
    try {
      const reg = await t.transform((editor) => {
        editor.add(toolDef);
      });
      if (reg && typeof reg.dispose === "function")
        registrations.push(reg);
    } catch {
      try {
        writeUnavailable("v2", "planner-wait unavailable");
      } catch {}
    }
  } catch {
    try {
      writeUnavailable("v2", "planner-wait unavailable");
    } catch {}
  }
}
async function setupV2(ctx) {
  const registrations = [];
  let eventController = null;
  try {
    const c = ctx;
    if (!c || typeof c !== "object")
      return;
    try {
      try {
        if (!c.event || typeof c.event.subscribe !== "function") {
          writeUnavailable("v2", "event.subscribe unavailable");
        }
      } catch {}
      try {
        if (!c.session || typeof c.session.hook !== "function") {
          writeUnavailable("v2", "session.hook unavailable");
        }
      } catch {}
      try {
        if (!c.tool || typeof c.tool.hook !== "function") {
          writeUnavailable("v2", "tool.hook unavailable");
        }
      } catch {}
    } catch {}
    try {
      const ev = c.event;
      if (ev && typeof ev.subscribe === "function") {
        try {
          const controller = new AbortController;
          eventController = controller;
          const stream = ev.subscribe({ signal: controller.signal });
          (async () => {
            try {
              for await (const e of stream) {
                try {
                  if (controller.signal.aborted)
                    return;
                } catch {
                  return;
                }
                try {
                  recordSessionEvent(sessionIndex2, e);
                } catch {}
                try {
                  if (controller.signal.aborted)
                    return;
                } catch {
                  return;
                }
              }
            } catch {}
          })();
        } catch {
          try {
            writeUnavailable("v2", "event.subscribe unavailable");
          } catch {}
        }
      }
    } catch {}
    await subscribe(registrations, c.session, "context", async (input) => {
      let pending = null;
      try {
        const inp = input;
        if (!inp || typeof inp !== "object" || Array.isArray(inp))
          return;
        const system = inp.system;
        if (!Array.isArray(system))
          return;
        if (hasMarker(system))
          return;
        const sid = readSessionID(inp) ?? (typeof inp.sessionID === "string" ? inp.sessionID : undefined);
        const probe = readAgent(inp) ?? (typeof inp.agent === "string" ? inp.agent : undefined);
        const r = resolveRole(lookupSession(sessionIndex2, sid), probe);
        const m = mandateFor(r.role, "v2");
        if (!appendTextPart(system, m.text))
          return;
        const sessionType = r.role === "neutral" ? "unknown" : r.role;
        pending = {
          sessionType,
          agent: r.agent,
          mandateKind: m.kind,
          markerUsed: m.marker,
          session: sid,
          identitySource: r.source
        };
      } catch {
        return;
      }
      if (pending)
        writeInjection("v2", pending);
    });
    await subscribe(registrations, c.tool, "execute.before", async (input) => {
      try {
        const inp = input;
        if (!inp || typeof inp !== "object")
          return;
        writeToolEvent("v2", { tool: inp.tool, session: inp.sessionID, agent: inp.agent });
        try {
          observeMcpBeforeExecute("v2", {
            tool: inp.tool,
            turn: inp.turnID !== undefined ? inp.turnID : inp.turnId,
            criticality: inp.criticality
          });
        } catch {}
      } catch {}
    });
    try {
      setMcpPolicyFileReader(readMcpPolicyFileBounded);
    } catch {}
    try {
      const cAny = c;
      let env = {};
      try {
        const pe = typeof process !== "undefined" ? process.env : undefined;
        env = readPlannerWaitEnv(pe);
      } catch {
        env = {};
      }
      await setupPlannerWaitTool(cAny.tool, cAny.session, env, registrations);
    } catch {}
  } catch {
    return;
  }
  return () => {
    try {
      if (eventController) {
        try {
          eventController.abort();
        } catch {}
        eventController = null;
      }
    } catch {}
    try {
      sessionIndex2.clear();
    } catch {}
    for (const reg of registrations) {
      try {
        const r = reg.dispose();
        if (r && typeof r.catch === "function") {
          r.catch(() => {
            return;
          });
        }
      } catch {}
    }
  };
}
var V2Plugin = {
  id: V2_ID,
  setup: setupV2
};

// plugins/orchestration-enforcement.ts
async function server(ctx) {
  if (ctx === undefined)
    return OrchestrationEnforcement;
  return OrchestrationEnforcement(ctx);
}
async function setup(ctx) {
  return V2Plugin.setup(ctx);
}
var DualExport = {
  id: V2_ID,
  setup,
  server
};
var orchestration_enforcement_default = DualExport;
export {
  setMcpPolicyFileReader,
  runMcpGuarded,
  resolveMcpPolicy,
  resetMcpTransport,
  pendingMcpDeadlines,
  observeMcpBeforeExecute,
  normalizeMcpTurn,
  normalizeMcpCriticality,
  normalizeMcpClass,
  mcpResultGrantsAuthority,
  getMcpTransportConfig,
  getMcpCircuitSnapshot,
  effectiveMcpMode,
  orchestration_enforcement_default as default,
  configureMcpTransport,
  classifyMcpTool,
  __orchestrationEnforcementTest,
  __mcpTransportTest,
  V2_ID,
  OrchestrationEnforcement
};
