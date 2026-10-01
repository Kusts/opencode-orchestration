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
  "Mandatory orchestration preflight before the first action: classify the task as TRIVIAL_DIRECT (only with a closed reason token: DIRECT_TRIVIAL_LOCALIZED, DIRECT_READ_ONLY_POINT_LOOKUP, DIRECT_COSMETIC_NO_LOGIC, DIRECT_FORMATTING_ONLY), DELEGATED, DETERMINISTIC_FALLBACK, or BLOCKED.",
  "Non-trivial tasks require material participation of at least one suitable subagent; doing everything alone without a recorded decision is ORCHESTRATION_POLICY_BYPASS.",
  "For relevant changes, follow the coder → tester → reviewer cycle and integrate their syntheses. DONE requires observed worker participation on non-trivial work.",
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
  const lines = kind === "worker" ? WORKER_LINES : kind === "planner" ? PLANNER_LINES : NEUTRAL_LINES;
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
var V2_ID = "orchestration-enforcement";
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
      } catch {}
    });
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
  orchestration_enforcement_default as default,
  __orchestrationEnforcementTest,
  V2_ID,
  OrchestrationEnforcement
};
