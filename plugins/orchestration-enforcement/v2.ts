// V2 adapter: Plugin.define({ id, setup }) shape for the V2 host
// (@opencode/plugin 2.x). The ONLY external import is `import type`
// (erased at build): this file emits zero runtime references to any
// package, so the V1 host never loads V2 APIs and vice versa. At runtime
// the exported { id, setup } object literal is structurally identical to
// what Plugin.define() returns (define is the identity function), so no
// runtime import of @opencode/plugin is needed on either host.
//
// Mandate injection uses the "context" session hook: it is the documented
// V2 counterpart of V1's experimental.chat.system.transform — it runs when
// the session context (system parts + messages + tools) is assembled,
// before generation, and receives a MUTABLE input (single argument, no
// separate output object). The "prompt" hook is admission-time (too early:
// no system array to coalesce into); "compaction"/"generate"/"title" are
// auxiliary requests that must not carry the enforcement mandate.
// System parts in V2 are Array<{ type: "text", text }> (NOT strings), so
// injection appends one text part instead of coalescing into system[0].
//
// Observability minimum: ctx.tool.hook("execute.before") records tool
// name + session (sanitized) and NEVER blocks — grant binding is a later
// phase. Every hook fails open: any exception is swallowed after a
// best-effort error telemetry write, never propagated to the runtime.
import type { Plugin } from "@opencode/plugin";
import type { SessionEntry } from "./shared/types";
import {
  indexSession,
  lookupSession,
  readAgent,
  readSessionID,
  recordSessionEvent,
  resolveRole,
} from "./shared/identity";
import { lstatSync, readFileSync, statSync } from "node:fs";
import { spawn as spawnBridgeProcess } from "node:child_process";
import type { Info as ToolInfo, ToolContext, ToolDomain } from "@opencode/plugin/promise/tool";
import {
  PLANNER_WAIT_INPUT_SCHEMA,
  PLANNER_WAIT_TOOL_NAME,
  checkPlannerWaitFixtureFiles,
  isPlannerWaitEnabled,
  makePlannerWaitExecute,
  readPlannerWaitBridgeConfig,
  readPlannerWaitEnv,
} from "./shared/planner-wait";
import { appendTextPart, hasMarker, mandateFor } from "./shared/mandate";
import {
  observeMcpBeforeExecute,
  setMcpPolicyFileReader,
} from "./shared/mcp-transport";
import { loggedSize, writeInjection, writeToolEvent, writeUnavailable } from "./shared/telemetry";

export const V2_ID = "orchestration-enforcement";

// Bounded policy-file reader for the MCP transport envelope (Phase 28
// slice 2): absolute paths only, regular files only, 64 KiB cap,
// utf8, every failure => null (the envelope then uses the embedded
// defaults, which mirror the canonical policy exactly). Installed at
// setup; fail-open throughout. NEVER throws.
function readMcpPolicyFileBounded(absPath: unknown): string | null {
  try {
    if (typeof absPath !== "string") return null;
    const t = absPath.trim();
    if (t.length === 0 || t.length > 512) return null;
    const isAbs = t.charAt(0) === "/" || /^[A-Za-z]:[\\/]/.test(t);
    if (!isAbs) return null;
    let size = -1;
    let isFile = false;
    try {
      const st = statSync(t);
      isFile = st.isFile();
      size = st.size;
    } catch {
      return null;
    }
    if (!isFile) return null;
    if (size <= 0 || size > 65536) return null;
    let text = "";
    try {
      text = readFileSync(t, "utf8");
    } catch {
      return null;
    }
    // Post-read re-check: covers the stat/read window (the file may
    // have grown between stat and read). Oversized or empty content
    // is refused, so the envelope falls back to the embedded
    // defaults with a policy-fallback telemetry row.
    if (text.length === 0 || text.length > 65536) return null;
    return text;
  } catch {
    return null;
  }
}

const sessionIndex = new Map<string, SessionEntry>();

type AnyFn = (...args: Array<any>) => any;

async function subscribe(
  registrations: Array<{ dispose: () => unknown }>,
  owner: any,
  name: string,
  callback: AnyFn,
): Promise<void> {
  try {
    if (!owner || typeof owner.hook !== "function") return;
    const reg = await (owner.hook as AnyFn).call(owner, name, callback);
    if (reg && typeof reg.dispose === "function") registrations.push(reg);
  } catch {
    // Fail-open: a missing/renamed hook never breaks setup.
  }
}

