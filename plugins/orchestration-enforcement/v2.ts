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
import { appendTextPart, hasMarker, mandateFor } from "./shared/mandate";
import { loggedSize, writeInjection, writeToolEvent, writeUnavailable } from "./shared/telemetry";

export const V2_ID = "orchestration-enforcement";

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
    await subscribe(registrations, c.tool, "execute.before", async (input: any) => {
      try {
        const inp = input as any;
        if (!inp || typeof inp !== "object") return;
        writeToolEvent("v2", { tool: inp.tool, session: inp.sessionID, agent: inp.agent });
      } catch {
        // Fail-open: observability never breaks tool execution.
      }
    });
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
};
