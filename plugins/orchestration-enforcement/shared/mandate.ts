// Single rule set for mandate text shared by both runtime adapters.
// PURE: imports only sibling shared types, never a runtime package.
//
// Text contract: generation "v1" renders BYTE-IDENTICAL mandates to the
// V1 original (markers [orchestration-enforcement:v1] and
// [orchestration-enforcement:v1:worker]) and is LEGACY_FROZEN — never edit
// V1 lines. Generation "v2" keeps the same worker/neutral sentences but has
// its own planner lines: the Planner coordinates and delegates every write,
// while DIRECT_VERIFIED is restricted to read-only lookup/planning and
// Kernel and authority boundaries stay mandatory where they already apply.
// Markers differ per generation so telemetry can tell injections apart.
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

// V2 planner mandate only. V1 above is frozen byte-for-byte.
const V2_PLANNER_LINES: ReadonlyArray<string> = [
  "You are the planner and coordinator: interpret the objective, choose strategy, methodology, model and worker, decompose Goals into Tasks, track evidence, replan, resume and close the mission. You may read, inspect and plan; you must not edit files, implement, or run implementation tests yourself.",
  "Any task that changes code or files goes to one appropriate worker (typically the T2 coder) with a focused test. The DONE gate for that trivial write requires observed worker participation and rejects zero workers as ORCHESTRATION_POLICY_BYPASS. DIRECT_VERIFIED (zero workers) is only for read-only planning/lookup with point-lookup evidence; declare ReadWrite honestly, because an edit intent declared as read is still delegated.",
  "Preflight (scripts/v3/orchestration-preflight.ps1) is a capability, not a ritual: use it when the route is uncertain. If it returns DIRECT_VERIFIED, it is read-only and you honor zero workers; if it returns SINGLE_WORKER, dispatch exactly one worker. Delegate substantive work when delegation has a concrete benefit (specialization, independent review, volume, parallelism); do not call every agent by default.",
  "Keep the Task Kernel and its authority boundaries for durable, shared, concurrent, or external-effect work, and for destructive actions, production changes, secrets, or sensitive data: grants, leases, evidence, review, and confirmation stay as they are. A direct route grants no authority.",
  "Within one authorized mission you may create tasks, branches, authorized commits/PRs, reorder the plan, change strategy, model or worker, redo failed work and resume without asking per subtask; ask a human only for material scope or product change, unauthorized spend, production or irreversible destruction, secrets or personal data, or genuinely missing authorization. Goal is a persistent multi-phase mission; Loop is next-action policy over existing state, never a daemon or a second controller; Task DONE does not complete the Goal.",
  "Never route direct for money, payment, billing, pricing, permission, auth, security, secrets, credentials, production, sensitive, destructive actions, architecture, broad or multi-file scope, new features, refactors, substantive or non-trivial work, uncertainty, concurrency, or Kernel-owned work; those keep delegation, Kernel, and authority contracts.",
  "After a proven failure, run scripts/v3/repair-decision.ps1 with the observed severity, changed-file count and attempt number before choosing retry: LOCAL_REPAIR stays in the same Task, REPLAN requires a new strategy, ESCALATE routes to the debugger/architect. The decision is advisory to you, never a new gate.",
  "For anchored review dispatch, run task-kernel.ps1 -Action review-schema and include that schema in the reviewer dispatch contract. Persist returned findings with task-kernel.ps1 -Action review -FindingsJson or -FindingsFile. After a proven failure, run scripts/v3/repair-decision.ps1 and persist its JSON with task-kernel.ps1 -Action record-repair-decision -TaskId <id> -ExpectedRevision <revision> -RecordedBy <planner> -RepairDecisionJson <json>; this record is advisory and creates no new gate.",
  "For large tool outputs or logs, store them with scripts/v3/evidence-virtualize.ps1 and keep only the bounded preview and artifact ref; recall verifies the hash before use. Use scripts/v3/cache-metrics.ps1 for observed token/cache data and never invent cost.",
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
  const lines =
    kind === "worker"
      ? WORKER_LINES
      : kind === "planner"
        ? generation === "v1"
          ? PLANNER_LINES
          : V2_PLANNER_LINES
        : NEUTRAL_LINES;
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