// PR181 Fatia A: single native tool `orchestration_planner_wait` on the
// EXISTING V2 setup path. Opt-in, disabled by default: without
// OPENCODE_PLANNER_WAIT_ENABLED=1 nothing is registered (zero behavior
// change). When enabled, the tool validates Planner-root authorization
// (host ToolContext sessionID/agent only; model-supplied session keys
// refused) and spawns the fixture-owned PowerShell bridge, which performs
// the Phase 32 root-session CAS bind plus the GitHub wait registration.
// Fail-open throughout: any doubt skips registration (with a
// hooks-unavailable telemetry row) and setup never throws.
async function setupPlannerWaitTool(
  tool: unknown,
  session: unknown,
  env: Record<string, string | undefined>,
  registrations: Array<{ dispose: () => unknown }>,
): Promise<void> {
  try {
    if (!isPlannerWaitEnabled(env)) return;
    const cfg = readPlannerWaitBridgeConfig(env);
    const t = tool as ToolDomain | null | undefined;
    if (!cfg.ok || !t || typeof (t as unknown as Record<string, unknown>).transform !== "function") {
      try {
        writeUnavailable("v2", "planner-wait unavailable");
      } catch {
        // Fail-open.
      }
      return;
    }
    let fixtureOk = false;
    try {
      // lstat (never stat) on BOTH bridge and shell: a symlink at either
      // path denies even when it resolves to a regular file. Residual: this
      // check is not atomic with the later spawn (TOCTOU); the bridge
      // response stays strictly parsed and authority pins stay false.
      const checked = checkPlannerWaitFixtureFiles(lstatSync, cfg.bridge, cfg.shell);
      fixtureOk = !!checked && checked.ok === true;
    } catch {
      fixtureOk = false;
    }
    if (!fixtureOk) {
      try {
        writeUnavailable("v2", "planner-wait unavailable");
      } catch {
        // Fail-open.
      }
      return;
    }
    let sessionGet: ((id: string) => Promise<unknown>) | undefined;
    try {
      const get = (session as unknown as Record<string, unknown>)?.get;
      if (typeof get === "function") {
        const bound = (get as (...a: Array<any>) => Promise<unknown>).bind(session);
        // Exact pin @opencode/plugin 2.0.23 (Promise layer): get({sessionID})
        // => Promise<SessionInfo> (direct; the Promise adapter already
        // unwraps the {data} transport envelope). Never a bare string arg.
        sessionGet = (id: string) => bound({ sessionID: id });
      }
    } catch {
      sessionGet = undefined;
    }
    const fullCfg = { bridge: cfg.bridge, shell: cfg.shell, timeoutMs: cfg.timeoutMs };
    const handler = makePlannerWaitExecute(fullCfg, {
      spawnFn: (exe, argv, opts) => spawnBridgeProcess(exe, argv, opts),
      sessionGet,
    });
    // Pinned-API proof (2.0.23): this literal is checked by tsc against
    // `Info` from @opencode/plugin/promise/tool — {name, input,
    // description, execute}. A wrong key (id/parameters/args) or a wrong
    // input/execute shape fails the V2 typecheck track.
    const toolDef: ToolInfo = {
      name: PLANNER_WAIT_TOOL_NAME,
      description:
        "Registers the Planner root-session binding (Phase 32 CAS) and a GitHub CI/PR wait. Planner root sessions only.",
      input: PLANNER_WAIT_INPUT_SCHEMA,
      execute: async (args: unknown, context: ToolContext) => handler(args, context),
    };
    try {
      const reg = await t.transform((editor) => {
        editor.add(toolDef);
      });
      if (reg && typeof reg.dispose === "function") registrations.push(reg);
    } catch {
      try {
        writeUnavailable("v2", "planner-wait unavailable");
      } catch {
        // Fail-open.
      }
    }
  } catch {
    try {
      writeUnavailable("v2", "planner-wait unavailable");
    } catch {
      // Fail-open.
    }
  }
}

