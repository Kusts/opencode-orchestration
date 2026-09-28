// Telemetry writer shared by both runtime adapters.
// This is the ONLY shared module allowed Node imports (fs/os/path for the
// jsonl sink). It never imports a runtime package. Same path, same
// sanitize, same fail-open as the V1 original; each line gains a
// "runtime": "v1"|"v2" field so injections are attributable per runtime.
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { InjectionRecord, RuntimeId } from "./types";
import { sanitizeOpt, setAddBounded } from "./sanitize";
import { INDEX_CAP } from "./identity";

// Logged once per (runtime, session, marker) to avoid unbounded log
// growth; capped at INDEX_CAP entries with oldest-first eviction.
// NEVER throws; module-level because one process hosts one runtime.
const logged = new Set<string>();

export function loggedSize(): number {
  try {
    return logged.size;
  } catch {
    return -1;
  }
}

function telemetryPath(): string | null {
  try {
    const dir = join(homedir(), ".opencode-orchestration", "evidence", "v3", "orchestration");
    mkdirSync(dir, { recursive: true });
    return join(dir, "session-injections.jsonl");
  } catch {
    return null;
  }
}

export function writeInjection(runtime: RuntimeId, rec: InjectionRecord): void {
  try {
    const agent = sanitizeOpt(rec.agent);
    const session = sanitizeOpt(rec.session);
    const key = runtime + "::" + (session ?? "null") + "::" + rec.markerUsed;
    if (logged.has(key)) return;
    const path = telemetryPath();
    if (path === null) return;
    const line: Record<string, string> = {
      ts: new Date().toISOString(),
      runtime,
      sessionType: rec.sessionType,
      mandate: rec.mandateKind,
      markerUsed: rec.markerUsed,
      identity_source: rec.identitySource,
    };
    if (agent) line["agent"] = agent;
    if (session) line["session"] = session;
    appendFileSync(path, JSON.stringify(line) + "\n", "utf8");
    setAddBounded(logged, key, INDEX_CAP);
  } catch {
    // Fail-open: telemetry never breaks the session.
  }
}

// Feature-detection signal (V31-R2 F3): records which V2 hook surface
// was unavailable at setup time. Same jsonl sink, same fail-open policy;
// reason is a caller-owned constant (never user input). NEVER throws.
export function writeUnavailable(runtime: RuntimeId, reason: string): void {
  try {
    const r = (reason || "").trim();
    if (r.length === 0) return;
    const key = runtime + "::hooks-unavailable::" + r;
    if (logged.has(key)) return;
    const path = telemetryPath();
    if (path === null) return;
    const line: Record<string, string> = {
      ts: new Date().toISOString(),
      runtime,
      kind: "hooks-unavailable",
      reason: r,
    };
    appendFileSync(path, JSON.stringify(line) + "\n", "utf8");
    setAddBounded(logged, key, INDEX_CAP);
  } catch {
    // Fail-open: telemetry never breaks the session.
  }
}

// Minimal V2 tool observability (Phase 4): record tool name + session +
// agent, sanitized, never blocking. Grant binding is a later phase.
export function writeToolEvent(
  runtime: RuntimeId,
  fields: { tool: unknown; session: unknown; agent: unknown },
): void {
  try {
    const tool = sanitizeOpt(fields.tool);
    const session = sanitizeOpt(fields.session);
    const agent = sanitizeOpt(fields.agent);
    const key = runtime + "::tool::" + (session ?? "null") + "::" + (tool ?? "null");
    if (logged.has(key)) return;
    const path = telemetryPath();
    if (path === null) return;
    const line: Record<string, string> = {
      ts: new Date().toISOString(),
      runtime,
      kind: "tool-event",
      identity_source: "input-probe",
    };
    if (tool) line["tool"] = tool;
    if (session) line["session"] = session;
    if (agent) line["agent"] = agent;
    appendFileSync(path, JSON.stringify(line) + "\n", "utf8");
    setAddBounded(logged, key, INDEX_CAP);
  } catch {
    // Fail-open: telemetry never breaks the session.
  }
}
