// RR-P24-LIVEHOOK fixture (fase 24 fatia 2): minimal V2 plugin ({ id, setup })
// exercising the exact surfaces the dist plugin relies on, observed into a
// temp JSONL sink. ESM, zero deps beyond node:fs/node:path (same allowance
// as the dist bundle telemetry). Fail-open everywhere; never throws.
// Sink path comes ONLY from RR_P24_LIVEHOOK_JSONL (temp-owned). All recorded
// values are identifiers/markers/type names, length-capped and charset
// gated; anything else becomes "redacted". No secrets, no tokens, no bodies.
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const SINK = process.env.RR_P24_LIVEHOOK_JSONL || "";

function row(obj) {
  try {
    if (!SINK) return;
    mkdirSync(dirname(SINK), { recursive: true });
    const base = { ts: new Date().toISOString() };
    const keys = Object.keys(obj || {});
    for (const k of keys) {
      try {
        base[k] = obj[k];
      } catch (e) {}
    }
    appendFileSync(SINK, JSON.stringify(base) + "\n", "utf8");
  } catch (e) {}
}

function safeId(v) {
  try {
    if (typeof v !== "string") return undefined;
    const t = v.trim();
    if (t.length === 0 || t.length > 128) return undefined;
    if (/^[A-Za-z0-9._:@-]*$/.test(t)) return t;
    return "redacted";
  } catch (e) {
    return undefined;
  }
}

function tname(v) {
  try {
    return typeof v;
  } catch (e) {
    return "probe-error";
  }
}

const regs = [];
let ctrl = null;

async function setup(ctx) {
  row({ kind: "BOOT", id: "rr-p24-livehook-fixture" });
  // Feature detection on the REAL host: presence/absence of every surface
  // the dist plugin needs, including interrupt/wait (HOLD-2 candidates).
  try {
    row({
      kind: "FEATURES",
      eventSubscribe: tname(ctx && ctx.event ? ctx.event.subscribe : undefined),
      sessionHook: tname(ctx && ctx.session ? ctx.session.hook : undefined),
      toolHook: tname(ctx && ctx.tool ? ctx.tool.hook : undefined),
      sessionInterrupt: tname(ctx && ctx.session ? ctx.session.interrupt : undefined),
      sessionWait: tname(ctx && ctx.session ? ctx.session.wait : undefined)
    });
  } catch (e) {
    row({ kind: "FEATURES_ERROR" });
  }
  // Lifecycle stream with session.created/session.updated filter.
  try {
    if (ctx && ctx.event && typeof ctx.event.subscribe === "function") {
      ctrl = new AbortController();
      const stream = ctx.event.subscribe({ signal: ctrl.signal });
      row({ kind: "SUBSCRIBED" });
      void (async () => {
        try {
          for await (const e of stream) {
            // RR-P24-TRIGGER-FIX (2): guard ANTERIOR — verificar abort ANTES
            // de interpretar/gravar cada evento. Posterior mantido abaixo.
            try {
              if (ctrl && ctrl.signal.aborted) return;
            } catch (ee) {
              return;
            }
            try {
              let t = "unknown";
              try {
                if (e && typeof e.type === "string") t = e.type;
              } catch (ee) {}
              if (t === "session.created" || t === "session.updated") {
                let sid = undefined;
                // RR-P24-TRIGGER-FIX (4): distinguir event.id de session id.
                // Campos de sessao reais primeiro; e.id (id do EVENTO) por
                // ultimo, nunca como primeira opcao. Ordem: sessionID,
                // sessionId, session.id, data.id, data.sessionID, sessionID
                // aninhado, e so entao e.id.
                try {
                  if (e && typeof e.sessionID === "string") sid = e.sessionID;
                  else if (e && typeof e.sessionId === "string") sid = e.sessionId;
                  else if (e && e.session && typeof e.session.id === "string") sid = e.session.id;
                  else if (e && e.session && typeof e.session.sessionID === "string") sid = e.session.sessionID;
                  else if (e && e.data && typeof e.data.sessionID === "string") sid = e.data.sessionID;
                  else if (e && e.data && typeof e.data.sessionId === "string") sid = e.data.sessionId;
                  else if (e && e.data && typeof e.data.id === "string") sid = e.data.id;
                  else if (e && typeof e.id === "string") sid = e.id;
                } catch (ee) {}
                row({ kind: "EVENT", type: t.slice(0, 64), session: safeId(sid) });
              }
            } catch (ee) {}
            try {
              if (ctrl && ctrl.signal.aborted) return;
            } catch (ee) {
              return;
            }
          }
        } catch (ee) {
          try {
            row({ kind: "STREAM_END" });
          } catch (eee) {}
        }
      })();
    } else {
      row({ kind: "SUBSCRIBE_UNAVAILABLE" });
    }
  } catch (e) {
    try {
      row({ kind: "SUBSCRIBE_ERROR" });
    } catch (ee) {}
  }
  // Context hook registration (fires on generation; needs a model run).
  try {
    if (ctx && ctx.session && typeof ctx.session.hook === "function") {
      const r = await ctx.session.hook("context", async (input) => {
        try {
          row({ kind: "CONTEXT_FIRED", session: safeId(input ? input.sessionID : undefined) });
        } catch (e) {}
      });
      if (r && typeof r.dispose === "function") regs.push(r);
      row({ kind: "CONTEXT_REGISTERED" });
    } else {
      row({ kind: "CONTEXT_UNAVAILABLE" });
    }
  } catch (e) {
    try {
      row({ kind: "CONTEXT_ERROR" });
    } catch (ee) {}
  }
  // Tool hook registration (fires on tool execution; needs a model run).
  try {
    if (ctx && ctx.tool && typeof ctx.tool.hook === "function") {
      const r2 = await ctx.tool.hook("execute.before", async (input) => {
        try {
          row({
            kind: "TOOL_FIRED",
            tool: safeId(input ? input.tool : undefined),
            session: safeId(input ? input.sessionID : undefined)
          });
        } catch (e) {}
      });
      if (r2 && typeof r2.dispose === "function") regs.push(r2);
      row({ kind: "TOOL_REGISTERED" });
    } else {
      row({ kind: "TOOL_UNAVAILABLE" });
    }
  } catch (e) {
    try {
      row({ kind: "TOOL_ERROR" });
    } catch (ee) {}
  }
  return () => {
    try {
      row({ kind: "CLEANUP" });
    } catch (e) {}
    try {
      if (ctrl) ctrl.abort();
    } catch (e) {}
    for (const r of regs) {
      try {
        r.dispose();
      } catch (e) {}
    }
  };
}

const Fixture = { id: "rr-p24-livehook-fixture", setup: setup };
export default Fixture;
