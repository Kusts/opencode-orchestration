// v2-mock.ts - V31-R2 F3 harness mock V2 (local, sem rede) + Phase 24 fatia 1.
// Monta um ctx fake com as superficies documentadas (event.subscribe
// AsyncIterable com signal + session/tool com .hook), registra o setup()
// do adapter V2, entrega um evento de lifecycle via subscribe e afirma:
// sessionIndex atualizado, mandato v2 injetado (marker), telemetria com
// runtime:v2, setup que NAO aguarda o stream infinito, cleanup que aborta
// o loop. Tambem cobre: deteccao de superficies ausentes (fail-open +
// telemetria hooks-unavailable, com "event.subscribe unavailable") e as
// representacoes de system do F5 (parts[], string[], vazio, misto).
// Rode com: bun run tests/distribution/plugin-harness/v2-mock.ts
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

// Isola a telemetria: o sink jsonl mora sob $HOME/.opencode-orchestration.
const tmpHome = mkdtempSync(join(tmpdir(), "oo-v2mock-"));
process.env.HOME = tmpHome;
process.env.USERPROFILE = tmpHome;

const { V2Plugin, __orchestrationEnforcementV2Test } = await import(
  "../../../plugins/orchestration-enforcement/v2.ts"
);

const V2_MARKER = "[orchestration-enforcement:v2]";
const V2_WORKER_MARKER = "[orchestration-enforcement:v2:worker]";

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

type Cb = (input: any) => any;

function tick(ms = 25): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// Event stream mock (Phase 24 fatia 1): expoe o contrato documentado
// ctx.event.subscribe({ signal }) => AsyncIterable. O plugin inicia um loop
// detached com AbortController proprio; push() entrega eventos ao loop e o
// abort do cleanup encerra a espera. Propositalmente SEM .hook: prova que o
// plugin nao usa mais a superficie obsoleta event.hook.
function makeEventStream() {
  const queue: Array<any> = [];
  let notify: (() => void) | null = null;
  return {
    push(e: any): void {
      queue.push(e);
      const n = notify;
      notify = null;
      if (n) {
        try {
          n();
        } catch {
          // Fail-open no mock.
        }
      }
    },
    subscribe(opts: any): AsyncIterable<any> {
      const signal = opts?.signal as AbortSignal | undefined;
      async function* gen(): AsyncGenerator<any, void, unknown> {
        while (true) {
          if (signal?.aborted) return;
          if (queue.length === 0) {
            await new Promise<void>((resolve) => {
              let settled = false;
              const done = () => {
                if (settled) return;
                settled = true;
                try {
                  signal?.removeEventListener?.("abort", onAbort);
                } catch {
                  // Fail-open no mock.
                }
                resolve();
              };
              const onAbort = () => {
                notify = null;
                done();
              };
              notify = done;
              try {
                if (signal?.aborted) {
                  notify = null;
                  done();
                  return;
                }
                signal?.addEventListener?.("abort", onAbort, { once: true });
              } catch {
                // Sem suporte a abort: espera so o push.
              }
            });
            if (signal?.aborted) return;
            continue;
          }
          yield queue.shift();
        }
      }
      return gen();
    },
  };
}

function makeSurface() {
  const handlers = new Map<string, Array<Cb>>();
  return {
    handlers,
    hook: async (name: string, cb: Cb) => {
      const arr = handlers.get(name) ?? [];
      arr.push(cb);
      handlers.set(name, arr);
      return {
        dispose: () => {
          const l = handlers.get(name) ?? [];
          const i = l.indexOf(cb);
          if (i >= 0) l.splice(i, 1);
        },
      };
    },
    fire: async (name: string, input: any) => {
      for (const cb of [...(handlers.get(name) ?? [])]) await cb(input);
    },
  };
}

function readJsonl(): Array<any> {
  const p = join(tmpHome, ".opencode-orchestration", "evidence", "v3", "orchestration", "session-injections.jsonl");
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8")
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter((o) => o !== null);
}

ok(typeof V2Plugin?.setup === "function", "v2 setup exportado");
ok(typeof V2Plugin?.id === "string" && V2Plugin.id.length > 0, "v2 id exportado");

// 1. setup com superficies completas retorna cleanup sem throw e SEM
// aguardar o stream infinito (o loop de eventos e detached com signal).
const ev = makeEventStream();
const sess = makeSurface();
const tool = makeSurface();
let cleanup: unknown = null;
let threwSetup = false;
let setupMs = -1;
try {
  const t0 = Date.now();
  cleanup = await V2Plugin.setup({ event: ev, session: sess, tool });
  setupMs = Date.now() - t0;
} catch {
  threwSetup = true;
}
ok(!threwSetup && typeof cleanup === "function", "1 setup completo retorna cleanup");
ok(!threwSetup && setupMs >= 0 && setupMs < 2000, "1b setup nao aguarda stream infinito", `dt=${setupMs}ms`);

// 2. lifecycle via event.subscribe indexa sessao (worker coder).
// Expectativa independente: evento entregue no stream => index atualizado.
ev.push({
  event: { type: "session.created", properties: { info: { id: "v2-mock-sess-1", agent: "coder" } } },
});
await tick();
ok(__orchestrationEnforcementV2Test.sessionIndexSize() === 1, "2 session.created via subscribe indexa sessao");

// 2b. filtro: tipo irrelevante nao popula o indice.
ev.push({
  event: { type: "session.idle", properties: { info: { id: "v2-mock-sess-idle", agent: "coder" } } },
});
await tick();
ok(__orchestrationEnforcementV2Test.sessionIndexSize() === 1, "2b tipo irrelevante nao indexa");

// 3. contexto com system vazio (parts[], canonico V2): injeta parte textual v2 worker.
const ctxEmpty: any = { sessionID: "v2-mock-sess-1", agent: "coder", system: [] };
await sess.fire("context", ctxEmpty);
ok(
  Array.isArray(ctxEmpty.system) &&
    ctxEmpty.system.length === 1 &&
    typeof ctxEmpty.system[0] === "object" &&
    (ctxEmpty.system[0] as any).type === "text" &&
    typeof (ctxEmpty.system[0] as any).text === "string" &&
    ((ctxEmpty.system[0] as any).text as string).includes(V2_WORKER_MARKER),
  "3 system vazio injeta parte textual v2 worker",
);

// 4. contexto com string[] (formato V1): append string, sem misturar formatos.
const ctxStrings: any = { sessionID: "v2-mock-s2", agent: "build", system: ["base do planner"] };
await sess.fire("context", ctxStrings);
ok(
  Array.isArray(ctxStrings.system) &&
    ctxStrings.system.length === 2 &&
    typeof ctxStrings.system[1] === "string" &&
    (ctxStrings.system[1] as string).includes(V2_MARKER) &&
    ctxStrings.system.every((s: unknown) => typeof s === "string"),
  "4 string[] recebe append string (sem misturar)",
);

// 5. contexto com parts[] existente: append parte textual.
const ctxParts: any = {
  sessionID: "v2-mock-s3",
  agent: "build",
  system: [{ type: "text", text: "base" }],
};
await sess.fire("context", ctxParts);
ok(
  Array.isArray(ctxParts.system) &&
    ctxParts.system.length === 2 &&
    (ctxParts.system[1] as any).type === "text" &&
    ((ctxParts.system[1] as any).text as string).includes(V2_MARKER),
  "5 parts[] recebe append de parte textual",
);

// 6. formato misto (empate => primeira parte vence, string): nao introduz parte textual.
const ctxMixed: any = {
  sessionID: "v2-mock-s4",
  agent: "build",
  system: ["a", { type: "text", text: "b" }],
};
await sess.fire("context", ctxMixed);
ok(
  Array.isArray(ctxMixed.system) &&
    ctxMixed.system.length === 3 &&
    typeof ctxMixed.system[2] === "string" &&
    (ctxMixed.system[2] as string).includes(V2_MARKER),
  "6 misto empatado segue primeira parte (string, sem misturar)",
);

