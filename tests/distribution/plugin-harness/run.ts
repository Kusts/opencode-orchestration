import { OrchestrationEnforcement, __orchestrationEnforcementTest } from "../../../plugins/orchestration-enforcement.ts";

const PLANNER_MARKER = "[orchestration-enforcement:v1]";
const WORKER_MARKER = "[orchestration-enforcement:v1:worker]";
const MARKER_SUB = "orchestration-enforcement:v1";

let pass = 0;
let fail = 0;

function ok(cond: boolean, name: string, extra?: string): void {
  if (cond) {
    pass++;
    console.log(`ok - ${name}`);
  } else {
    fail++;
    console.log(`NOT OK - ${name}${extra ? " :: " + extra : ""}`);
  }
}

function count(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}

const hooks = await (OrchestrationEnforcement as any)({});
const transform = (hooks as any)["experimental.chat.system.transform"];

ok(typeof transform === "function", "harness exposes transform hook");

const plannerInput = { sessionID: "t-planner", agent: "build", model: {} };
const plannerOut: any = { system: ["planner base instructions"] };
await transform(plannerInput, plannerOut);

// 1. planner coalesced into system[0], single entry
ok(
  Array.isArray(plannerOut.system) &&
    plannerOut.system.length === 1 &&
    plannerOut.system[0].startsWith("planner base instructions") &&
    plannerOut.system[0].includes(PLANNER_MARKER),
  "1 planner coalesced into system[0] (1 entry)",
  JSON.stringify(plannerOut.system?.length),
);

const coderInput = { sessionID: "t-coder", agent: "coder", model: {} };
const coderOut: any = { system: ["coder base"] };
await transform(coderInput, coderOut);

// 2. coder: no delegation obligation, has no-subdelegation
ok(
  typeof coderOut.system[0] === "string" &&
    coderOut.system[0].includes("Do not create or invoke other subagents") &&
    !coderOut.system[0].includes("require material participation") &&
    !coderOut.system[0].includes("TRIVIAL_DIRECT") &&
    !coderOut.system[0].includes("DONE requires") &&
    !coderOut.system[0].includes("ORCHESTRATION_POLICY_BYPASS"),
  "2 coder worker mandate, no delegation obligation",
);

const reviewerInput = { sessionID: "t-reviewer", session: { agent: "reviewer" }, model: {} };
const reviewerOut: any = { system: ["reviewer base"] };
await transform(reviewerInput, reviewerOut);

// 3. generic worker via nested session metadata: worker mandate, no preflight/DONE notions
ok(
  typeof reviewerOut.system[0] === "string" &&
    reviewerOut.system[0].includes(WORKER_MARKER) &&
    !reviewerOut.system[0].toLowerCase().includes("preflight") &&
    !reviewerOut.system[0].includes("DONE"),
  "3 generic worker mandate, no preflight/DONE",
);

const unknownInput = { sessionID: "t-unknown", model: {} };
const unknownOut: any = { system: ["unknown base"] };
await transform(unknownInput, unknownOut);

// 4. unknown: conservative neutral mandate (base marker, no worker suffix, no hard obligations)
ok(
  typeof unknownOut.system[0] === "string" &&
    unknownOut.system[0].includes(PLANNER_MARKER) &&
    !unknownOut.system[0].includes(":worker") &&
    !unknownOut.system[0].includes("DONE requires") &&
    !unknownOut.system[0].includes("require material participation"),
  "4 unknown neutral conservative mandate",
);

// 5. marker appears EXACTLY once in each injected output
for (const [label, out] of [
  ["planner", plannerOut],
  ["coder", coderOut],
  ["reviewer", reviewerOut],
  ["unknown", unknownOut],
] as Array<[string, any]>) {
  ok(count(String(out.system[0]), MARKER_SUB) === 1, `5 marker exactly 1x (${label})`, `count=${count(String(out.system[0]), MARKER_SUB)}`);
}

// 6. repeated transform is idempotent (same output object twice)
const idemOut: any = { system: ["idem base"] };
await transform({ sessionID: "t-idem", agent: "build", model: {} }, idemOut);
const once = JSON.stringify(idemOut);
await transform({ sessionID: "t-idem", agent: "build", model: {} }, idemOut);
ok(JSON.stringify(idemOut) === once && count(String(idemOut.system[0]), MARKER_SUB) === 1, "6 idempotent on repeat");

// 7. empty system array creates the first entry
const emptyOut: any = { system: [] };
await transform({ sessionID: "t-empty", agent: "build", model: {} }, emptyOut);
ok(emptyOut.system.length === 1 && count(String(emptyOut.system[0]), MARKER_SUB) === 1, "7 empty system creates first entry");

// 8. malformed hook data: no throw, no injection
let threw = false;
const malformed: Array<[string, any, any]> = [
  ["null-output", { sessionID: "t-m", model: {} }, null],
  ["string-output", { sessionID: "t-m", model: {} }, "nope"],
  ["null-input", null, { system: ["base"] }],
  ["string-input", "nope", { system: ["base"] }],
  ["system-null", { sessionID: "t-m", model: {} }, { system: null }],
  ["system-string", { sessionID: "t-m", model: {} }, { system: "x" }],
  ["system-first-nonstr", { sessionID: "t-m", model: {} }, { system: [123] }],
];
for (const [label, inp, out] of malformed) {
  const before = JSON.stringify(out);
  try {
    await transform(inp, out);
  } catch {
    threw = true;
    console.log(`NOT OK - 8 malformed threw (${label})`);
    fail++;
    continue;
  }
  const hasMarker =
    typeof out === "object" &&
    out !== null &&
    Array.isArray((out as any).system) &&
    (out as any).system.some((s: unknown) => typeof s === "string" && (s as string).includes(MARKER_SUB));
  if (hasMarker || JSON.stringify(out) !== before) {
    fail++;
    console.log(`NOT OK - 8 malformed injected/mutated (${label})`);
  } else {
    pass++;
    console.log(`ok - 8 malformed safe (${label})`);
  }
}
ok(!threw, "8 malformed never throws");

