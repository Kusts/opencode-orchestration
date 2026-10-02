// mcp-transport-run.ts - Phase 28 slice 2 harness (local, no network).
// Proves the MCP transport envelope in shared/mcp-transport.ts:
// conservative allowlist classification, embedded defaults mirroring
// the canonical policy, shadow default (never cancels), enforced
// timeout with safe abandon (no unhandled rejection), circuit
// (2 failures => OPEN, conclusion-based cooldown, single half-open
// probe, rearm), required vs optional on every branch, unknown tools
// bypassing, illegible policy => embedded defaults, sanitized
// telemetry, authority guard, and V1 parity without crash.
// Run with: bun run tests/distribution/plugin-harness/mcp-transport-run.ts
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Isolate telemetry: the jsonl sink lives under $HOME.
const tmpHome = mkdtempSync(join(tmpdir(), "oo-mcptrans-"));
process.env.HOME = tmpHome;
process.env.USERPROFILE = tmpHome;

const MCP = await import("../../../plugins/orchestration-enforcement/shared/mcp-transport.ts");
const IDX = await import("../../../plugins/orchestration-enforcement.ts");
const V2T = await import("../../../plugins/orchestration-enforcement/v2.ts");

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

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function readJsonl(): Array<any> {
  const p = join(tmpHome, ".opencode-orchestration", "evidence", "v3", "orchestration", "session-injections.jsonl");
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8")
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l: string) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter((o) => o !== null);
}

function mcpRows(): Array<any> {
  return readJsonl().filter((r) => r && r.kind === "mcp-transport");
}

function hasRow(server: string, event: string): boolean {
  return mcpRows().some((r) => r.server === server && r.event === event);
}

const T0 = 1900000000000;
let keyN = 0;
function freshKey(prefix: string): { server: string; turn: string } {
  keyN++;
  return { server: `tsrv${keyN}${prefix}`, turn: `tturn${keyN}` };
}
// Tool names must stay within the allowlist shape while unique per
// test: mcp__<server>__<tool>.
function toolFor(server: string): string {
  return `mcp__${server}__call`;
}

// ---------- R1: conservative classification ----------
{
  const j1 = MCP.classifyMcpTool("jev");
  ok(!!j1 && j1.server === "jev" && j1.mcpClass === "advisory", "1 jev classifies advisory/jev");
  const j2 = MCP.classifyMcpTool("JEV_decide");
  ok(!!j2 && j2.server === "jev" && j2.mcpClass === "advisory", "1b jev prefix (any case) is advisory");
  const m1 = MCP.classifyMcpTool("ai-memory_query");
  ok(!!m1 && m1.server === "ai-memory" && m1.mcpClass === "memory", "1c ai-memory classifies memory");
  const m2 = MCP.classifyMcpTool("memory_recall");
  ok(!!m2 && m2.server === "memory" && m2.mcpClass === "memory", "1d memory classifies memory");
  const g1 = MCP.classifyMcpTool("mcp__myserver__do_thing");
  ok(!!g1 && g1.server === "myserver" && g1.mcpClass === "remote", "1e generic mcp__server__tool is remote with server");
  const g2 = MCP.classifyMcpTool("MCP__UPPER__X");
  ok(!!g2 && g2.server === "upper" && g2.mcpClass === "remote", "1f generic shape lowercases server");
  for (const u of ["read", "bash", "foobar", "", "   ", "../evil", "notmcp_tool", "ferramenta_x"]) {
    ok(MCP.classifyMcpTool(u) === null, `1g unknown not MCP (${JSON.stringify(String(u)).slice(0, 24)})`);
  }
  ok(MCP.classifyMcpTool(null) === null, "1h null not MCP");
  ok(MCP.classifyMcpTool(123) === null, "1i non-string not MCP");
  ok(MCP.classifyMcpTool("x".repeat(300)) === null, "1j oversized not MCP");
  const evil = MCP.classifyMcpTool("mcp__<script>alert(1)</script>__x");
  ok(!!evil && evil.mcpClass === "remote" && evil.server === "mcp", "1k unsafe server segment falls back to mcp (still remote)");
}

