import type { Plugin } from "@opencode-ai/plugin";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const MARKER = "[orchestration-enforcement:v1]";

const MANDATE = [
  "# Orquestração obrigatória de subagents (enforcement estrutural)",
  "",
  "Este bloco é injetado automaticamente em toda sessão do OpenCode.",
  "",
  "- Toda tarefa passa por preflight de orquestração ANTES da primeira ação. Classifique e aja: TRIVIAL_DIRECT (apenas com reason token fechado: DIRECT_TRIVIAL_LOCALIZED, DIRECT_READ_ONLY_POINT_LOOKUP, DIRECT_COSMETIC_NO_LOGIC, DIRECT_FORMATTING_ONLY), DELEGATED, DETERMINISTIC_FALLBACK ou BLOCKED.",
  "- Tarefa não trivial exige participação material de ao menos um subagent adequado (explorer, researcher, coder, tester, reviewer, debugger, architect, security-reviewer ou especialista de domínio). Executar sozinho sem decisão registrada é ORCHESTRATION_POLICY_BYPASS.",
  "- Delegue de forma autônoma, sem perguntar ao usuário se deve delegar. Use workers baratos para exploração/pesquisa/implementação/testes e workers fortes para review crítico, debugging, segurança e arquitetura.",
  "- Em mudança relevante, siga o ciclo coder → tester → reviewer e integre as sínteses (STATUS, FINDINGS, EVIDENCE, VALIDATION, RISKS). DONE exige participação observada de workers em tarefa não trivial.",
  "",
  "[orchestration-enforcement:v1]",
].join("\n");

const injected = new Set<string>();

function sessionID(input: unknown): string | undefined {
  const value = input as any;
  return value?.sessionID ?? value?.sessionId ?? value?.session_id ?? value?.info?.id;
}

export const OrchestrationEnforcement: Plugin = async () => {
  return {
    "experimental.chat.system.transform": async (input, output) => {
      try {
        const system = (output as any)?.system;
        if (!Array.isArray(system)) return;
        let hasMarker = false;
        for (const item of system) {
          if (typeof item === "string" && item.includes(MARKER)) {
            hasMarker = true;
            break;
          }
        }
        if (!hasMarker) system.push(MANDATE);
        const id = sessionID(input) ?? null;
        const key = id ?? "null";
        if (injected.has(key)) return;
        const dir = join(homedir(), ".opencode-orchestration", "evidence", "v3", "orchestration");
        mkdirSync(dir, { recursive: true });
        const line = JSON.stringify({
          ts: new Date().toISOString(),
          kind: "session_system_injection",
          session: id,
          plugin: "orchestration-enforcement",
          version: 1,
        });
        appendFileSync(join(dir, "session-injections.jsonl"), line + "\n", "utf8");
        injected.add(key);
      } catch {}
    },
  } as any;
};

export default OrchestrationEnforcement;
