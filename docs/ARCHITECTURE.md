# Arquitetura

Fonte canônica da política: `source/global/AGENTS.md` (global) +
`source/adapters/opencode.md` (runtime). Este documento resume; em caso de
divergência, o `source/` vence.

## Visão geral

```
                    ┌─────────────────────────┐
                    │   Planner `build`       │  único control plane;
                    │   (modelo da sessão)    │  decide, decompõe, integra
                    └────────────┬────────────┘
                                 │ preflight obrigatório
                    ┌────────────┴────────────┐
                    │  TRIVIAL_DIRECT /       │
                    │  DELEGATED /            │
                    │  DETERMINISTIC_FALLBACK │
                    │  / BLOCKED              │
                    └────────────┬────────────┘
              ┌────────┬─────────┴──────────┬──────────┐
              │        │                    │          │
     ┌────────┴───┐ ┌──┴───────┐ ┌───────────┴──┐ ┌───┴────────┐
     │ CHEAP pool │ │ STRONG   │ │ PLANNING     │ │ DIAGNOSTIC │
     │ (execução) │ │ pool     │ │ (advisory,   │ │ (validam,  │
     │            │ │ (juízo)  │ │ read-only)   │ │ não editam)│
     └────────────┘ └──────────┘ └──────────────┘ └────────────┘
                                 │ enforcement por sessão
                    ┌────────────┴────────────┐
                    │ plugins/                │
                    │ orchestration-          │  mandato + telemetria
                    │ enforcement.ts          │  sanitizada local
                    └─────────────────────────┘
```

O Planner mantém no próprio contexto só objetivo, plano, decisões, estado
e critérios de aceite. Buscas extensas, logs e hipóteses descartadas ficam
nos contextos dos workers. Workers nunca criam subagentes
(`subagent_depth: 1` + `permission.task: deny`).

## Planner único + pools

O Planner `build` é o único control plane: decide arquitetura, decompõe,
seleciona o menor conjunto útil, define ownership, integra evidências e
encerra. `coder` é o implementador padrão; especialistas de domínio só com
profundidade, risco, workstream independente ou paralelização segura.

**Cheap pool** (`{{MODEL_CHEAP}}`, escala horizontal — evidência e volume),
11 workers de execução:

`explorer`, `researcher`, `coder`, `tester`, `docs-manager`,
`frontend-engineer`, `backend-engineer`, `database-engineer`,
`ai-agent-engineer`, `automation-engineer`, `infra-engineer`.

**Strong pool** (`{{MODEL_STRONG}}`, escala vertical — decisões difíceis),
4 workers de juízo:

`reviewer`, `debugger`, `security-reviewer`, `architect`.

**Planning layer** (advisory, read-only, `permission.task: deny`), 4 papéis:

`requirements-analyst`, `engineering-advisor`, `product-designer`,
`skeptic` — no máximo 1 por subtarefa, sem rito obrigatório.

Total: 11 + 4 + 4 = **19 workers delegáveis** (`source/agents/*.md`).
No `templates/opencode.json.tmpl`, 15 têm bloco `agent.*`; os 4 de planning
vivem só nos `.md` + allowlist do `build` (by design — ver check 3 de
`scripts/test-package-consistency.ps1`). `agent.build.model` nunca existe:
o Planner herda o modelo da sessão.

## Mandatory Preflight (4 estados)

Toda tarefa passa pelo preflight **antes** da primeira ação
(`scripts/v3/orchestration-preflight.ps1`, lib em `scripts/v3/lib/`):

| Estado | Significado |
|---|---|
| `TRIVIAL_DIRECT` | Só com reason token fechado (`DIRECT_TRIVIAL_LOCALIZED`, `DIRECT_READ_ONLY_POINT_LOOKUP`, `DIRECT_COSMETIC_NO_LOGIC`, `DIRECT_FORMATTING_ONLY`). Texto livre não é bypass válido. |
| `DELEGATED` | Pré-decisão que planeja (`UNVERIFIED_POST_EXECUTION_REQUIRED`); compliance só no DONE gate. |
| `DETERMINISTIC_FALLBACK` | Router/registry indisponível, stale, exceção, timeout ou resposta malformada — nunca execução solitária. |
| `BLOCKED` | Não prosseguir; devolver ao usuário. |

Tarefa não trivial exige participação material de ao menos 1 subagent
adequado. `non-trivial + participação = 0` produz
`ORCHESTRATION_POLICY_BYPASS`: sem `DONE` compliant.

## DONE gate

`DONE` = requisitos atendidos, critérios verificados, comportamento
validado, checks executados, integração verificada, findings resolvidos ou
conscientemente aceitos, review encerrado, riscos residuais conhecidos,
nenhuma unidade essencial esquecida. Atestação via participação observada
(`Test-OrchestrationDoneCompliance`); mensagem de sucesso de worker nunca é
prova. Ciclo padrão: `coder → tester → reviewer` (+ `security-reviewer`
quando a policy disparar). Após 2 tentativas sem êxito: `debugger` com
evidência nova; se incerteza estrutural, `architect`. 3ª tentativa só com
hipótese, informação ou estratégia nova.