// ---------- R1/R2: policy defaults mirror the canonical file ----------
const CANON = JSON.stringify({
  version: 1,
  classes: {
    advisory: { execution_timeout_seconds: 30, connect_timeout_seconds: 10 },
    memory: { execution_timeout_seconds: 60, connect_timeout_seconds: 15 },
    remote: { execution_timeout_seconds: 120, connect_timeout_seconds: 20 },
    long_running: { execution_timeout_seconds: 0, connect_timeout_seconds: 20, requires_explicit_task_contract: true },
  },
  class_aliases: { jev: "advisory" },
  failure_threshold: 2,
  circuit: { cooldown_seconds: 300 },
  criticality: { allowed: ["optional", "required"], default: "optional" },
});
// The canonical policy file itself: the embedded mirror above must
// match reality (R-M3). Resolved relative to this file so the
// harness works from any working directory.
const REGISTRY_URL = new URL("../../../source/registry/mcp-request-policy.json", import.meta.url);
let registryText = "";
try {
  registryText = readFileSync(REGISTRY_URL, "utf8");
} catch {
  registryText = "";
}
{
  const d = MCP.resolveMcpPolicy(null);
  ok(d.budgetsS.advisory === 30 && d.budgetsS.memory === 60 && d.budgetsS.remote === 120, "2 embedded budgets 30/60/120");
  ok(d.failureThreshold === 2 && d.cooldownS === 300, "2b embedded threshold 2 + cooldown 300");
  const g = MCP.resolveMcpPolicy("garbage{{{");
  ok(g.source === "embedded-defaults" && g.budgetsS.remote === 120, "2c garbage policy text => embedded defaults");
  const big = MCP.resolveMcpPolicy("x".repeat(70000));
  ok(big.source === "embedded-defaults", "2d oversized policy text => embedded defaults");
  const dev = MCP.resolveMcpPolicy(CANON.replace('"advisory":{"execution_timeout_seconds":30', '"advisory":{"execution_timeout_seconds":31'));
  void dev;
  const devObj = JSON.parse(CANON) as any;
  devObj.classes.advisory.execution_timeout_seconds = 31;
  const dev2 = MCP.resolveMcpPolicy(JSON.stringify(devObj));
  ok(dev2.source === "embedded-defaults", "2e deviating budget => embedded defaults (never partial)");
  const good = MCP.resolveMcpPolicy(CANON);
  ok(good.source === "policy-text" && good.budgetsS.memory === 60 && good.cooldownS === 300, "2f canonical text accepted with same budgets");
  ok(MCP.normalizeMcpClass("jev") === "advisory", "2g jev alias normalizes to advisory");
  ok(MCP.normalizeMcpClass("nope") === null, "2h unknown class => null");
  ok(MCP.normalizeMcpCriticality("required") === "required", "2i required stays required");
  ok(MCP.normalizeMcpCriticality("whatever") === "optional", "2j criticality defaults optional");
  ok(MCP.normalizeMcpCriticality(null) === "optional", "2k null criticality => optional");
}

// ---------- R-F3/R-M3: the mirror matches the real registry file ----------
{
  ok(registryText.length > 0, "2x registry policy file readable");
  let reg: any = null;
  try {
    reg = JSON.parse(registryText);
  } catch {
    reg = null;
  }
  ok(!!reg, "2x registry policy file parses");
  if (reg) {
    const c = reg.classes;
    ok(c.advisory.execution_timeout_seconds === 30 && c.advisory.connect_timeout_seconds === 10, "2x registry advisory 30/10 matches mirror");
    ok(c.memory.execution_timeout_seconds === 60 && c.memory.connect_timeout_seconds === 15, "2x registry memory 60/15 matches mirror");
    ok(c.remote.execution_timeout_seconds === 120 && c.remote.connect_timeout_seconds === 20, "2x registry remote 120/20 matches mirror");
    ok(c.long_running.execution_timeout_seconds === 0 && c.long_running.requires_explicit_task_contract === true && c.long_running.connect_timeout_seconds === 20, "2x registry long_running matches mirror");
    ok(reg.class_aliases && reg.class_aliases.jev === "advisory", "2x registry jev alias matches mirror");
    ok(reg.failure_threshold === 2 && reg.circuit && reg.circuit.cooldown_seconds === 300, "2x registry threshold 2 + cooldown 300 match mirror");
    ok(reg.criticality && reg.criticality.default === "optional", "2x registry criticality default matches mirror");
  }
  ok(MCP.resolveMcpPolicy(registryText).source === "policy-text", "2x registry file text accepted by the strict parser");
  const devConn = JSON.parse(CANON) as any;
  devConn.classes.advisory.connect_timeout_seconds = 11;
  ok(MCP.resolveMcpPolicy(JSON.stringify(devConn)).source === "embedded-defaults", "2x deviating connect budget => embedded defaults");
  const devCd = JSON.parse(CANON) as any;
  devCd.circuit.cooldown_seconds = 301;
  ok(MCP.resolveMcpPolicy(JSON.stringify(devCd)).source === "embedded-defaults", "2x deviating cooldown => embedded defaults");
}