// 7. execute.before: telemetria de ferramenta com runtime:v2.
await tool.fire("execute.before", { tool: "read", sessionID: "v2-mock-sess-1", agent: "coder" });
const rows = readJsonl();
const inj = rows.find((r) => r.runtime === "v2" && typeof r.markerUsed === "string" && (r.markerUsed as string).includes("orchestration-enforcement:v2"));
ok(!!inj, "7 telemetria de injecao com runtime:v2", `linhas=${rows.length}`);
const toolRow = rows.find((r) => r.runtime === "v2" && r.kind === "tool-event" && r.tool === "read");
ok(!!toolRow, "7 telemetria tool-event com runtime:v2");
void homedir;

// 8. idempotencia: repetir o mesmo contexto nao duplica mandato.
const before = JSON.stringify(ctxEmpty);
await sess.fire("context", ctxEmpty);
ok(JSON.stringify(ctxEmpty) === before, "8 contexto repetido nao duplica mandato");

// F2 (SIMPLIFY-F2-MANDATE): o mandato do Planner V2 nao pode transformar
// preflight/worker/Kernel/reviewer em rito para trabalho claro, local,
// reversivel e de baixo risco; Kernel/autoridade seguem obrigatorios onde
// ha efeito durável/compartilhado/concorrente/externo e em acoes
// destrutivas/producao/segredos. V1 e LEGACY_FROZEN: o texto emitido tem de
// permanecer byte-identico (literais abaixo sao o contrato atual do V1).
const V1_PLANNER_EXPECTED =
  "Mandatory orchestration preflight before the first action: classify the task as SINGLE_WORKER, MULTI_WORKER, PERSISTENT_GOAL, DETERMINISTIC_FALLBACK, or BLOCKED. SINGLE_WORKER is full orchestration (Planner -> one cheap worker -> Planner); the Planner never performs the user's operational work directly when a suitable worker exists.\n" +
  "Non-trivial tasks require material participation of at least one suitable subagent; doing everything alone without a recorded decision is ORCHESTRATION_POLICY_BYPASS.\n" +
  "For relevant changes, follow the coder → tester → reviewer cycle and integrate their syntheses. DONE requires observed worker participation on non-trivial work.\n\n" +
  "[orchestration-enforcement:v1]";

const f2 = makeSurface();
const f2Tool = makeSurface();
let f2Cleanup: unknown = null;
try {
  f2Cleanup = await V2Plugin.setup({ event: makeEventStream(), session: f2, tool: f2Tool });
} catch {
  f2Cleanup = null;
}
const v2PlannerCtx: any = { sessionID: "f2-v2-planner", agent: "build", system: [{ type: "text", text: "base" }] };
await f2.fire("context", v2PlannerCtx);
const v2PlannerText =
  Array.isArray(v2PlannerCtx.system) && v2PlannerCtx.system.length === 2 && typeof v2PlannerCtx.system[1]?.text === "string"
    ? (v2PlannerCtx.system[1].text as string)
    : "";
ok(
  v2PlannerText.includes("DIRECT_VERIFIED") && /zero workers/i.test(v2PlannerText),
  "F2 V2 planner: DIRECT_VERIFIED honrado como zero workers",
);
ok(
  /no preflight, worker, kernel task, review cycle, worktree, or pr is mandatory/i.test(v2PlannerText) &&
    /low-risk, local, reversible/i.test(v2PlannerText),
  "F2 V2 planner: direto permitido sem rito obrigatorio",
  v2PlannerText.slice(0, 120),
);
ok(
  /durable, shared, concurrent, or external-effect/i.test(v2PlannerText) &&
    /destructive/i.test(v2PlannerText) &&
    /production/i.test(v2PlannerText) &&
    /secrets/i.test(v2PlannerText) &&
    /grants no authority/i.test(v2PlannerText),
  "F2 V2 planner: Kernel/autoridade preservados",
);
ok(
  /one file and one code unit/i.test(v2PlannerText) &&
    /function, branch, condition, or expression/i.test(v2PlannerText) &&
    /one micro-fix/i.test(v2PlannerText) &&
    /focused test/i.test(v2PlannerText) &&
    /T2 coder/.test(v2PlannerText),
  "F2-SCOPE V2 planner: um arquivo E uma unidade de codigo + teste focado",
  v2PlannerText.slice(0, 220),
);
ok(
  !/single file, function/i.test(v2PlannerText) &&
    !/one file, function/i.test(v2PlannerText) &&
    !/one file, branch/i.test(v2PlannerText) &&
    !/one file or one/i.test(v2PlannerText),
  "F2-SCOPE V2 planner: sem listagem ambigua arquivo-ou-unidade",
  v2PlannerText.slice(0, 220),
);
ok(
  ["payment", "billing", "pricing", "permission", "auth", "security", "secrets", "credentials", "production", "destructive", "architecture", "multi-file", "substantive", "concurrency", "Kernel-owned"].every(
    (w) => new RegExp(w.replace("-", "\\-"), "i").test(v2PlannerText),
  ) &&
    !/docs-only microedits/i.test(v2PlannerText) &&
    !/functional code writes still classify as MULTI_WORKER/i.test(v2PlannerText),
  "F2-DIRECT V2 planner: exclusoes do micro-escopo + sem restricao stale",
  v2PlannerText.slice(0, 200),
);
ok(
  /TaskType=trivial/.test(v2PlannerText) &&
    /Domain=code/.test(v2PlannerText) &&
    /Risk=low/.test(v2PlannerText) &&
    /ReadWrite=write/.test(v2PlannerText),
  "F2-DIRECT V2 planner: criterio espelha o classificador existente",
);
ok(
  /grants no authority/i.test(v2PlannerText) && /evidence/i.test(v2PlannerText) && !/docs-only microedits/i.test(v2PlannerText),
  "F2-DIRECT V2 planner: Kernel Evidence Contract e autoridade preservados",
);
ok(
  /multi-file/i.test(v2PlannerText) &&
    /new feature/i.test(v2PlannerText) &&
    /refactor/i.test(v2PlannerText) &&
    /non-trivial/i.test(v2PlannerText) &&
    /sensitive/i.test(v2PlannerText),
  "F2-DIRECT V2 planner: fora do micro-escopo segue delegado/Kernel",
);
ok(
  !v2PlannerText.includes("Mandatory orchestration preflight before the first action") &&
    !v2PlannerText.includes("never performs the user's operational work directly") &&
    !v2PlannerText.includes("DONE requires observed worker participation"),
  "F2 V2 planner: sem as frases coercitivas antigas",
);
if (typeof f2Cleanup === "function") {
  try {
    (f2Cleanup as () => void)();
  } catch {
    // Fail-open no mock.
  }
}

// F2-V1: mandato do Planner V1 byte-identico ao atual (LEGACY_FROZEN).
const { OrchestrationEnforcement: V1PluginForF2 } = await import("../../../plugins/orchestration-enforcement.ts");
let v1PlannerSeg = "";
try {
  const v1Hooks: any = await (V1PluginForF2 as any)({});
  const v1Transform = v1Hooks["experimental.chat.system.transform"];
  const v1Out: any = { system: ["v1-planner-base"] };
  await v1Transform({ sessionID: "f2-v1-planner", agent: "build", model: {} }, v1Out);
  const v1All = typeof v1Out.system?.[0] === "string" ? (v1Out.system[0] as string) : "";
  const prefix = "v1-planner-base\n\n";
  v1PlannerSeg = v1All.startsWith(prefix) ? v1All.slice(prefix.length) : "";
} catch {
  v1PlannerSeg = "";
}
ok(v1PlannerSeg === V1_PLANNER_EXPECTED, "F2 V1 planner mandate byte-identico", JSON.stringify(v1PlannerSeg.slice(0, 80)));

