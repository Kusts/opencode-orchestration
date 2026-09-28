// V1 adapter: same hook signatures as the original V1-only plugin
// (event() + experimental.chat.system.transform), delegating ALL policy
// to shared/ (identity with generation "v1", mandate, sanitize,
// telemetry with runtime "v1").
//
// The ONLY external import is `import type` (erased at build): this file
// emits zero runtime references to any package, so it loads identically
// inside a V1 host with or without V2 artifacts present.
import type { Plugin } from "@opencode-ai/plugin";
import type { SessionEntry } from "./shared/types";
import {
  INDEX_CAP,
  lookupSession,
  readAgent,
  readSessionID,
  recordSessionEvent,
  resolveRole,
} from "./shared/identity";
import { coalesceString, hasMarker, mandateFor } from "./shared/mandate";
import { loggedSize, writeInjection } from "./shared/telemetry";

const sessionIndex = new Map<string, SessionEntry>();

// Fail-safe client capture. Reserved for a future one-shot
// client.session.get lookup — NOT used today: the event map alone is
// authoritative, and an extra fetch would add async failure modes inside
// the injection path for no guaranteed signal (client shape varies across
// 1.18.x builds). Simple and correct beats clever and fragile here.
let sessionClient: any = undefined;

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
        recordSessionEvent(sessionIndex, input);
      } catch {
        // NEVER throw out of a lifecycle hook.
      }
    },
    "experimental.chat.system.transform": async (input: any, output: any) => {
      let pending: {
        sessionType: "planner" | "worker" | "unknown";
        agent: string | undefined;
        mandateKind: "planner" | "worker" | "neutral";
        markerUsed: string;
        session: string | undefined;
        identitySource: "session-map" | "input-probe" | "none";
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
        if (hasMarker(system)) return;
        // 2./3. Identity: session-map first, input-probe fallback, else neutral.
        // Coalesce into system[0], or create the first entry.
        const sid = readSessionID(input);
        const r = resolveRole(lookupSession(sessionIndex, sid), readAgent(input));
        const m = mandateFor(r.role, "v1");
        if (!coalesceString(system as Array<string>, m.text)) return; // malformed first entry => fail-safe
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
      if (pending) writeInjection("v1", pending);
    },
  } as any;
};

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
      return loggedSize();
    } catch {
      return -1;
    }
  },
};