// ---------- R2/R-F6: long-running without contract ----------
{
  // SHADOW observes and proceeds: no deadline envelope, the call is
  // never refused (would-refuse telemetry only).
  MCP.resetMcpTransport();
  let ran = 0;
  const opt = await MCP.runMcpGuarded({
    tool: "mcp__batch__run",
    classOverride: "long_running",
    criticality: "optional",
    execute: async () => { ran++; await sleep(60); return "shadow-lr"; },
  });
  ok(ran === 1, "3 shadow long-running without contract still executes");
  ok(opt.status === "OK" && opt.value === "shadow-lr", "3b shadow long-running returns the value");
  ok(hasRow("batch", "would-refuse-long-running"), "3c shadow records would-refuse-long-running");
  // ENFORCED refuses structurally without executing.
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  let ranE = 0;
  const optE = await MCP.runMcpGuarded({
    tool: "mcp__batch__run",
    classOverride: "long_running",
    criticality: "optional",
    mode: "enforced",
    execute: async () => { ranE++; return "x"; },
  });
  ok(ranE === 0, "3d enforced long-running without contract never executes");
  ok(optE.status === "MCP_UNAVAILABLE" && optE.cause === "MCP_LONG_RUNNING_REQUIRES_CONTRACT", "3e enforced optional refusal cause");
  ok(optE.ok === true && optE.blocked === false && optE.fallback_continue === true, "3f enforced optional refusal falls back, not blocked");
  let ran2 = 0;
  const req = await MCP.runMcpGuarded({
    tool: "mcp__batch__run",
    classOverride: "long_running",
    criticality: "required",
    mode: "enforced",
    execute: async () => { ran2++; return "x"; },
  });
  ok(ran2 === 0 && req.status === "MCP_REQUIRED_BLOCKED" && req.blocked === true, "3g enforced required refusal blocks without executing");
  ok(req.ok === false && req.cause === "MCP_LONG_RUNNING_REQUIRES_CONTRACT", "3h enforced required refusal cause preserved");
  let ran3 = 0;
  const bad = await MCP.runMcpGuarded({
    tool: "mcp__batch__run",
    classOverride: "long_running",
    contract: { id: "c1", budgetSeconds: 0 },
    mode: "enforced",
    execute: async () => { ran3++; return "x"; },
  });
  ok(ran3 === 0 && bad.cause === "MCP_LONG_RUNNING_REQUIRES_CONTRACT", "3i zero-budget contract refused in enforced mode");
  let ran4 = 0;
  const withContract = await MCP.runMcpGuarded({
    tool: "mcp__batch__run",
    classOverride: "long_running",
    contract: { id: "task-7", budgetSeconds: 3600 },
    execute: async () => { ran4++; return "contract-ok"; },
  });
  ok(ran4 === 1 && withContract.status === "OK" && withContract.value === "contract-ok", "3j explicit contract executes");
  MCP.resetMcpTransport();
}

// ---------- R7: shadow is the default; never cancels ----------
{
  MCP.resetMcpTransport();
  ok(MCP.getMcpTransportConfig().enforced === false, "4 default config is shadow (enforced=false)");
  const eff = MCP.effectiveMcpMode(undefined);
  ok(eff.mode === "shadow" && eff.denied === false, "4b unset mode resolves shadow");
  const denied = MCP.effectiveMcpMode("enforced");
  ok(denied.mode === "shadow" && denied.denied === true, "4c enforced request without opt-in denied to shadow");
  const k = freshKey("sh");
  let done = false;
  const r = await MCP.runMcpGuarded({
    tool: toolFor(k.server),
    turn: k.turn,
    tightenBudgetMs: 40,
    execute: async () => { await sleep(120); done = true; return "slow-value"; },
  });
  ok(done === true, "4d shadow never cancels the execution");
  ok(r.status === "OK" && r.value === "slow-value" && r.mode === "shadow", "4e shadow returns the underlying value");
  ok(r.elapsedMs >= 100, `4f shadow waits full duration (elapsed=${r.elapsedMs})`);
  ok(hasRow(k.server, "would-timeout"), "4g shadow overrun records would-timeout");
}

// ---------- R3/R7: enforced timeout abandons safely ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  ok(MCP.effectiveMcpMode(undefined).mode === "enforced", "5 global opt-in enables enforced");
  const k = freshKey("enf");
  let late = false;
  const t0 = Date.now();
  const r = await MCP.runMcpGuarded({
    tool: toolFor(k.server),
    turn: k.turn,
    criticality: "optional",
    tightenBudgetMs: 50,
    execute: async () => { await sleep(300); late = true; return "too-late"; },
  });
  const dt = Date.now() - t0;
  ok(r.cause === "MCP_TIMEOUT", "5b enforced overrun yields MCP_TIMEOUT cause");
  ok(r.status === "MCP_UNAVAILABLE" && r.ok === true && r.blocked === false && r.fallback_continue === true, "5c optional timeout falls back, not blocked");
  ok(dt < 200, `5d result returns near budget, abandons slow call (dt=${dt}ms)`);
  await sleep(350);
  ok(late === true, "5e abandoned work may still settle (no kill)");
  ok(hasRow(k.server, "timeout"), "5f enforced overrun records timeout telemetry");
  const k2 = freshKey("enf2");
  const req = await MCP.runMcpGuarded({
    tool: toolFor(k2.server),
    turn: k2.turn,
    criticality: "required",
    tightenBudgetMs: 50,
    execute: async () => { await sleep(300); return "x"; },
  });
  ok(req.status === "MCP_REQUIRED_BLOCKED" && req.ok === false && req.blocked === true && req.cause === "MCP_TIMEOUT", "5g required timeout blocks with cause");
  MCP.resetMcpTransport();
}