## Wave + Barrier

`DISPATCH WAVE` → workers independentes → aguardar resultados necessários
→ `BARRIER` → uma síntese do Planner → próxima decisão. Limites padrão:
até 3 cheap simultâneos (burst 4 se genuinamente independentes); até 2
Coders só com ownership explícita de arquivos diferentes; até 3 Testers sem
fixtures/portas/banco compartilhados incompatíveis; 1 strong por decisão
(exceção: Reviewer + Security Reviewer read-only em paralelo).
Discovery (Explorer/Researcher) é o melhor candidato a fan-out, dividido
por domínios reais.

## Dispatch Contract

Toda delegação não trivial carrega: `TASK_ID`, `OBJECTIVE`,
`DEPENDENCIES`, `BASE_REVISION` (quando Git concorrente importar),
`READ_SCOPE`, `WRITE_SCOPE` (vazio para read-only),
`ACCEPTANCE_CRITERIA`, `VALIDATION`, `PROHIBITED_OPERATIONS`,
`RETURN_FORMAT`, `ESCALATION_CONDITIONS`. Com escrita ou shell sensível,
inclua `ALLOWED_ENVIRONMENT`, `PRODUCTION_AUTHORIZED` (ausência = `false`;
`true` sozinho não autoriza destruição nem credenciais) e
`CREDENTIAL_SCOPE` (só identificadores/perfis, nunca segredos). O worker
não amplia esses campos por inferência; diante do não coberto, interrompe
e devolve ao Planner. Retorno compacto (`TASK_ID`, `STATUS`,
`KEY_FINDINGS`, `EVIDENCE`, `VALIDATION`, `BLOCKERS`, `RISKS`,
`RECOMMENDATION`); Reviewer termina `APPROVED`/`CHANGES_REQUIRED`, Tester
`PASS`/`FAIL`.

## V3 (router, registry, flags)

- **Router shadow/off por padrão**: `source/registry/capability-flags.json`
  tem `capability_router.shadow=false`, `active=false`,
  `skill_routing`/`mcp_routing`/`adaptive_ranking=false`. A política
  determinística decide; o Router (`scripts/v3/route-accept.ps1`,
  `scripts/v3/shadow-route.ps1`, bridge `scripts/v3/skill-bridge.ps1`) só
  observa/propõe como **dado**, nunca como instrução — sem autoridade,
  sem carregar skills, sem habilitar MCPs.
- **Registry distribuída**: `source/registry/` (`capability-flags.json`,
  `capability-policy.json`, `runtimes.json`) — curada, versionada, parseável.
  Trust/risco vêm **exclusivamente** da policy; frontmatter contribui só
  descrição/capacidades candidatas.
- **`build-capability-registry` → cache opt-in**:
  `scripts/v3/build-capability-registry.ps1` faz probe de
  `source/agents/*.md` + policy e escreve `cache/v3/capability-registry.json`
  (ignorado pelo git). Sem registry gerada, o sistema usa fallback
  determinístico — nada quebra.
- **Safe-by-default**: toda flag de roteamento nasce `false`; ativação é
  decisão humana explícita com registro (gate-closure), nunca inferência.
- **V3 em maintenance mode**: sem V4, sem novas phases/flags/frameworks.
  Reabre só por bug observado, capability nova do runtime, telemetria
  recorrente `WRONG`/`SUBOPTIMAL`/`BYPASS`, mudança de modelo/runtime ou
  evidência que retire um HOLD/BLOCKED.

## Ownership model do installer (PACKAGE/USER)

O instalador (`install.ps1`) só gerencia o que é do pacote: bloco markered
do `AGENTS.md`, 19 `.md` de agents, plugin, skills-core e as chaves do
sistema no config (`$schema`, `model`, `default_agent`, `subagent_depth`,
`agent.*` — em `opencode.json` ou `opencode.jsonc`, respeitando a
precedência do runtime: jsonc vence quando ambos existem, igual ao
OpenCode V1). Tudo do usuário fora disso (`mcp.*`, `autoupdate`,
`skills.paths`, `plugin`, agents custom, chaves desconhecidas, conteúdo
fora dos markers) é preservado por merge estrutural — essas chaves nunca
são escritas nem removidas. `~/.opencode-orchestration/manifest.json`
registra hashes e snapshot do que foi instalado; o `uninstall.ps1` só
remove o que está intacto (hash confere) e mantém o resto com `KEEP` +
aviso. Ver [INSTALLATION.md](INSTALLATION.md).

## Permissões e shell

Classes (read-only / writer-shell / writer-no-shell / diagnostic),
barreiras (runtime / prompt / planner) e limitações declaradas do matching
`bash:` vivem em [PERMISSIONS.md](PERMISSIONS.md) — referência normativa
para tudo que envolve shell.