// F2-SCOPE: o adapter V2 canonico (fonte do prompt gerado) precisa declarar
// os DOIS marcadores de escopo (arquivo E unidade de codigo) + teste focado, e
// nao a listagem ambigua que o predicado do preflight nao aceita sozinha.
let adapterV2 = "";
try {
  adapterV2 = readFileSync(new URL("../../../source/adapters/opencode-v2.md", import.meta.url), "utf8");
} catch {
  adapterV2 = "";
}
ok(
  /um\s+\S+\s+arquivo\s+quanto\s+uma\s+\S+\s+unidade/i.test(adapterV2) &&
    /focused test/i.test(adapterV2) &&
    /DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK/.test(adapterV2) &&
    /billing/.test(adapterV2) &&
    /Kernel/.test(adapterV2),
  "F2-SCOPE adapter Orquestracao V2: arquivo E unidade + teste focado + exclusoes",
  adapterV2.slice(0, 120),
);
ok(
  !/arquivo,\s*\S*fun/i.test(adapterV2) && !/um\s+\S+\s+arquivo\s+ou\s+/i.test(adapterV2),
  "F2-SCOPE adapter Orquestracao V2: sem arquivo-ou-unidade ambiguo",
);

// 9. superficies ausentes: setup({}) nao lanca e registra hooks-unavailable.
let threwBare = false;
let bareCleanup: unknown = null;
try {
  bareCleanup = await V2Plugin.setup({});
} catch {
  threwBare = true;
}
ok(!threwBare, "9 setup({}) fail-open (sem throw)");
const rows2 = readJsonl();
const unav = rows2.filter((r) => r.runtime === "v2" && r.kind === "hooks-unavailable");
ok(
  unav.length >= 3 &&
    unav.some((r) => r.reason === "event.subscribe unavailable") &&
    unav.some((r) => r.reason === "session.hook unavailable") &&
    unav.some((r) => r.reason === "tool.hook unavailable"),
  "9 telemetria hooks-unavailable por superficie",
  `unav=${unav.length}`,
);
if (typeof bareCleanup === "function") {
  let threwBareCleanup = false;
  try {
    (bareCleanup as () => void)();
  } catch {
    threwBareCleanup = true;
  }
  ok(!threwBareCleanup, "9 cleanup parcial sem throw");
}

// 10. cleanup aborta o loop de eventos e limpa estado, sem erro.
let threwCleanup = false;
try {
  (cleanup as () => void)();
} catch {
  threwCleanup = true;
}
ok(!threwCleanup, "10 cleanup sem throw");
ok(__orchestrationEnforcementV2Test.sessionIndexSize() === 0, "10 cleanup limpa sessionIndex");

// 10b. apos o abort, evento novo NAO reindexa (loop encerrado).
ev.push({
  event: { type: "session.created", properties: { info: { id: "v2-mock-after-cleanup", agent: "coder" } } },
});
await tick();
ok(__orchestrationEnforcementV2Test.sessionIndexSize() === 0, "10b pos-cleanup nao reindexa (abort ok)");

// 10c. corrida abort-before-record (RR-P24-REV-FIX): iterador HOSTIL cujo
// next() pendente entrega deliberadamente {done:false, value:evento} MESMO
// apos abort (NAO checa signal no gerador). So o guard do plugin (aborted
// ANTES de recordSessionEvent em v2.ts) impede a indexacao.
// PROVA DE DISCRIMINACAO (por construcao): este iterador ignora abort
// (sem addEventListener, sem checagem de signal, nunca retorna done:true),
// logo o next() pendente SEMPRE resolve com {done:false, value:evento}.
// Sem await entre push() e cleanup(), o cleanup (abort + sessionIndex.clear
// sincronos) executa ANTES da continuacao do for-await (microtask). Sem o
// guard do plugin, a continuacao chamaria recordSessionEvent APOS o clear
// => size 1 (FAIL). Com o guard, o evento e descartado => size 0 (PASS).
// Ou seja: size==0 so e possivel com o guard presente; o teste distingue
// guard presente vs ausente e nao passa vacuamente.
function makeHostileStream() {
  const queued: Array<any> = [];
  let resolvePending: ((v: any) => void) | null = null;
  return {
    push(e: any): void {
      if (resolvePending) {
        const r = resolvePending;
        resolvePending = null;
        try {
          r(e);
        } catch {
          // Fail-open no mock.
        }
        return;
      }
      queued.push(e);
    },
    subscribe(_opts: any): AsyncIterable<any> {
      // Ignora _opts.signal de proposito: iterador hostil.
      void _opts;
      return {
        [Symbol.asyncIterator]() {
          return {
            next(): Promise<{ done: boolean; value?: any }> {
              if (queued.length > 0) {
                const v = queued.shift();
                return Promise.resolve({ done: false, value: v });
              }
              return new Promise<{ done: boolean; value?: any }>((resolve) => {
                // Pendente: resolve com evento mesmo apos abort do cleanup.
                resolvePending = (v: any) => resolve({ done: false, value: v });
              });
            },
            return(): Promise<{ done: boolean; value?: any }> {
              return Promise.resolve({ done: true, value: undefined });
            },
            throw(): Promise<{ done: boolean; value?: any }> {
              return Promise.resolve({ done: true, value: undefined });
            },
          };
        },
      };
    },
  };
}
const evR = makeHostileStream();
const sessR = makeSurface();
const toolR = makeSurface();
let cleanupR: unknown = null;
try {
  cleanupR = await V2Plugin.setup({ event: evR, session: sessR, tool: toolR });
} catch {
  cleanupR = null;
}
ok(typeof cleanupR === "function", "10c setup fresco para corrida abort-before-record");
if (typeof cleanupR === "function") {
  await tick(50);
  evR.push({
    event: { type: "session.created", properties: { info: { id: "v2-mock-race-1", agent: "coder" } } },
  });
  // Sem await entre push e cleanup: o consumidor pendente ainda nao retomou.
  (cleanupR as () => void)();
  await tick(50);
  ok(__orchestrationEnforcementV2Test.sessionIndexSize() === 0, "10c next() pendente + cleanup antes => indice vazio");
} else {
  ok(false, "10c next() pendente + cleanup antes => indice vazio", "setup fresco falhou");
}

// 10c-controle (prova de discriminacao executavel): o iterador hostil
// IGNORA abort de verdade. Prova direta: next() pendente resolve
// {done:false, value:evento} mesmo com signal ja abortado. Logo, o size==0
// do 10c so e possivel pelo guard do plugin (v2.ts); um consumo cru sem
// guard receberia o valor e indexaria (size 1). Sem este controle, o 10c
// poderia passar vacuamente (iterador bem-comportado que respeita abort).
const evC = makeHostileStream();
const ctrlC = new AbortController();
const iterC = (evC.subscribe({ signal: ctrlC.signal }) as AsyncIterable<any>)[Symbol.asyncIterator]();
const pendingC = iterC.next();
ctrlC.abort();
evC.push({
  event: { type: "session.created", properties: { info: { id: "v2-mock-control-1", agent: "coder" } } },
});
const resC = await pendingC;
ok(
  resC.done === false && !!resC.value,
  "10c-controle iterador hostil entrega valor apos abort (sem guard indexaria)",
);