// ---------- no unhandled rejection on abandon ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  let unhandled = 0;
  const onU = (): void => { unhandled++; };
  process.on("unhandledRejection", onU);
  const k = freshKey("unh");
  const r = await MCP.runMcpGuarded({
    tool: toolFor(k.server),
    turn: k.turn,
    tightenBudgetMs: 40,
    execute: async () => { await sleep(80); throw new Error("late-failure"); },
  });
  ok(r.cause === "MCP_TIMEOUT", "6 late rejection still surfaces as MCP_TIMEOUT");
  await sleep(250);
  try {
    process.off("unhandledRejection", onU);
  } catch { /* fail-open */ }
  ok(unhandled === 0, `6b no unhandled rejection on abandon (count=${unhandled})`);
  MCP.resetMcpTransport();
}

// ---------- R4: circuit (2 failures => OPEN, conclusion cooldown, half-open, rearm) ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const k = freshKey("ckt");
  const tool = toolFor(k.server);
  const boom = (): Promise<unknown> => Promise.reject(new Error("net-down"));
  const f1 = await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: T0, execute: boom });
  ok(f1.cause === "MCP_ERROR" && f1.status === "MCP_UNAVAILABLE", "7 first failure recorded (MCP_ERROR, optional fallback)");
  const f2 = await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: T0 + 50000, execute: boom });
  ok(f2.cause === "MCP_ERROR", "7b second failure recorded");
  const snap = MCP.getMcpCircuitSnapshot(k.server, "remote", k.turn, T0 + 50000);
  ok(snap.state === "OPEN" && snap.consecutive === 2, `7c two failures => OPEN (state=${snap.state})`);
  let ran = 0;
  const f3 = await MCP.runMcpGuarded({
    tool, turn: k.turn, nowMs: T0 + 100000,
    execute: async () => { ran++; return "x"; },
  });
  ok(ran === 0 && f3.cause === "MCP_CIRCUIT_OPEN", "7d OPEN fast-fails without executing (no hammering)");
  ok(f3.status === "MCP_UNAVAILABLE", "7e open circuit optional => fallback");
  // Cooldown is measured from the CONCLUSION (T0+50000): T0+300000 is
  // 300s after the FIRST failure but only 250s after the conclusion.
  let ran2 = 0;
  const f4 = await MCP.runMcpGuarded({
    tool, turn: k.turn, nowMs: T0 + 300000,
    execute: async () => { ran2++; return "x"; },
  });
  ok(ran2 === 0 && f4.cause === "MCP_CIRCUIT_OPEN", "7f cooldown counted from conclusion (still OPEN at +300s after first)");
  // Half-open probe at +351s (past 300s cooldown from conclusion).
  let ran3 = 0;
  const f5 = await MCP.runMcpGuarded({
    tool, turn: k.turn, nowMs: T0 + 351000,
    execute: async () => { ran3++; return "probe-ok"; },
  });
  ok(ran3 === 1 && f5.status === "OK", "7g expired cooldown allows one half-open probe");
  const snap2 = MCP.getMcpCircuitSnapshot(k.server, "remote", k.turn, T0 + 351000);
  ok(snap2.state === "CLOSED" && snap2.consecutive === 0, "7h successful probe rearms CLOSED");
  ok(hasRow(k.server, "circuit-open") && hasRow(k.server, "rearm"), "7i circuit-open + rearm telemetry recorded");
  MCP.resetMcpTransport();
}

// ---------- R4b: single half-open probe; failing probe renews cooldown ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const k = freshKey("hp");
  const tool = toolFor(k.server);
  const old = Date.now() - 400000;
  await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: old, execute: () => Promise.reject(new Error("n1")) });
  await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: old, execute: () => Promise.reject(new Error("n2")) });
  let probes = 0;
  const p1 = MCP.runMcpGuarded({
    tool, turn: k.turn,
    execute: async () => { probes++; await sleep(120); return "p1-ok"; },
  });
  await sleep(15);
  let secondRan = 0;
  const p2 = await MCP.runMcpGuarded({
    tool, turn: k.turn,
    execute: async () => { secondRan++; return "p2"; },
  });
  ok(probes === 1 && secondRan === 0 && p2.cause === "MCP_CIRCUIT_OPEN", "8 concurrent contender fast-fails during probe (single probe)");
  const r1 = await p1;
  ok(r1.status === "OK", "8b probe success rearms");
  let thirdRan = 0;
  const p3 = await MCP.runMcpGuarded({
    tool, turn: k.turn,
    execute: async () => { thirdRan++; return "p3"; },
  });
  ok(thirdRan === 1 && p3.status === "OK", "8c post-rearm calls execute normally");
  // Failing probe renews the cooldown from its own conclusion.
  const k2 = freshKey("hp2");
  const tool2 = toolFor(k2.server);
  await MCP.runMcpGuarded({ tool: tool2, turn: k2.turn, nowMs: T0, execute: () => Promise.reject(new Error("a")) });
  await MCP.runMcpGuarded({ tool: tool2, turn: k2.turn, nowMs: T0, execute: () => Promise.reject(new Error("b")) });
  const fp = await MCP.runMcpGuarded({ tool: tool2, turn: k2.turn, nowMs: T0 + 301000, execute: () => Promise.reject(new Error("probe-fail")) });
  ok(fp.cause === "MCP_ERROR" || fp.cause === "MCP_TIMEOUT", "8d failing probe surfaces failure");
  let renewed = 0;
  const fp2 = await MCP.runMcpGuarded({
    tool: tool2, turn: k2.turn, nowMs: T0 + 301000 + 299000,
    execute: async () => { renewed++; return "x"; },
  });
  ok(renewed === 0 && fp2.cause === "MCP_CIRCUIT_OPEN", "8e failing probe renews cooldown (OPEN again)");
  MCP.resetMcpTransport();
}

