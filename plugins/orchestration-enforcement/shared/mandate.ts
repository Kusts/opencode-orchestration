// Single rule set for mandate text shared by both runtime adapters.
// PURE: imports only sibling shared types, never a runtime package.
//
// Text contract: generation "v1" renders BYTE-IDENTICAL mandates to the
// V1 original (markers [orchestration-enforcement:v1] and
// [orchestration-enforcement:v1:worker]). Generation "v2" renders the
// same sentences with v2 markers so telemetry can tell injections apart.
import type { Generation, MandateKind, Role } from "./types";

// Broad idempotence substring: covers planner/worker markers of BOTH
// generations. In a V1-only runtime v2 markers never occur, so V1
// behavior is unchanged; in a V2 runtime an already-injected context is
// never double-wrapped. The legacy V1-only substring
// ("orchestration-enforcement:v1") remains a subset of this one.
export const MARKER_SUBSTRING = "orchestration-enforcement:";

const PLANNER_LINES: ReadonlyArray<string> = [
  "Mandatory orchestration preflight before the first action: classify the task as SINGLE_WORKER, MULTI_WORKER, PERSISTENT_GOAL, DETERMINISTIC_FALLBACK, or BLOCKED. SINGLE_WORKER is full orchestration (Planner -> one cheap worker -> Planner); the Planner never performs the user's operational work directly when a suitable worker exists.",
  "Non-trivial tasks require material participation of at least one suitable subagent; doing everything alone without a recorded decision is ORCHESTRATION_POLICY_BYPASS.",
  "For relevant changes, follow the coder → tester → reviewer cycle and integrate their syntheses. DONE requires observed worker participation on non-trivial work.",
  "",
];

const WORKER_LINES: ReadonlyArray<string> = [
  "You are a bounded specialist executing a delegated scope; do not orchestrate.",
  "Do not create or invoke other subagents (the task tool is unavailable/denied to you).",
  "Stay inside your delegated scope and preserve contracts and unrelated work.",
  "Return a compact structured result with STATUS, KEY_FINDINGS, EVIDENCE, VALIDATION, RISKS, RECOMMENDATION.",
  "",
];

const NEUTRAL_LINES: ReadonlyArray<string> = [
  "Follow the project's orchestration policy for this session.",
  "Specialists never create subagents; the primary agent runs orchestration preflight for non-trivial work.",
  "",
];

export function markerFor(kind: MandateKind, generation: Generation): string {
  if (kind === "worker") return "[orchestration-enforcement:" + generation + ":worker]";
  return "[orchestration-enforcement:" + generation + "]";
}

export function kindForRole(role: Role): MandateKind {
  if (role === "planner") return "planner";
  if (role === "worker") return "worker";
  return "neutral";
}

export function mandateFor(role: Role, generation: Generation): { text: string; kind: MandateKind; marker: string } {
  const kind = kindForRole(role);
  const marker = markerFor(kind, generation);
  const lines = kind === "worker" ? WORKER_LINES : kind === "planner" ? PLANNER_LINES : NEUTRAL_LINES;
  return { text: [...lines, marker].join("\n"), kind, marker };
}

// Tolerant marker scan over unknown system-entry shapes: V1 uses string[],
// V2 uses Array<{ type: "text", text }>. Any entry whose text includes the
// broad marker substring counts as already injected. NEVER throws.
export function hasMarker(entries: unknown): boolean {
  try {
    if (!Array.isArray(entries)) return false;
    for (const item of entries) {
      if (typeof item === "string") {
        if (item.includes(MARKER_SUBSTRING)) return true;
        continue;
      }
      if (item && typeof item === "object") {
        const t = (item as any).text;
        if (typeof t === "string" && t.includes(MARKER_SUBSTRING)) return true;
      }
    }
    return false;
  } catch {
    return false;
  }
}

// V1-style coalescing into a validated string array: append to system[0]
// or create the first entry. Caller must have validated shapes and
// idempotence already. Returns true when mutated.
export function coalesceString(system: Array<string>, text: string): boolean {
  try {
    if (system.length === 0) {
      system.push(text);
      return true;
    }
    if (typeof system[0] === "string") {
      system[0] = system[0].length > 0 ? system[0] + "\n\n" + text : text;
      return true;
    }
    return false;
  } catch {
    return false;
  }
}

// V2-style injection that NEVER mixes representations. Canonical V2
// systems are Array<{ type: "text", text }>, but a host may hand over
// string[] (V1-shaped) or an empty array. Rules, fail-open (never throw):
// - empty array => append one { type: "text", text } part (V2 canonical).
// - all strings => append the mandate as a string.
// - all { type: "text", text } parts => append one text part.
// - mixed or unknown shapes => do NOT introduce a minority format: follow
//   the MAJORITY representation (tie => first part wins); arrays with no
//   recognizable part at all are left untouched (return false).
// Returns true when mutated.
export function appendTextPart(system: unknown, text: string): boolean {
  try {
    if (!Array.isArray(system)) return false;
    if (typeof text !== "string") return false;
    const arr = system as Array<unknown>;
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
      if (
        item &&
        typeof item === "object" &&
        (item as any).type === "text" &&
        typeof (item as any).text === "string"
      ) {
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
    if (strings === 0 && parts === 0) return false;
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