async function setupV2(ctx: any): Promise<(() => void) | void> {
  const registrations: Array<{ dispose: () => unknown }> = [];
  let eventController: AbortController | null = null;
  try {
    const c = ctx as any;
    if (!c || typeof c !== "object") return undefined;

    // FEATURE DETECTION (V31-R2 F3, Phase 24 fatia 1): verify each surface
    // used below is a function BEFORE registering. Lifecycle indexing now
    // uses the documented ctx.event.subscribe({ signal }) AsyncIterable
    // (addenda Part H, sec 24); the old event.hook("session.created" /
    // "session.updated") shape is obsolete and never fires on host 2.0.18.
    // Any missing/non-function surface emits one 'hooks-unavailable'
    // telemetry row (same jsonl, with the surface as reason) and setup
    // continues with whatever IS available. Never throws: every probe is
    // guarded and the writer is fail-open.
    try {
      try {
        if (!c.event || typeof c.event.subscribe !== "function") {
          writeUnavailable("v2", "event.subscribe unavailable");
        }
      } catch {
        // Fail-open: one bad probe never blocks the others.
      }
      try {
        if (!c.session || typeof c.session.hook !== "function") {
          writeUnavailable("v2", "session.hook unavailable");
        }
      } catch {
        // Fail-open: one bad probe never blocks the others.
      }
      try {
        if (!c.tool || typeof c.tool.hook !== "function") {
          writeUnavailable("v2", "tool.hook unavailable");
        }
      } catch {
        // Fail-open: one bad probe never blocks the others.
      }
    } catch {
      // Fail-open: detection itself never breaks setup.
    }

    // Lifecycle indexing (parentID => worker detection) via the documented
    // V2 event stream: ctx.event.subscribe({ signal }) returns an
    // AsyncIterable. Setup NEVER awaits the infinite stream: it starts a
    // detached loop with its own AbortController and returns; the cleanup
    // callback aborts it. Filtering lives in recordSessionEvent (tolerant
    // envelope in shared/identity.ts): only session.created/session.updated
    // populate the index, unknown shapes are a no-op. Fail-open throughout.
    // session.hook("context") and tool.hook("execute.before") below are
    // untouched: both surfaces are confirmed valid on host 2.0.18.
    try {
      const ev = c.event;
      if (ev && typeof ev.subscribe === "function") {
        try {
          const controller = new AbortController();
          eventController = controller;
          const stream = ev.subscribe({ signal: controller.signal });
          // Detached on purpose: setup resolves while this loop lives on
          // until cleanup aborts it. Never awaited here.
          void (async () => {
            try {
              for await (const e of stream as AsyncIterable<unknown>) {
                // RR-P24-REV-FIX: checar abort ANTES de indexar. Sem isso, um
                // next() ja pendente que resolve com evento apos o cleanup
                // ainda popularia o indice (corrida). Abort antes => drop.
                try {
                  if (controller.signal.aborted) return;
                } catch {
                  return;
                }
                try {
                  recordSessionEvent(sessionIndex, e);
                } catch {
                  // NEVER throw out of the lifecycle loop.
                }
                try {
                  if (controller.signal.aborted) return;
                } catch {
                  return;
                }
              }
            } catch {
              // Fail-open: stream errors end the loop silently.
            }
          })();
        } catch {
          // Fail-open: subscribe failure stays best-effort.
          try {
            writeUnavailable("v2", "event.subscribe unavailable");
          } catch {
            // Fail-open.
          }
        }
      }
    } catch {
      // Fail-open: event indexing is best-effort in V2.
    }

    // Mandate injection on session context assembly.
    await subscribe(registrations, c.session, "context", async (input: any) => {
      let pending: {
        sessionType: "planner" | "worker" | "unknown";
        agent: string | undefined;
        mandateKind: "planner" | "worker" | "neutral";
        markerUsed: string;
        session: string | undefined;
        identitySource: "session-map" | "input-probe" | "none";
      } | null = null;
      try {
        const inp = input as any;
        if (!inp || typeof inp !== "object" || Array.isArray(inp)) return;
        const system = inp.system;
        if (!Array.isArray(system)) return;
        // Idempotence: any part already carrying a marker => no-op.
        if (hasMarker(system)) return;
        // Identity: session-map first, then the typed agent field plus
        // generic input probing, else neutral. The V2 context input
        // carries `agent` and `sessionID` as first-class fields.
        const sid = readSessionID(inp) ?? (typeof inp.sessionID === "string" ? inp.sessionID : undefined);
        const probe = readAgent(inp) ?? (typeof inp.agent === "string" ? inp.agent : undefined);
        const r = resolveRole(lookupSession(sessionIndex, sid), probe);
        const m = mandateFor(r.role, "v2");
        if (!appendTextPart(system, m.text)) return;
        const sessionType = r.role === "neutral" ? "unknown" : r.role;
        pending = {
          sessionType,
          agent: r.agent,
          mandateKind: m.kind,
          markerUsed: m.marker,
          session: sid,
          identitySource: r.source,
        };
      } catch {
        return; // fail-safe silent: no injection, no crash
      }
      if (pending) writeInjection("v2", pending);
    });

    // Observability minimum: tool events, never blocking.
    // MCP transport observation (Phase 28 slice 2): classifies the
    // tool and reports a would-block when the circuit is open. Shadow
    // semantics: observe only, NEVER cancel the execution. Fail-open.
    await subscribe(registrations, c.tool, "execute.before", async (input: any) => {
      try {
        const inp = input as any;
        if (!inp || typeof inp !== "object") return;
        writeToolEvent("v2", { tool: inp.tool, session: inp.sessionID, agent: inp.agent });
        try {
          observeMcpBeforeExecute("v2", {
            tool: inp.tool,
            turn: inp.turnID !== undefined ? inp.turnID : inp.turnId,
            criticality: inp.criticality,
          });
        } catch {
          // Fail-open: MCP observation never breaks tool execution.
        }
      } catch {
        // Fail-open: observability never breaks tool execution.
      }
    });
    // Install the bounded MCP policy-file reader (absolute paths only;
    // without an explicit path configured the envelope stays on the
    // embedded defaults and performs no file access). Fail-open.
    try {
      setMcpPolicyFileReader(readMcpPolicyFileBounded);
    } catch {
      // Fail-open: envelope works on embedded defaults regardless.
    }
    // PR181 Fatia A (opt-in, off by default): Planner root-session
    // binding + GitHub wait tool on the existing setup path. No env =>
    // no registration. Never throws.
    try {
      const cAny = c as any;
      let env: Record<string, string | undefined> = {};
      try {
        const pe = (typeof process !== "undefined" ? (process as any).env : undefined) as unknown;
        env = readPlannerWaitEnv(pe);
      } catch {
        env = {};
      }
      await setupPlannerWaitTool(cAny.tool, cAny.session, env, registrations);
    } catch {
      // Fail-open: planner-wait never breaks setup.
    }
  } catch {
    // Fail-open: setup never throws to the runtime.
    return undefined;
  }
  return () => {
    try {
      if (eventController) {
        try {
          eventController.abort();
        } catch {
          // Fail-open.
        }
        eventController = null;
      }
    } catch {
      // Fail-open.
    }
    try {
      sessionIndex.clear();
    } catch {
      // Fail-open.
    }
    for (const reg of registrations) {
      try {
        const r = reg.dispose();
        if (r && typeof (r as Promise<unknown>).catch === "function") {
          (r as Promise<unknown>).catch(() => undefined);
        }
      } catch {
        // Fail-open: cleanup is best-effort.
      }
    }
    void loggedSize;
  };
}