// ---------- R4c: success resets the streak; shadow never blocks ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const k = freshKey("streak");
  const tool = toolFor(k.server);
  await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: T0, execute: () => Promise.reject(new Error("x")) });
  await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: T0, execute: async () => "fine" });
  const s = MCP.getMcpCircuitSnapshot(k.server, "remote", k.turn, T0);
  ok(s.state === "CLOSED" && s.consecutive === 0, "9 success resets consecutive counter");
  MCP.resetMcpTransport();
  const k2 = freshKey("shopen");
  const tool2 = toolFor(k2.server);
  await MCP.runMcpGuarded({ tool: tool2, turn: k2.turn, nowMs: T0, execute: () => Promise.reject(new Error("s1")) });
  await MCP.runMcpGuarded({ tool: tool2, turn: k2.turn, nowMs: T0, execute: () => Promise.reject(new Error("s2")) });
  let shadowRan = 0;
  const sh = await MCP.runMcpGuarded({
    tool: tool2, turn: k2.turn, nowMs: T0 + 1000,
    execute: async () => { shadowRan++; return "shadow-through"; },
  });
  ok(shadowRan === 1 && sh.status === "OK", "9b shadow executes even with circuit OPEN (never cancels)");
  ok(hasRow(k2.server, "would-block-circuit-open"), "9c shadow records would-block instead of blocking");
  MCP.resetMcpTransport();
}

// ---------- R5: required vs optional on every branch + execution error ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const fast_boom = (): Promise<unknown> => Promise.reject(new Error("exec-fail"));
  const ko = freshKey("err");
  const eo = await MCP.runMcpGuarded({ tool: toolFor(ko.server), turn: ko.turn, criticality: "optional", execute: fast_boom });
  ok(eo.status === "MCP_UNAVAILABLE" && eo.ok && !eo.blocked && eo.fallback_continue && eo.cause === "MCP_ERROR", "10 optional execution error => fallback");
  const kr = freshKey("err2");
  const er = await MCP.runMcpGuarded({ tool: toolFor(kr.server), turn: kr.turn, criticality: "required", execute: fast_boom });
  ok(er.status === "MCP_REQUIRED_BLOCKED" && !er.ok && er.blocked && !er.fallback_continue && er.cause === "MCP_ERROR", "10b required execution error => blocked");
  // Authority guard denies every shape, including null and hostile input.
  const shapes: Array<unknown> = [eo, er, null, undefined, { granted: true, widened: true }, "x", 42];
  let allDenied = true;
  for (const s of shapes) {
    const g = MCP.mcpResultGrantsAuthority(s);
    if (g.granted !== false || g.widened !== false || g.status !== "MCP_RESULT_CANNOT_GRANT") allDenied = false;
  }
  ok(allDenied, "10c authority guard denies all result shapes + null + hostile input");
  MCP.resetMcpTransport();
}

// ---------- R1: unknown tools bypass untouched ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const r = await MCP.runMcpGuarded({ tool: "read", execute: async () => "file-bytes" });
  ok(r.engaged === false && r.status === "MCP_BYPASS_NOT_MCP" && r.value === "file-bytes", "11 unknown tool bypasses with value");
  let threw: unknown = null;
  try {
    await MCP.runMcpGuarded({ tool: "bash", execute: async () => { throw new Error("orig-boom"); } });
  } catch (e) {
    threw = e;
  }
  ok(!!threw && (threw as Error).message === "orig-boom", "11b bypass rejection propagates transparently (not shaped)");
  MCP.resetMcpTransport();
}

// ---------- R8: abort-safe + internal fail-closed ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const k = freshKey("ab");
  const ctl = new AbortController();
  ctl.abort();
  let ran = 0;
  const r = await MCP.runMcpGuarded({
    tool: toolFor(k.server), turn: k.turn, signal: ctl.signal,
    execute: async () => { ran++; return "x"; },
  });
  ok(ran === 0 && r.cause === "MCP_ABORTED", "12 pre-aborted signal refuses without executing");
  const s = MCP.getMcpCircuitSnapshot(k.server, "remote", k.turn);
  ok(s.state === "CLOSED" && s.consecutive === 0, "12b abort leaves the circuit untouched");
  // Shadow observes and proceeds: the host owns the abort, the
  // envelope never alters admission.
  const kSh = freshKey("absh");
  const ctlSh = new AbortController();
  ctlSh.abort();
  let ranSh = 0;
  const rSh = await MCP.runMcpGuarded({
    tool: toolFor(kSh.server), turn: kSh.turn, mode: "shadow", signal: ctlSh.signal,
    execute: async () => { ranSh++; return "shadow-through-abort"; },
  });
  ok(ranSh === 1 && rSh.status === "OK", "12d shadow pre-aborted proceeds (observe-only)");
  ok(hasRow(kSh.server, "would-refuse-aborted"), "12e shadow records would-refuse-aborted");
  let threw2 = false;
  let out: any = null;
  try {
    out = await MCP.runMcpGuarded(null as any);
  } catch {
    threw2 = true;
  }
  ok(!threw2 && out && out.status === "MCP_REQUIRED_BLOCKED" && out.cause === "MCP_INTERNAL", "12c envelope never throws (internal => structured block)");
  MCP.resetMcpTransport();
}