// PW-V2 planner-wait tool (PR181 Fatia A, opt-in, off by default).
// The tool lives on the EXISTING orchestration-enforcement V2 setup path
// (plugins/orchestration-enforcement/v2.ts); there is no separate plugin.
// These tests use stubbed spawn/sessionGet (never a real bridge) and run
// with the same `bun run` gate as the rest of this mock.
function makePwToolSurface() {
  const added: Array<any> = [];
  const handlers = new Map<string, Array<Cb>>();
  return {
    added,
    hook: async (name: string, cb: Cb) => {
      const arr = handlers.get(name) ?? [];
      arr.push(cb);
      handlers.set(name, arr);
      return { dispose: () => {} };
    },
    transform: async (cb: (editor: any) => void) => {
      const editor = {
        list: () => [],
        get: () => undefined,
        namespace: () => {},
        add: (t: any) => {
          added.push(t);
        },
        update: () => {},
        remove: () => {},
      };
      await cb(editor);
      return { dispose: async () => {} };
    },
  };
}
function makePwSessionSurface(info: any, recorded?: Array<any>) {
  return {
    hook: async (_name: string, _cb: Cb) => ({ dispose: () => {} }),
    // Test fixture models prior 2.0.23 runtime-observed Promise layer; current 2.2.6 is typechecked, not runtime-observed. get({sessionID})
    // => Promise<SessionInfo> (direct). Records the raw host argument so
    // tests can assert the object shape ({sessionID} — never a bare string).
    get: async (arg: unknown) => {
      try {
        recorded?.push(arg);
      } catch {
        // Fail-open no mock.
      }
      return info;
    },
  };
}
// SessionInfo fixtures based on actual 2.0.23 observation only (not evidence for 2.2.6):
// id/projectID/cost(number)/tokens(location/time objects)/title; root has
// NO own parentID key).
function pwRootSession(id: string): any {
  return {
    id,
    projectID: "proj-1",
    title: "planner",
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    location: { directory: "/repo" },
    time: { created: 1, updated: 2 },
  };
}
function pwChildSession(id: string, parentID: string): any {
  return { ...pwRootSession(id), title: "child", parentID };
}
const PW_ENV_KEYS = [
  "OPENCODE_PLANNER_WAIT_ENABLED",
  "OPENCODE_PLANNER_WAIT_BRIDGE",
  "OPENCODE_PLANNER_WAIT_SHELL",
  "OPENCODE_PLANNER_WAIT_TIMEOUT_MS",
];
function savePwEnv(): Record<string, string | undefined> {
  const out: Record<string, string | undefined> = {};
  for (const k of PW_ENV_KEYS) out[k] = process.env[k];
  return out;
}
function restorePwEnv(saved: Record<string, string | undefined>): void {
  for (const k of PW_ENV_KEYS) {
    if (saved[k] === undefined) delete process.env[k];
    else process.env[k] = saved[k] as string;
  }
}
function clearPwEnv(): void {
  for (const k of PW_ENV_KEYS) delete process.env[k];
}
function makePwBridgeFixture(): { dir: string; bridge: string } {
  const dir = mkdtempSync(join(tmpdir(), "pw-v2mock-"));
  const bridge = join(dir, "planner-wait-bridge.ps1");
  writeFileSync(bridge, "# fixture bridge\n", "utf8");
  return { dir, bridge };
}
function pwValidArgs(): any {
  return {
    task_id: "pw-task-1",
    goal_id: "pw-goal-1",
    run_id: "run-1",
    repository: "acme/widgets",
    pr_number: 42,
    branch: "fix/pw",
    expected_head_sha: "a".repeat(40),
    required_checks: ["ci"],
    review_expectation: "APPROVED",
    cursor: "",
    deadline_utc: "2026-10-11T00:00:00Z",
    retry_budget_max: 5,
  };
}
const PW_SAFE_KEYS = [
  "task_id",
  "goal_id",
  "run_id",
  "repository",
  "pr_number",
  "branch",
  "expected_head_sha",
  "required_checks",
  "review_expectation",
  "cursor",
  "deadline_utc",
  "retry_budget_max",
];
const PW_REMOVED_KEYS = [
  "owner",
  "ownership_generation",
  "lease_owner",
  "lease_expires_utc",
  "goal_store_dir",
  "tasks_dir",
  "waits_dir",
  "flags_path",
  "repo_root",
];
function pwPlannerContext(sessionID: string): any {
  return { sessionID, agent: "build", messageID: "msg-01", id: "call-01" };
}
function pwStubSpawn(
  calls: Array<any>,
  script: (args: { child: any; stdout: any; payload: string; exe: string; argv: Array<string>; opts: any }) => void,
): (exe: string, argv: Array<string>, opts: any) => any {
  const { EventEmitter } = require("node:events");
  return (exe: string, argv: Array<string>, opts: any) => {
    const child = new EventEmitter();
    const stdout = new EventEmitter();
    const stderr = new EventEmitter();
    const stdin = new EventEmitter();
    let payload = "";
    (stdin as any).write = (chunk: any) => {
      payload += String(chunk);
      return true;
    };
    (stdin as any).end = () => {
      try {
        script({ child, stdout, payload, exe, argv, opts });
      } catch (err) {
        child.emit("error", err);
      }
    };
    (child as any).stdin = stdin;
    (child as any).stdout = stdout;
    (child as any).stderr = stderr;
    (child as any).kill = () => {
      try {
        child.emit("close", null);
      } catch {
        // Fail-open no mock.
      }
      return true;
    };
    calls.push({ exe, argv, opts, getPayload: () => payload });
    return child;
  };
}