// 9. array input => fail-safe, no throw, no injection
{
  let threw9 = false;
  const arrOut: any = { system: ["base"] };
  const before9 = JSON.stringify(arrOut);
  try {
    await transform([] as any, arrOut);
  } catch {
    threw9 = true;
  }
  const has9 =
    Array.isArray(arrOut.system) &&
    arrOut.system.some((s: unknown) => typeof s === "string" && (s as string).includes(MARKER_SUB));
  ok(!threw9 && !has9 && JSON.stringify(arrOut) === before9, "9 array input fail-safe, no injection");
}

// 10. non-string anywhere in system => no injection, no mutation
{
  const cases: Array<[string, any]> = [
    ["trailing-nonstr", { system: ["base", 123] }],
    ["leading-nonstr", { system: [123, "base"] }],
  ];
  for (const [label, out] of cases) {
    const before = JSON.stringify(out);
    let threw10 = false;
    try {
      await transform({ sessionID: `t-mixed-${label}`, agent: "build", model: {} }, out);
    } catch {
      threw10 = true;
    }
    const has =
      Array.isArray(out.system) &&
      out.system.some((s: unknown) => typeof s === "string" && (s as string).includes(MARKER_SUB));
    ok(!threw10 && !has && JSON.stringify(out) === before, `10 mixed system fail-safe (${label})`);
  }
}

// 11. evil agent (200 chars + unsafe charset) => no throw, telemetry omits agent
{
  const { readFileSync, existsSync } = await import("node:fs");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");
  const evil = "x".repeat(200) + "<script>alert(1)</script>;`rm -rf /`";
  const sid = `t-evil-${Date.now()}`;
  const evilOut: any = { system: ["base"] };
  let threw11 = false;
  try {
    await transform({ sessionID: sid, agent: evil, model: {} }, evilOut);
  } catch {
    threw11 = true;
  }
  ok(!threw11, "11 evil agent never throws");
  const logPath = join(homedir(), ".opencode-orchestration", "evidence", "v3", "orchestration", "session-injections.jsonl");
  let omitOk = false;
  try {
    if (existsSync(logPath)) {
      const lines = readFileSync(logPath, "utf8").trim().split("\n");
      const hit = lines.map((l: string) => { try { return JSON.parse(l); } catch { return null; } }).find((o: any) => o && o.session === sid);
      // evil agent must be omitted; session id itself is safe so the row is findable
      omitOk = !!hit && !("agent" in hit);
      if (hit) {
        const keys = Object.keys(hit).sort();
        omitOk = omitOk && keys.every((k) => ["ts", "sessionType", "agent", "mandate", "markerUsed", "session", "identity_source"].includes(k));
      }
    }
  } catch { omitOk = false; }
  ok(omitOk, "11 telemetry omits unsafe agent, schema unchanged");
}

// 12. sessionIndex bounded: CAP+N inserts via event hook => size stays at CAP,
// oldest evicted (falls back to neutral), newest still resolves via session-map.
{
  const cap = __orchestrationEnforcementTest.cap;
  const eventHook = (hooks as any).event;
  ok(typeof eventHook === "function", "12 event hook exposed");
  const N = cap + 10;
  for (let i = 0; i < N; i++) {
    await eventHook({ event: { type: "session.created", properties: { info: { id: `t-cap-${i}`, agent: "coder" } } } }, {});
  }
  ok(__orchestrationEnforcementTest.sessionIndexSize() === cap, `12 sessionIndex capped at ${cap}`, `size=${__orchestrationEnforcementTest.sessionIndexSize()}`);
  const evictedOut: any = { system: ["base"] };
  await transform({ sessionID: "t-cap-0", model: {} }, evictedOut);
  ok(
    typeof evictedOut.system[0] === "string" &&
      evictedOut.system[0].includes(PLANNER_MARKER) &&
      !evictedOut.system[0].includes(":worker"),
    "12 oldest entry evicted (neutral fallback, no worker mandate)",
  );
  const recentOut: any = { system: ["base"] };
  await transform({ sessionID: `t-cap-${N - 1}`, model: {} }, recentOut);
  ok(
    typeof recentOut.system[0] === "string" && recentOut.system[0].includes(WORKER_MARKER),
    "12 newest entry still resolves via session-map (worker mandate)",
  );
}

// 13. logged bounded: distinct transforms still inject (boundedAdd path safe),
// size never exceeds cap.
{
  for (let i = 0; i < 5; i++) {
    const out: any = { system: ["base"] };
    await transform({ sessionID: `t-logged-${Date.now()}-${i}`, agent: "build", model: {} }, out);
    if (typeof out.system[0] !== "string" || !out.system[0].includes(PLANNER_MARKER)) {
      ok(false, `13 logged smoke injects (${i})`);
      break;
    }
    if (i === 4) ok(true, "13 logged smoke injects (boundedAdd path safe)");
  }
  ok(__orchestrationEnforcementTest.loggedSize() <= __orchestrationEnforcementTest.cap, "13 logged size within cap", `size=${__orchestrationEnforcementTest.loggedSize()}`);
}

console.log(`SUMMARY pass=${pass} fail=${fail}`);
process.exit(fail > 0 ? 1 : 0);