// ---------- R1: policy file path (bounded read; illegible => defaults) ----------
{
  MCP.resetMcpTransport();
  MCP.setMcpPolicyFileReader(() => "not-json{{{");
  MCP.configureMcpTransport({ policyPath: "/abs/policy.json" });
  const k = freshKey("pf");
  const r = await MCP.runMcpGuarded({ tool: toolFor(k.server), turn: k.turn, execute: async () => "v" });
  ok(r.status === "OK", "13 illegible policy file still serves calls on embedded defaults");
  ok(hasRow(k.server, "policy-fallback"), "13b illegible file records policy-fallback");
  MCP.resetMcpTransport();
  MCP.setMcpPolicyFileReader(() => CANON);
  MCP.configureMcpTransport({ policyPath: "/abs/policy.json" });
  const k2 = freshKey("pf2");
  await MCP.runMcpGuarded({ tool: toolFor(k2.server), turn: k2.turn, execute: async () => "v" });
  ok(!hasRow(k2.server, "policy-fallback"), "13c valid file accepted (no fallback row)");
  // V2 bounded reader unit checks (no host needed).
  const readP = (V2T as any).__orchestrationEnforcementV2Test.readPolicyFileBounded;
  ok(typeof readP === "function", "13d v2 exposes bounded policy reader seam");
  if (typeof readP === "function") {
    ok(readP("/definitely/missing-oo-policy.json") === null, "13e missing file => null");
    ok(readP("relative/path.json") === null, "13f relative path refused");
    ok(readP("") === null && readP(null) === null, "13g empty/null refused");
    const bigPath = join(tmpHome, "big-policy.json");
    writeFileSync(bigPath, "x".repeat(70000));
    ok(readP(bigPath) === null, "13h oversized file refused");
    const dirPath = tmpHome;
    ok(readP(dirPath) === null, "13i directory refused");
    const goodPath = join(tmpHome, "good-policy.json");
    writeFileSync(goodPath, CANON);
    ok(readP(goodPath) === CANON, "13j small valid file reads");
  }
  MCP.resetMcpTransport();
}

// ---------- R6: telemetry sanitized ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const evilTool = "mcp__<script>alert(1)</script>__x";
  const r = await MCP.runMcpGuarded({
    tool: evilTool,
    criticality: "optional",
    tightenBudgetMs: 40,
    execute: async () => { await sleep(150); return "x"; },
  });
  ok(r.cause === "MCP_TIMEOUT", "14 evil-named tool still times out structurally");
  const raw = existsSync(join(tmpHome, ".opencode-orchestration", "evidence", "v3", "orchestration", "session-injections.jsonl"))
    ? readFileSync(join(tmpHome, ".opencode-orchestration", "evidence", "v3", "orchestration", "session-injections.jsonl"), "utf8")
    : "";
  ok(!raw.includes("<script") && !raw.includes("alert(1)"), "14b telemetry never carries raw unsafe input");
  const rows = mcpRows();
  const allowedKeys = ["ts", "runtime", "kind", "event", "server", "class", "criticality", "mode", "cause", "origin", "turn_len", "elapsed_ms", "budget_ms"];
  ok(rows.length > 0 && rows.every((o) => Object.keys(o).every((k) => allowedKeys.includes(k))), "14c telemetry rows keep the closed schema");
  ok(rows.every((o) => typeof o.turn_len === "string" && o.turn_len.indexOf("len:") === 0), "14d turn logged as len fingerprint only");
  MCP.resetMcpTransport();
}

// ---------- R9: V1 parity (no crash, no silent enforcement) ----------
{
  MCP.resetMcpTransport();
  const hooks = await ((IDX as any).OrchestrationEnforcement as any)({});
  const transform = (hooks as any)["experimental.chat.system.transform"];
  ok(typeof transform === "function", "15 v1 hooks load with envelope present (no crash)");
  ok(!("tool" in hooks), "15b v1 exposes no tool-interception surface (observe/skip only)");
  const out: any = { system: ["base"] };
  await transform({ sessionID: "t-mcp-v1", agent: "coder", model: {} }, out);
  ok(typeof out.system[0] === "string" && out.system[0].includes("orchestration-enforcement:v1"), "15c v1 mandate path unaffected");
  ok(typeof (IDX as any).classifyMcpTool === "function" && typeof (IDX as any).runMcpGuarded === "function", "15d envelope shared from the dual index (same semantics both runtimes)");
  const dual = (IDX as any).default;
  ok(!!dual && typeof dual.setup === "function" && typeof dual.server === "function", "15e dual export keeps id+setup+server");
  MCP.resetMcpTransport();
}