const pwMod: any = (await import("../../../plugins/orchestration-enforcement/v2.ts")) as any;
const pwT: any = pwMod.__plannerWaitV2Test;
ok(!!pwT && typeof pwT.makeExecute === "function", "PW-T hook de teste exportado pelo adapter V2");
if (!pwT || typeof pwT.makeExecute !== "function") {
  for (const name of ["PW-T4", "PW-T5", "PW-T6", "PW-T7"]) ok(false, name, "hook ausente");
} else {

// PW-T1: opt-in desligado por padrao => setup nao registra ferramenta.
{
  const saved = savePwEnv();
  try {
    clearPwEnv();
    const tool = makePwToolSurface();
    let threw = false;
    try {
      await V2Plugin.setup({ event: makeEventStream(), session: makeSurface(), tool });
    } catch {
      threw = true;
    }
    ok(!threw, "PW-T1 setup sem env nao lanca");
    ok(tool.added.length === 0, "PW-T1 opt-in desligado: nenhuma tool registrada", `added=${tool.added.length}`);
  } finally {
    restorePwEnv(saved);
  }
}

// PW-T2: habilitado com fixture => exatamente uma tool, shape baseada na observação histórica 2.0.23,
// input sem campo de sessao.
{
  const saved = savePwEnv();
  const fx = makePwBridgeFixture();
  try {
    clearPwEnv();
    process.env.OPENCODE_PLANNER_WAIT_ENABLED = "1";
    process.env.OPENCODE_PLANNER_WAIT_BRIDGE = fx.bridge;
    process.env.OPENCODE_PLANNER_WAIT_SHELL = process.execPath;
    const tool = makePwToolSurface();
    let threw = false;
    try {
      await V2Plugin.setup({ event: makeEventStream(), session: makePwSessionSurface(pwRootSession("ses-root-1")), tool });
    } catch {
      threw = true;
    }
    ok(!threw, "PW-T2 setup habilitado nao lanca");
    ok(tool.added.length === 1, "PW-T2 exatamente uma tool registrada", `added=${tool.added.length}`);
    if (tool.added.length === 1) {
      const t = tool.added[0];
      ok(t.name === "orchestration_planner_wait", "PW-T2 nome da tool", String(t.name));
      const props = (t.input && t.input.properties) || {};
      ok(!Object.keys(props).some((k: string) => /session/i.test(k)), "PW-T2 input sem campo de sessao");
      ok(typeof t.execute === "function", "PW-T2 execute e funcao");
      ok(t.execute.length === 2, "PW-T2 execute recebe (args, context)");
      ok(typeof t.description === "string" && t.description.length > 0, "PW-T2 description presente");
    }
  } finally {
    restorePwEnv(saved);
    try {
      const { rmSync } = await import("node:fs");
      rmSync(fx.dir, { recursive: true, force: true });
    } catch {
      // Fail-open no mock.
    }
  }
}

// PW-T3: habilitado com fixture invalida => fail-open (sem throw, sem tool).
{
  const saved = savePwEnv();
  try {
    clearPwEnv();
    process.env.OPENCODE_PLANNER_WAIT_ENABLED = "1";
    process.env.OPENCODE_PLANNER_WAIT_SHELL = process.execPath;
    const tool = makePwToolSurface();
    let threw = false;
    try {
      await V2Plugin.setup({ event: makeEventStream(), session: makePwSessionSurface(pwRootSession("s")), tool });
    } catch {
      threw = true;
    }
    ok(!threw, "PW-T3 fixture invalida nao lanca (fail-open)");
    ok(tool.added.length === 0, "PW-T3 fixture invalida: nenhuma tool registrada");
  } finally {
    restorePwEnv(saved);
  }
}

// PW-T4: execute nega worker sem spawn.
{
  const calls: Array<any> = [];
  const handler = pwT.makeExecute(
    { bridge: "b", shell: "s", timeoutMs: 1000 },
    { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => pwRootSession("ses-w-1") },
  );
  let reason = "";
  try {
    await handler(pwValidArgs(), { sessionID: "ses-w-1", agent: "coder", messageID: "m", id: "c" });
  } catch (e) {
    reason = String((e as Error)?.message ?? e);
  }
  ok(/planner-wait-worker-denied/.test(reason), "PW-T4 worker negado", reason);
  ok(calls.length === 0, "PW-T4 worker negado antes do spawn");
}

// PW-T5: execute nega identidade de sessao vinda do modelo.
{
  const calls: Array<any> = [];
  const handler = pwT.makeExecute(
    { bridge: "b", shell: "s", timeoutMs: 1000 },
    { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => pwRootSession("ses-root-1") },
  );
  const args = pwValidArgs();
  args.session_id = "ses-forged";
  let reason = "";
  try {
    await handler(args, pwPlannerContext("ses-root-1"));
  } catch (e) {
    reason = String((e as Error)?.message ?? e);
  }
  ok(/planner-wait-session-forbidden/.test(reason), "PW-T5 sessao do modelo recusada", reason);
  ok(calls.length === 0, "PW-T5 sessao forjada recusada antes do spawn");
}

// PW-T6: execute nega sessao nao-root via proveniencia do host.
{
  const calls: Array<any> = [];
  const handler = pwT.makeExecute(
    { bridge: "b", shell: "s", timeoutMs: 1000 },
    { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => pwChildSession("ses-child-9", "ses-root-1") },
  );
  let reason = "";
  try {
    await handler(pwValidArgs(), { sessionID: "ses-child-9", agent: "build", messageID: "m", id: "c" });
  } catch (e) {
    reason = String((e as Error)?.message ?? e);
  }
  ok(/planner-wait-not-root/.test(reason), "PW-T6 nao-root negado", reason);
  ok(calls.length === 0, "PW-T6 nao-root negado antes do spawn");
}

// PW-T7: planner root ok com bridge stubada; sessao do HOST vai no stdin,
// pins de autoridade falsos, argv literal com shell:false.
{
  const calls: Array<any> = [];
  const doc = {
    schema_version: 1, operation: "bind-wait", ok: true, reason: "registered",
    run_id: "run-1", revision: 3, binding: "bound", wait_reused: false,
    wait_file: "w", dedup_key: "d", task_mutated: true,
    grants_authority: false, done_approved: false,
  };
  const handler = pwT.makeExecute(
    { bridge: "B", shell: "S", timeoutMs: 1000 },
    {
      spawnFn: pwStubSpawn(calls, ({ child, stdout }) => {
        stdout.emit("data", JSON.stringify(doc));
        child.emit("close", 0);
      }),
      sessionGet: async () => pwRootSession("ses-root-1"),
    },
  );
  let out: any = null;
  let reason = "";
  try {
    out = await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
  } catch (e) {
    reason = String((e as Error)?.message ?? e);
  }
  ok(out !== null && reason === "", "PW-T7 planner root executa", reason);
  ok(calls.length === 1, "PW-T7 exatamente uma chamada ao bridge");
  if (calls.length === 1) {
    const argv = calls[0].argv as Array<string>;
    ok(
      argv.length === 4 && argv[0] === "-NoProfile" && argv[1] === "-NonInteractive" && argv[2] === "-File" && argv[3] === "B",
      "PW-T7 argv literal",
      argv.join(" "),
    );
    ok(calls[0].opts && calls[0].opts.shell === false, "PW-T7 shell:false");
    const sent = JSON.parse(calls[0].getPayload());
    ok(sent.schema_version === 1, "PW-T7 envelope versao 1");
    ok(sent.request.session_id === "ses-root-1", "PW-T7 sessao do HOST no stdin");
    ok(
      !Object.keys(sent.request).some((k: string) => k !== "session_id" && /session/i.test(k)),
      "PW-T7 sem eco de sessao do modelo",
    );
    const sentKeys = Object.keys(sent.request).filter((k: string) => k !== "session_id").sort();
    const wantKeys = ["branch", "cursor", "deadline_utc", "expected_head_sha", "goal_id", "pr_number", "repository", "required_checks", "review_expectation", "retry_budget_max", "run_id", "task_id"].sort();
    ok(
      sentKeys.length === wantKeys.length && wantKeys.every((k) => sentKeys.indexOf(k) !== -1),
      "PW-T7 payload tem exatamente os campos seguros",
      sentKeys.join(","),
    );
    for (const k of ["owner", "ownership_generation", "lease_owner", "lease_expires_utc", "goal_store_dir", "tasks_dir", "waits_dir", "flags_path", "repo_root"]) {
      ok(!Object.prototype.hasOwnProperty.call(sent.request, k), "PW-T7 sem campo proibido no stdin: " + k, k);
    }
  }
  if (out !== null) {
    const text = out?.content?.[0]?.text ?? "";
    const back = JSON.parse(text);
    ok(back.ok === true && back.run_id === "run-1", "PW-T7 resultado do bridge superficiado");
    ok(back.grants_authority === false && back.done_approved === false, "PW-T7 pins de autoridade falsos");
  } else {
    ok(false, "PW-T7 resultado do bridge superficiado", "sem output");
  }
}

// PW-T8: schema exacto — so campos seguros; sem paths de storage, sem
// owner/generation/lease_owner/lease_expires; required exacto; additionalProperties false.
{
  const t = pwT.inputSchema;
  ok(!!t && t.type === "object", "PW-T8 inputSchema e object");
  if (!!t) {
    const props = Object.keys(t.properties || {});
    ok(
      props.length === PW_SAFE_KEYS.length && PW_SAFE_KEYS.every((k) => props.indexOf(k) !== -1),
      "PW-T8 properties sao exatamente os campos seguros",
      props.join(","),
    );
    for (const k of PW_REMOVED_KEYS) {
      ok(props.indexOf(k) === -1, "PW-T8 schema sem campo proibido: " + k, k);
    }
    const req = (t.required || []) as Array<string>;
    const wantReq = [
      "task_id", "goal_id", "repository", "pr_number", "branch",
      "expected_head_sha", "deadline_utc", "retry_budget_max",
    ];
    ok(
      req.length === wantReq.length && wantReq.every((k) => req.indexOf(k) !== -1),
      "PW-T8 required exacto (sem auth/paths)",
      req.join(","),
    );
    ok(t.additionalProperties === false, "PW-T8 additionalProperties false");
  }
}

// PW-T9: chaves de storage/autoridade e chaves desconhecidas sao recusadas
// antes de qualquer spawn (allowlist explicita em runtime).
{
  const badList: Array<{ label: string; args: any; reason: RegExp }> = [];
  for (const k of PW_REMOVED_KEYS) {
    const a = pwValidArgs();
    (a as any)[k] = "x";
    badList.push({ label: k, args: a, reason: /planner-wait-args-unknown-field/ });
  }
  const unknownArgs = pwValidArgs() as any;
  unknownArgs["foo"] = 1;
  badList.push({ label: "foo", args: unknownArgs, reason: /planner-wait-args-unknown-field/ });
  // Lease-expiry model-supplied (later/earlier) nunca atravessa: rejeitado
  // como unknown-field, sem spawn, mesmo com ISO valido.
  for (const probe of ["2099-01-01T00:00:00Z", "2000-01-01T00:00:00Z"]) {
    const a = pwValidArgs();
    (a as any)["lease_expires_utc"] = probe;
    badList.push({ label: "lease_expires_utc:" + probe, args: a, reason: /planner-wait-args-unknown-field/ });
  }
  for (const b of badList) {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => pwRootSession("ses-root-1"),
      },
    );
    let reason = "";
    try {
      await handler(b.args, pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(b.reason.test(reason), "PW-T9 chave proibida recusada: " + b.label, reason);
    ok(calls.length === 0, "PW-T9 sem spawn para chave proibida: " + b.label);
  }
}

// PW-T10: sem session.get do host => proveniencia indisponivel, sem spawn.
{
  const calls: Array<any> = [];
  const handler = pwT.makeExecute(
    { bridge: "B", shell: "S", timeoutMs: 1000 },
    { spawnFn: pwStubSpawn(calls, () => {}) },
  );
  let reason = "";
  try {
    await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
  } catch (e) {
    reason = String((e as Error)?.message ?? e);
  }
  ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T10 sem session.get nega", reason);
  ok(calls.length === 0, "PW-T10 sem session.get: sem spawn");
}

// PW-T11: validador de fixture via seam (lstatSync real no adapter):
// symlink em bridge ou shell nega; ausente/nao-arquivo/oversized nega.
{
  ok(typeof pwT.checkFixture === "function", "PW-T11 seam checkFixture exportado");
  if (typeof pwT.checkFixture === "function") {
    const goodStat = () => ({ isSymbolicLink: () => false, isFile: () => true, size: 100 });
    const symStat = () => ({ isSymbolicLink: () => true, isFile: () => true, size: 100 });
    const dirStat = () => ({ isSymbolicLink: () => false, isFile: () => false, size: 100 });
    const bigStat = () => ({ isSymbolicLink: () => false, isFile: () => true, size: 70000 });
    const throwing = () => { throw new Error("ENOENT"); };
    const rOk = pwT.checkFixture(goodStat, "/abs/bridge.ps1", "/abs/pwsh");
    ok(!!rOk && (rOk as any).ok === true, "PW-T11 fixture valida passa");
    const rSymBridge = pwT.checkFixture(symStat, "/abs/bridge.ps1", "/abs/pwsh");
    ok(!(rSymBridge as any).ok, "PW-T11 symlink no bridge nega");
    const rSymShell = pwT.checkFixture(goodStat, "/abs/bridge.ps1", "/abs/pwsh", symStat);
    ok(!(rSymShell as any).ok, "PW-T11 symlink no shell nega");
    const rMissing = pwT.checkFixture(throwing, "/abs/bridge.ps1", "/abs/pwsh");
    ok(!(rMissing as any).ok, "PW-T11 ausente nega");
    const rDir = pwT.checkFixture(dirStat, "/abs/bridge.ps1", "/abs/pwsh");
    ok(!(rDir as any).ok, "PW-T11 diretorio nega");
    const rBig = pwT.checkFixture(bigStat, "/abs/bridge.ps1", "/abs/pwsh");
    ok(!(rBig as any).ok, "PW-T11 oversized nega");
  }
}

// PW-T12 (PR181-A-TOOLCONTEXT-STRICT): ToolContext estrito — SOMENTE os
// campos do contrato typechecked na pin atual; shape de runtime observada somente em 2.0.23 (sessionID/agent, ao
// lado de messageID/id; execute(input, context) fornecido pelo host,
// separado dos args do modelo). Alias (sessionId/session_id/agentName/
// agent_name) NAO sao lidos.
{
  // T12a: canonico planner funciona.
  const calls: Array<any> = [];
  const doc = {
    schema_version: 1, operation: "bind-wait", ok: true, reason: "registered",
    run_id: "run-1", revision: 3, binding: "bound", wait_reused: false,
    wait_file: "w", dedup_key: "d", task_mutated: true,
    grants_authority: false, done_approved: false,
  };
  const handler = pwT.makeExecute(
    { bridge: "B", shell: "S", timeoutMs: 1000 },
    {
      spawnFn: pwStubSpawn(calls, ({ child, stdout }) => {
        stdout.emit("data", JSON.stringify(doc));
        child.emit("close", 0);
      }),
      sessionGet: async () => pwRootSession("ses-root-1"),
    },
  );
  let out: any = null;
  let reason = "";
  try {
    out = await handler(pwValidArgs(), { sessionID: "ses-root-1", agent: "build", messageID: "m", id: "c" });
  } catch (e) {
    reason = String((e as Error)?.message ?? e);
  }
  ok(out !== null && reason === "", "PW-T12a canonico sessionID/agent executa", reason);
  ok(calls.length === 1, "PW-T12a canonico chega ao spawn");
  // T12b: somente-alias nega sem spawn.
  for (const aliasCtx of [
    { sessionId: "ses-root-1", agent: "build", messageID: "m", id: "c" },
    { session_id: "ses-root-1", agent_name: "build", messageID: "m", id: "c" },
    { sessionId: "ses-root-1", agentName: "build", messageID: "m", id: "c" },
  ]) {
    const c2: Array<any> = [];
    const h2 = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(c2, ({ child, stdout }: any) => {
          stdout.emit("data", JSON.stringify(doc));
          child.emit("close", 0);
        }),
        sessionGet: async () => pwRootSession("ses-root-1"),
      },
    );
    let r2 = "";
    try {
      await h2(pwValidArgs(), aliasCtx);
    } catch (e) {
      r2 = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-context-unknown/.test(r2), "PW-T12b somente-alias nega", r2 + " :: " + JSON.stringify(Object.keys(aliasCtx)));
    ok(c2.length === 0, "PW-T12b somente-alias sem spawn");
  }
  // T12c: worker canonico + alias forjado de planner continua negado
  // como worker (alias ignorado, sem escalacao).
  {
    const c3: Array<any> = [];
    const h3 = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(c3, () => {}),
        sessionGet: async () => pwRootSession("ses-w-1"),
      },
    );
    let r3 = "";
    try {
      await h3(pwValidArgs(), { sessionID: "ses-w-1", agent: "coder", agentName: "build", messageID: "m", id: "c" });
    } catch (e) {
      r3 = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-worker-denied/.test(r3), "PW-T12c worker canonico + alias forjado ainda nega", r3);
    ok(c3.length === 0, "PW-T12c worker forjado sem spawn");
  }
}

