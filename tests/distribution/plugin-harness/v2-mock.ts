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
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
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

console.log(`SUMMARY pass=${pass} fail=${fail}`);
process.exit(fail > 0 ? 1 : 0);