// ---------- R-F1: mid-flight abort releases the probe, counts nothing ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const k = freshKey("abp");
  const tool = toolFor(k.server);
  const old = Date.now() - 400000;
  await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: old, execute: () => Promise.reject(new Error("n1")) });
  await MCP.runMcpGuarded({ tool, turn: k.turn, nowMs: old, execute: () => Promise.reject(new Error("n2")) });
  const before = MCP.getMcpCircuitSnapshot(k.server, "remote", k.turn, old + 1000);
  ok(before.state === "OPEN" && before.consecutive === 2, "17 abort-probe setup OPEN with streak 2");
  const ctl = new AbortController();
  let probeRan = 0;
  const p = MCP.runMcpGuarded({
    tool, turn: k.turn, signal: ctl.signal,
    execute: async () => { probeRan++; await sleep(200); return "never"; },
  });
  await sleep(20);
  ctl.abort();
  const r = await p;
  ok(probeRan === 1, "17b probe started before the abort");
  ok(r.cause === "MCP_ABORTED", "17c mid-flight abort surfaces MCP_ABORTED");
  const after = MCP.getMcpCircuitSnapshot(k.server, "remote", k.turn);
  ok(after.consecutive === 2 && after.state === "HALF_OPEN", "17d abort counts no failure and renews no cooldown (streak kept, cooldown expired)");
  let probe2Ran = 0;
  const r2 = await MCP.runMcpGuarded({
    tool, turn: k.turn,
    execute: async () => { probe2Ran++; return "probe2-ok"; },
  });
  ok(probe2Ran === 1 && r2.status === "OK", "17e probe reservation released (next probe runs, no stuck HALF_OPEN_BUSY)");
  ok(MCP.getMcpCircuitSnapshot(k.server, "remote", k.turn).state === "CLOSED", "17f successful second probe rearms");
  MCP.resetMcpTransport();
}

// ---------- R-F2: loser timers are cancelled (no orphan deadlines) ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  ok(MCP.__mcpTransportTest.pendingDeadlines() === 0, "18 no deadlines pending at start");
  const k = freshKey("tmr");
  await MCP.runMcpGuarded({ tool: toolFor(k.server), turn: k.turn, execute: async () => "fast" });
  ok(MCP.__mcpTransportTest.pendingDeadlines() === 0, "18b fast win cancels the loser timer");
  const k2 = freshKey("tmr2");
  await MCP.runMcpGuarded({
    tool: toolFor(k2.server), turn: k2.turn, tightenBudgetMs: 30,
    execute: async () => { await sleep(120); return "slow"; },
  });
  ok(MCP.__mcpTransportTest.pendingDeadlines() === 0, "18c timeout path leaves no pending deadline");
  MCP.resetMcpTransport();
}

// ---------- R-F4: exact-content cache + fresh file reads + named origins ----------
{
  MCP.resetMcpTransport();
  const a = CANON;
  const bObj = JSON.parse(CANON) as any;
  bObj.circuit.cooldown_seconds = 301;
  const b = JSON.stringify(bObj);
  ok(a.length === b.length, "19 collision fixture has equal length");
  // Through the path that actually caches: two guarded calls with
  // same-length, same-prefix, different-content inline texts. A
  // truncation key would collide; exact-content equality must not.
  const kA = freshKey("cc");
  await MCP.runMcpGuarded({ tool: toolFor(kA.server), turn: kA.turn, policyText: a, execute: async () => "v" });
  ok(!hasRow(kA.server, "policy-fallback"), "19 valid inline text accepted (no fallback)");
  const kB = freshKey("cc2");
  await MCP.runMcpGuarded({ tool: toolFor(kB.server), turn: kB.turn, policyText: b, execute: async () => "v" });
  const rowsB = mcpRows().filter((r) => r.server === kB.server && r.event === "policy-fallback");
  ok(rowsB.length > 0 && rowsB[0].origin === "call", "19b same-length deviating text falls back with origin call (no truncation-key collision)");
  let content: string | null = CANON;
  MCP.setMcpPolicyFileReader(() => content);
  MCP.configureMcpTransport({ policyPath: "/abs/fresh.json" });
  const k = freshKey("fr");
  await MCP.runMcpGuarded({ tool: toolFor(k.server), turn: k.turn, execute: async () => "v" });
  ok(!hasRow(k.server, "policy-fallback"), "19c valid file content accepted");
  content = "broken{{{";
  const k2 = freshKey("fr2");
  await MCP.runMcpGuarded({ tool: toolFor(k2.server), turn: k2.turn, execute: async () => "v" });
  ok(hasRow(k2.server, "policy-fallback"), "19d changed file content re-read (no stale file cache)");
  const rows = mcpRows().filter((r) => r.server === k2.server && r.event === "policy-fallback");
  ok(rows.length > 0 && rows[0].origin === "policy-file", "19e fallback row names the file origin");
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ policyText: "nope{{{", enforced: false });
  const k3 = freshKey("cfg");
  await MCP.runMcpGuarded({ tool: toolFor(k3.server), turn: k3.turn, execute: async () => "v" });
  const rows3 = mcpRows().filter((r) => r.server === k3.server && r.event === "policy-fallback");
  ok(rows3.length > 0 && rows3[0].origin === "configure", "19f configure-text fallback names its origin");
  MCP.resetMcpTransport();
}