// PW-T13 (ETAPA6D exact-pin): o adapter V2 invoca o host session.get com o
// objeto exato {sessionID} (nunca string bare) e a proveniencia aceita o
// SessionInfo direto com fixture baseada na observação 2.0.23; isto não prova shape em 2.2.6. Prova via setup real: session fake
// registra o arg bruto; execute passa da proveniencia (raiz completa) e
// chega ao bridge (stub nay? aqui o spawn real falha fail-closed como
// bridge-refused — o ponto e que NAO e provenance-* e o arg e objeto).
{
  const saved = savePwEnv();
  const fx = makePwBridgeFixture();
  const seen: Array<any> = [];
  let tool: any = null;
  let cleanup: any = null;
  try {
    clearPwEnv();
    process.env.OPENCODE_PLANNER_WAIT_ENABLED = "1";
    process.env.OPENCODE_PLANNER_WAIT_BRIDGE = fx.bridge;
    process.env.OPENCODE_PLANNER_WAIT_SHELL = process.execPath;
    process.env.OPENCODE_PLANNER_WAIT_TIMEOUT_MS = "5000";
    tool = makePwToolSurface();
    const sess = makePwSessionSurface(pwRootSession("ses-root-1"), seen);
    try {
      cleanup = await V2Plugin.setup({ event: makeEventStream(), session: sess, tool });
    } catch {
      cleanup = null;
    }
    ok(tool.added.length === 1, "PW-T13 adapter registra tool para prova de arg", `added=${tool.added.length}`);
    if (tool.added.length === 1) {
      let reason = "";
      try {
        await tool.added[0].execute(pwValidArgs(), pwPlannerContext("ses-root-1"));
      } catch (e) {
        reason = String((e as Error)?.message ?? e);
      }
      ok(seen.length === 1, "PW-T13 session.get chamado exatamente 1x", `seen=${seen.length}`);
      if (seen.length === 1) {
        const arg = seen[0] as any;
        const isObj = !!arg && typeof arg === "object" && !Array.isArray(arg);
        ok(isObj, "PW-T13 session.get recebe objeto (nunca string bare)", String(typeof arg));
        const keys = isObj ? Object.keys(arg).sort() : [];
        ok(keys.length === 1 && keys[0] === "sessionID", "PW-T13 arg exato {sessionID}", JSON.stringify(keys));
        ok(isObj && (arg as any).sessionID === "ses-root-1", "PW-T13 sessionID do HOST repassado", JSON.stringify(arg));
      } else {
        ok(false, "PW-T13 session.get recebe objeto (nunca string bare)", "sem chamada");
        ok(false, "PW-T13 arg exato {sessionID}", "sem chamada");
        ok(false, "PW-T13 sessionID do HOST repassado", "sem chamada");
      }
      // Raiz completa passa da proveniencia: o erro (se houver) nunca e
      // provenance-*/not-root/mismatch — e bridge-* (fixture dummy real).
      ok(
        reason === "" || (/planner-wait-bridge-/.test(reason) && !/planner-wait-provenance-|planner-wait-not-root|planner-wait-provenance-mismatch/.test(reason)),
        "PW-T13 raiz direta passa da proveniencia (so bridge pode falhar)",
        reason,
      );
    }
  } finally {
    restorePwEnv(saved);
    try {
      if (typeof cleanup === "function") (cleanup as () => void)();
    } catch {
      // Fail-open no mock.
    }
    try {
      const { rmSync } = await import("node:fs");
      rmSync(fx.dir, { recursive: true, force: true });
    } catch {
      // Fail-open no mock.
    }
  }
}