// Structural V2 plugin: { id, setup }. No Plugin.define() call is needed
// at runtime (define is the identity function); the type import above
// only constrains this shape at typecheck time.
export const V2Plugin: { id: string; setup: (ctx: any) => Promise<(() => void) | void> } = {
  id: V2_ID,
  setup: setupV2,
};

// Type-level conformance: our structural shape must satisfy the real V2
// Plugin type. This assignment is checked by tsc (V2 track) and emits no
// runtime reference to the package.
const _assertConformance: Plugin.Plugin = V2Plugin;
void _assertConformance;

export const __orchestrationEnforcementV2Test = {
  id: V2_ID,
  sessionIndexSize: (): number => {
    try {
      return sessionIndex.size;
    } catch {
      return -1;
    }
  },
  loggedSize: (): number => {
    try {
      return loggedSize();
    } catch {
      return -1;
    }
  },
  readPolicyFileBounded: (p: unknown): string | null => {
    try {
      return readMcpPolicyFileBounded(p);
    } catch {
      return null;
    }
  },
};

// PR181 Fatia A test hook: exposes the planner-wait wiring for the
// distribution mock (tests/distribution/plugin-harness/v2-mock.ts).
// Runtime shape is identical to the separate-slice hook it replaces.
export const __plannerWaitV2Test = {
  toolName: PLANNER_WAIT_TOOL_NAME,
  inputSchema: PLANNER_WAIT_INPUT_SCHEMA,
  isEnabled: isPlannerWaitEnabled,
  readEnv: readPlannerWaitEnv,
  readBridgeConfig: readPlannerWaitBridgeConfig,
  makeExecute: makePlannerWaitExecute,
  checkFixture: checkPlannerWaitFixtureFiles,
};