// ---------- R-F5: internal error preserves the call criticality ----------
{
  MCP.resetMcpTransport();
  const evilOpts: any = {
    tool: "mcp__opt__call",
    criticality: "optional",
    execute: async () => "v",
  };
  Object.defineProperty(evilOpts, "tightenBudgetMs", {
    get() { throw new Error("evil-getter"); },
  });
  const r = await MCP.runMcpGuarded(evilOpts);
  ok(r.cause === "MCP_INTERNAL", "20 internal error carries MCP_INTERNAL cause");
  ok(r.status === "MCP_UNAVAILABLE" && r.ok && !r.blocked && r.fallback_continue, "20b optional preserved on internal error (fallback, not block)");
  const r2 = await MCP.runMcpGuarded(null as any);
  ok(r2.status === "MCP_REQUIRED_BLOCKED" && r2.blocked, "20c irrecoverable input stays conservative required/blocked");
  MCP.resetMcpTransport();
}

// ---------- R-M1: bounded store (eviction loses protection, documented) ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  for (let i = 0; i < 520; i++) {
    await MCP.runMcpGuarded({
      tool: "mcp__ev__call",
      turn: `evict-turn-${i}`,
      execute: () => Promise.reject(new Error("x")),
    });
  }
  const size = MCP.__mcpTransportTest.circuitSize();
  ok(size <= 500 && size > 0, `21 circuit store bounded (size=${size})`);
  MCP.resetMcpTransport();
  ok(MCP.__mcpTransportTest.circuitSize() === 0, "21b reset clears the store");
}

// ---------- REFORCO R-M1: evicted OPEN protection reads CLOSED (fail-open) ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const victimTurn = "evict-victim-turn";
  await MCP.runMcpGuarded({
    tool: "mcp__ev__call", turn: victimTurn, nowMs: T0,
    execute: () => Promise.reject(new Error("v1")),
  });
  await MCP.runMcpGuarded({
    tool: "mcp__ev__call", turn: victimTurn, nowMs: T0,
    execute: () => Promise.reject(new Error("v2")),
  });
  const openSnap = MCP.getMcpCircuitSnapshot("ev", "remote", victimTurn, T0);
  ok(openSnap.state === "OPEN", "21c victim entry OPEN before eviction flood");
  for (let i = 0; i < 520; i++) {
    await MCP.runMcpGuarded({
      tool: "mcp__ev__call",
      turn: `evict-flood-${i}`,
      execute: () => Promise.reject(new Error("x")),
    });
  }
  const lost = MCP.getMcpCircuitSnapshot("ev", "remote", victimTurn, T0);
  ok(lost.state === "CLOSED" && lost.consecutive === 0, "21d evicted OPEN protection reads CLOSED (documented fail-open residual)");
  MCP.resetMcpTransport();
}

// ---------- FIX3-1: hostile throw after timer creation still cleans up ----------
{
  MCP.resetMcpTransport();
  MCP.configureMcpTransport({ enforced: true });
  const hostile: any = { aborted: false };
  Object.defineProperty(hostile, "addEventListener", {
    get() { throw new Error("evil-listen"); },
  });
  const k = freshKey("hsl");
  const r = await MCP.runMcpGuarded({
    tool: toolFor(k.server), turn: k.turn, criticality: "optional", signal: hostile,
    tightenBudgetMs: 50,
    execute: async () => "v",
  });
  ok(r.cause === "MCP_INTERNAL", "22 hostile post-timer throw surfaces MCP_INTERNAL");
  ok(r.status === "MCP_UNAVAILABLE" && r.fallback_continue, "22b optional preserved on post-timer internal error");
  ok(MCP.__mcpTransportTest.pendingDeadlines() === 0, "22c no orphan deadline after internal throw past timer creation");
  MCP.resetMcpTransport();
}

// ---------- config surface ----------
{
  MCP.resetMcpTransport();
  process.env.OO_MCP_TRANSPORT_ENFORCED = "1";
  ok(MCP.effectiveMcpMode(undefined).mode === "enforced", "16 env opt-in key enables enforced (OO_MCP_TRANSPORT_ENFORCED=1)");
  delete process.env.OO_MCP_TRANSPORT_ENFORCED;
  ok(MCP.effectiveMcpMode(undefined).mode === "shadow", "16b default without opt-in is shadow");
  ok(MCP.getMcpCircuitSnapshot("s", "nope", "t").state === "UNKNOWN", "16c unknown class => UNKNOWN snapshot");
}

console.log(`SUMMARY pass=${pass} fail=${fail}`);
process.exitCode = fail > 0 ? 1 : 0;
// No explicit process.exit: loser timers are cancelled and unref'd,
// so nothing pins the loop and a natural exit here proves R-F2/R-S1.
// (If this harness ever hangs instead of exiting, a pending handle
// regressed and the hang itself is the signal.)