// PW-T14 (ETAPA6D fail-closed): incompleto/ausente/ambiguo nega como
// provenance-unavailable (ou mismatch), SEMPRE antes de qualquer spawn.
// Cobre: null, {}, wrapper legado truncado {info:{id}}, {id} nu sem
// projectID/time, parentID numerico (malformado), id mismatch e ids
// ambiguos (dois valores distintos).
{
  const cases: Array<{ label: string; doc: any; reason: RegExp }> = [
    { label: "null", doc: null, reason: /planner-wait-provenance-unavailable/ },
    { label: "vazio {}", doc: {}, reason: /planner-wait-provenance-unavailable/ },
    { label: "wrapper legado {info:{id}}", doc: { info: { id: "ses-root-1" } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "bare {id} sem projectID/time", doc: { id: "ses-root-1" }, reason: /planner-wait-provenance-unavailable/ },
    { label: "parentID numerico (malformado)", doc: { id: "ses-root-1", parentID: 123, projectID: "proj-1", time: {} }, reason: /planner-wait-provenance-unavailable/ },
    { label: "id mismatch", doc: pwRootSession("ses-other-9"), reason: /planner-wait-provenance-mismatch/ },
    { label: "ids ambiguos", doc: { id: "ses-root-1", sessionID: "ses-other-9", projectID: "proj-1", time: {} }, reason: /planner-wait-provenance-unavailable/ },
    { label: "sem projectID", doc: { id: "ses-root-1", time: {} }, reason: /planner-wait-provenance-unavailable/ },
    { label: "sem time", doc: { id: "ses-root-1", projectID: "proj-1" }, reason: /planner-wait-provenance-unavailable/ },
  ];
  for (const tc of cases) {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => tc.doc },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(tc.reason.test(reason), "PW-T14 incompleto/ambiguo nega: " + tc.label, reason);
    ok(calls.length === 0, "PW-T14 sem spawn para: " + tc.label);
  }
}

// PW-T15 (ETAPA6D unwrap): envelope {data: SessionInfo} (transporte cru)
// resolve como o direto; filho via {data} nega not-root; conflito
// direto-vs-data nega unavailable — tudo antes do spawn (exceto o raiz
// via {data}, que chega ao bridge stubado com sucesso).
{
  const doc = {
    schema_version: 1, operation: "bind-wait", ok: true, reason: "registered",
    run_id: "run-1", revision: 3, binding: "bound", wait_reused: false,
    wait_file: "w", dedup_key: "d", task_mutated: true,
    grants_authority: false, done_approved: false,
  };
  // T15a: {data: root} chega ao bridge (unwrap ok).
  {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, ({ child, stdout }) => {
          stdout.emit("data", JSON.stringify(doc));
          child.emit("close", 0);
        }),
        sessionGet: async () => ({ data: pwRootSession("ses-root-1") }),
      },
    );
    let out: any = null;
    let reason = "";
    try {
      out = await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(out !== null && reason === "", "PW-T15a {data:root} aceita (unwrap)", reason);
    ok(calls.length === 1, "PW-T15a {data:root} chega ao spawn");
  }
  // T15b: {data: child} nega not-root sem spawn.
  {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => ({ data: pwChildSession("ses-child-9", "ses-root-1") }),
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), { sessionID: "ses-child-9", agent: "build", messageID: "m", id: "c" });
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-not-root/.test(reason), "PW-T15b {data:child} nega not-root", reason);
    ok(calls.length === 0, "PW-T15b {data:child} sem spawn");
  }
  // T15c: conflito direto-vs-data nega unavailable sem spawn.
  {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => ({ id: "ses-root-1", data: pwRootSession("ses-other-9") }),
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T15c conflito direto-vs-data nega", reason);
    ok(calls.length === 0, "PW-T15c conflito sem spawn");
  }
}

// PW-T16 (reviewer MEDIUM follow-up): envelope `{data}` e autoritativo —
// sem fallback para o outer. (a) outer raiz completa + inner filho SEM id
// nega unavailable; (b) outer `id` == raiz + outer `sessionID` conflitante
// + inner id == raiz nega unavailable (alias ignorado antes); (c) outer
// parent malformado com inner raiz nega unavailable; (d) outer parent
// nao-vazio com inner raiz nega not-root. Tudo antes de qualquer spawn.
{
  // T16a: outer raiz completa + inner filho sem id => unavailable (inner
  // precisa carregar o id; outer nunca e fallback).
  {
    const calls: Array<any> = [];
    const outer = pwRootSession("ses-root-1");
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => ({ ...outer, data: { parentID: "ses-root-1", projectID: "proj-1", time: { created: 1, updated: 2 } } }),
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T16a outer raiz + data filho sem id nega", reason);
    ok(calls.length === 0, "PW-T16a sem spawn");
  }
  // T16b: outer id == host + outer sessionID conflitante + inner id == host
  // => unavailable (alias externo conflitante nao pode ser ignorado).
  {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => ({ id: "ses-root-1", sessionID: "ses-other-9", data: pwRootSession("ses-root-1") }),
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T16b outer sessionID conflitante nega", reason);
    ok(calls.length === 0, "PW-T16b sem spawn");
  }
  // T16c: outer parent malformado (numerico) + inner raiz => unavailable.
  {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => ({ data: pwRootSession("ses-root-1"), parentID: 123 }),
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T16c outer parent malformado nega", reason);
    ok(calls.length === 0, "PW-T16c sem spawn");
  }
  // T16d: outer parent nao-vazio (string) + inner raiz => not-root
  // (parent inspecionado em AMBOS os escopos).
  {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => ({ data: pwRootSession("ses-child-9"), parentID: "ses-root-1" }),
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), { sessionID: "ses-child-9", agent: "build", messageID: "m", id: "c" });
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-not-root/.test(reason), "PW-T16d outer parent nao-vazio nega not-root", reason);
    ok(calls.length === 0, "PW-T16d sem spawn");
  }
  // T16e (security MEDIUM edge): outer raiz completa + own data:null =>
  // unavailable (own `data` presence e envelope claim; sem fallback).
  {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => ({ ...pwRootSession("ses-root-1"), data: null }),
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T16e outer raiz + data:null nega", reason);
    ok(calls.length === 0, "PW-T16e sem spawn");
  }
  // T16f (security MEDIUM edge): outer raiz completa + own data:undefined =>
  // unavailable (mesma regra fail-closed do T16e).
  {
    const calls: Array<any> = [];
    const docWithUndefined: any = { ...pwRootSession("ses-root-1"), data: undefined };
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      {
        spawnFn: pwStubSpawn(calls, () => {}),
        sessionGet: async () => docWithUndefined,
      },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T16f outer raiz + data:undefined nega", reason);
    ok(calls.length === 0, "PW-T16f sem spawn");
  }
}

