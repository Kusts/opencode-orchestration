// v2-mock.ts - V31-R2 F3 harness mock V2 (local, sem rede).
// Monta um ctx fake com as superficies esperadas (event/session/tool com
// .hook), registra o setup() do adapter V2, dispara um evento de contexto
// com system array + um execute.before, e afirma: mandato v2 injetado
// (marker), telemetria escrita com runtime:v2, cleanup limpa estado.
// Tambem cobre: deteccao de superficies ausentes (fail-open + telemetria
// hooks-unavailable) e as representacoes de system do F5 (parts[], string[],
// vazio, misto). Rode com: bun run tests/distribution/plugin-harness/v2-mock.ts
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

// 1. setup com superficies completas retorna cleanup sem throw.
const ev = makeSurface();
const sess = makeSurface();
const tool = makeSurface();
let cleanup: unknown = null;
let threwSetup = false;
try {
  cleanup = await V2Plugin.setup({ event: ev, session: sess, tool });
} catch {
  threwSetup = true;
}
ok(!threwSetup && typeof cleanup === "function", "1 setup completo retorna cleanup");

// 2. lifecycle via event hook indexa sessao (worker coder).
await ev.fire("session.created", {
  event: { type: "session.created", properties: { info: { id: "v2-mock-sess-1", agent: "coder" } } },
});
ok(__orchestrationEnforcementV2Test.sessionIndexSize() === 1, "2 session.created indexa sessao");

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
    unav.some((r) => r.reason === "event.hook unavailable") &&
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

// 10. cleanup limpa estado (sessionIndex zerado) sem erro.
let threwCleanup = false;
try {
  (cleanup as () => void)();
} catch {
  threwCleanup = true;
}
ok(!threwCleanup, "10 cleanup sem throw");
ok(__orchestrationEnforcementV2Test.sessionIndexSize() === 0, "10 cleanup limpa sessionIndex");

console.log(`SUMMARY pass=${pass} fail=${fail}`);
process.exit(fail > 0 ? 1 : 0);