// PW-T17 (debugger pinned-schema): cada required key de Session.Info
// (id/projectID/cost/tokens/time/location) como OWN property com tipos do
// pin; herdados nao contam. parentID opt: raiz OMITE a chave; own
// null/undefined/empty/malformado => unavailable; nao-vazio valido =>
// not-root (ja coberto em T6/T15b/T16d).
{
  const fullRoot = (): any => pwRootSession("ses-root-1");
  const without = (k: string): any => {
    const o: any = fullRoot();
    delete o[k];
    return o;
  };
  const cases: Array<{ label: string; doc: any; ctx?: any; reason: RegExp }> = [
    { label: "sem id", doc: without("id"), reason: /planner-wait-provenance-unavailable/ },
    { label: "sem projectID", doc: without("projectID"), reason: /planner-wait-provenance-unavailable/ },
    { label: "sem cost", doc: without("cost"), reason: /planner-wait-provenance-unavailable/ },
    { label: "sem tokens", doc: without("tokens"), reason: /planner-wait-provenance-unavailable/ },
    { label: "sem time", doc: without("time"), reason: /planner-wait-provenance-unavailable/ },
    { label: "sem location", doc: without("location"), reason: /planner-wait-provenance-unavailable/ },
    { label: "id fora do padrao ^ses", doc: { ...fullRoot(), id: "xxx-1" }, ctx: { sessionID: "xxx-1", agent: "build", messageID: "m", id: "c" }, reason: /planner-wait-provenance-unavailable/ },
    { label: "cost nao-numerico", doc: { ...fullRoot(), cost: "0" }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens nao-objeto", doc: { ...fullRoot(), tokens: [] }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens vazio {}", doc: { ...fullRoot(), tokens: {} }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens sem input", doc: { ...fullRoot(), tokens: { output: 0, reasoning: 0, cache: { read: 0, write: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens sem output", doc: { ...fullRoot(), tokens: { input: 0, reasoning: 0, cache: { read: 0, write: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens sem reasoning", doc: { ...fullRoot(), tokens: { input: 0, output: 0, cache: { read: 0, write: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens sem cache", doc: { ...fullRoot(), tokens: { input: 0, output: 0, reasoning: 0 } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens.cache sem read", doc: { ...fullRoot(), tokens: { input: 0, output: 0, reasoning: 0, cache: { write: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens.cache sem write", doc: { ...fullRoot(), tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens.input nao-numerico", doc: { ...fullRoot(), tokens: { input: "0", output: 0, reasoning: 0, cache: { read: 0, write: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens.cache.read nao-numerico", doc: { ...fullRoot(), tokens: { input: 0, output: 0, reasoning: 0, cache: { read: "0", write: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens.input herdado", doc: { ...fullRoot(), tokens: Object.assign(Object.create({ input: 0 }), { output: 0, reasoning: 0, cache: { read: 0, write: 0 } }) }, reason: /planner-wait-provenance-unavailable/ },
    { label: "tokens.cache herdado", doc: { ...fullRoot(), tokens: Object.assign(Object.create({ cache: { read: 0, write: 0 } }), { input: 0, output: 0, reasoning: 0 }) }, reason: /planner-wait-provenance-unavailable/ },
    { label: "time sem created", doc: { ...fullRoot(), time: { updated: 2 } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "time.created nao-numerico", doc: { ...fullRoot(), time: { created: "1", updated: 2 } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "location sem directory", doc: { ...fullRoot(), location: {} }, reason: /planner-wait-provenance-unavailable/ },
    { label: "location.directory vazio", doc: { ...fullRoot(), location: { directory: "" } }, reason: /planner-wait-provenance-unavailable/ },
    { label: "{data} inner sem cost", doc: { data: without("cost") }, reason: /planner-wait-provenance-unavailable/ },
    { label: "{data} inner sem location", doc: { data: without("location") }, reason: /planner-wait-provenance-unavailable/ },
    { label: "{data} inner tokens sem cache", doc: { data: { ...without("tokens"), tokens: { input: 0, output: 0, reasoning: 0 } } }, reason: /planner-wait-provenance-unavailable/ },
  ];
  for (const tc of cases) {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => tc.doc },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), tc.ctx ?? pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(tc.reason.test(reason), "PW-T17 required ausente/invalido nega: " + tc.label, reason);
    ok(calls.length === 0, "PW-T17 sem spawn: " + tc.label);
  }
  // Herdados nao contam como own: cada caso nega unavailable sem spawn.
  const inheritedCases: Array<{ label: string; doc: any }> = [
    {
      label: "projectID herdado",
      doc: Object.assign(Object.create({ projectID: "proj-1" }), {
        id: "ses-root-1", cost: 0, tokens: { input: 0 },
        location: { directory: "/repo" }, time: { created: 1, updated: 2 },
      }),
    },
    {
      label: "time herdado",
      doc: Object.assign(Object.create({ time: { created: 1, updated: 2 } }), {
        id: "ses-root-1", projectID: "proj-1", cost: 0,
        tokens: { input: 0 }, location: { directory: "/repo" },
      }),
    },
    {
      label: "cost herdado",
      doc: Object.assign(Object.create({ cost: 0 }), {
        id: "ses-root-1", projectID: "proj-1", tokens: { input: 0 },
        location: { directory: "/repo" }, time: { created: 1, updated: 2 },
      }),
    },
    {
      label: "location.directory herdado",
      doc: { ...fullRoot(), location: Object.create({ directory: "/repo" }) },
    },
    {
      label: "time.created herdado",
      doc: { ...fullRoot(), time: Object.create({ created: 1, updated: 2 }) },
    },
  ];
  for (const tc of inheritedCases) {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => tc.doc },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T17 herdado nega: " + tc.label, reason);
    ok(calls.length === 0, "PW-T17 herdado sem spawn: " + tc.label);
  }
  // parentID opt: own null/undefined/"" recusa unavailable (raiz so passa
  // com a chave AUSENTE — PW-T7/T12a/T13 provam o caminho positivo).
  for (const pv of [null, undefined, ""] as Array<any>) {
    const calls: Array<any> = [];
    const doc: any = { ...fullRoot(), parentID: pv };
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => doc },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    const tag = pv === null ? "null" : pv === undefined ? "undefined" : "vazio";
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T17 parentID " + tag + " nega unavailable", reason);
    ok(calls.length === 0, "PW-T17 parentID " + tag + " sem spawn");
  }
}

// PW-T18 (reviewer MEDIUM): own ID-alias com null/undefined nao pode ser
// ignorado — raiz completa + `sessionID:null` ou own `session_id:undefined`
// e ambiguo/unavailable, no caminho direto e em ambos os escopos outer e
// nested `{data}`. Inclui conflito entre escopos.
{
  const fullRoot = (): any => pwRootSession("ses-root-1");
  const cases: Array<{ label: string; doc: any; ctx?: any }> = [
    { label: "direto sessionID:null", doc: { ...fullRoot(), sessionID: null } },
    { label: "direto session_id:undefined", doc: { ...fullRoot(), session_id: undefined } },
    {
      label: "outer sessionID:null + inner raiz",
      doc: { ...fullRoot(), sessionID: null, data: pwRootSession("ses-root-1") },
    },
    {
      label: "outer raiz + inner session_id:undefined",
      doc: { ...fullRoot(), data: { ...pwRootSession("ses-root-1"), session_id: undefined } },
    },
    {
      label: "outer sessionId:null + inner raiz (conflito entre escopos)",
      doc: { ...fullRoot(), sessionId: null, data: pwRootSession("ses-root-1") },
    },
  ];
  for (const tc of cases) {
    const calls: Array<any> = [];
    const handler = pwT.makeExecute(
      { bridge: "B", shell: "S", timeoutMs: 1000 },
      { spawnFn: pwStubSpawn(calls, () => {}), sessionGet: async () => tc.doc },
    );
    let reason = "";
    try {
      await handler(pwValidArgs(), tc.ctx ?? pwPlannerContext("ses-root-1"));
    } catch (e) {
      reason = String((e as Error)?.message ?? e);
    }
    ok(/planner-wait-provenance-unavailable/.test(reason), "PW-T18 alias null/undefined nega: " + tc.label, reason);
    ok(calls.length === 0, "PW-T18 sem spawn: " + tc.label);
  }
}

console.log(`SUMMARY pass=${pass} fail=${fail}`);}

console.log(`SUMMARY pass=${pass} fail=${fail}`);
process.exit(fail > 0 ? 1 : 0);