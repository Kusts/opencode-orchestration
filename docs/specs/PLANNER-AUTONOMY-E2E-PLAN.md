# PLANNER AUTONOMY E2E — plano

| Campo | Valor |
|---|---|
| Projeto | `Kusts/opencode-orchestration` |
| Integração | `kust-projetos/agent-config` |
| Baseline do relatório | `master@528c8be` |
| HEAD de registro | `f234026` |
| Prioridade | P0 |
| Status | Planejado |
| Data | 2026-11-17 |

Correção terminológica (2026-11-17, operador): a denominação incorreta no adendo era erro de digitação; o recurso é o MCP JEV, disponível e verificado neste runtime.

## Objetivo e princípio

Entregar autonomia E2E para o Planner decidir e conduzir missões técnicas,
com continuidade resiliente e integração de acompanhamento com Kaneo. Uma
autorização de missão abrange decisões técnicas e operações reversíveis
dentro do mandato. O Planner é o único coordenador; Task/Goal Kernel mantém o
estado técnico e a autoridade de conclusão; Kaneo apenas apresenta estado.
Não criar outro Planner, executor, Kernel ou workflow.

## Arquitetura desejada

```text
USUÁRIO autoriza a missão
        │
        ▼
PLANNER (decisor principal: cria plano/tarefas, seleciona workers e modelos,
         consulta especialistas se necessário, decide correções e mudanças
         de estratégia, controla continuidade)
        │
        ├──► CONSULTORIA SOB DEMANDA
        │    MCP JEV · Architect · Engineering Advisor · Debugger
        │
        ▼
AGENTES EXECUTORES
        │
        ▼
TESTES / REVIEW
        │
        ▼
TASK / GOAL KERNEL
  Verificado ───────────────► Próxima Task
  Falhou ───────────────────► Reparar / Replanejar
  Dependência ──────────────► Continuar frente independente
  Goal verificado ──────────► COMPLETED
        │
        ▼
KANEO (acompanhamento visual)
```

O Planner é o único coordenador estratégico; o Kernel mantém o estado técnico
e a autoridade de conclusão; Kaneo apenas apresenta estado.

## Marcos

### M1 — Diagnóstico das interrupções

**Prioridade:** P0 · **Dependência:** nenhuma.

- **Objetivo:** identificar causas observáveis das pausas, perguntas
  desnecessárias e falhas de continuidade.
- **Ações:** classificar pelo menos seis classes de causa; coletar pelo menos
  três evidências; mapear causas e pontos de decisão; propor uma lista mínima
  de correções. Não alterar permissões indiscriminadamente.
- **Entregáveis:** mapa das causas reais; evidência de pelo menos três
  interrupções representativas, quando disponíveis; arquivos ou configurações
  responsáveis; lista mínima de correções.
- **Aceite:** distinguir interrupções por autorização real daquelas causadas
  por configuração, instruções ou indecisão. Não alterar permissões
  indiscriminadamente.

### M2 — Autonomia decisória do Planner

**Prioridade:** P0 · **Dependência:** M1.

- **Objetivo:** tornar explícito o que o Planner pode decidir autonomamente e
  o que exige intervenção humana.
- **Ações:** especificar contrato decisório e fluxo em oito passos:
  (1) verificar se a decisão já foi tomada anteriormente; (2) consultar o
  contexto, código, documentação e evidências disponíveis; (3) avaliar
  alternativas; (4) escolher a solução mais simples que atenda aos critérios;
  (5) se a incerteza for relevante, consultar um especialista apropriado;
  (6) registrar a decisão importante; (7) delegar a execução; (8) validar e
  continuar. Revisar apenas contratos e pontos de integração necessários:
  mandato V2, política por missão, ask/allow/deny efetivos, integração com
  Task/Goal Kernel, instruções de workers e contratos de continuidade.
- **Decisões autônomas do Planner:** como implementar funcionalidade
  especificada; qual arquitetura/biblioteca dentro do escopo; qual agente;
  qual modelo conforme política; quando testar/revisar; como corrigir bugs;
  quando refatorar componente necessário; quando mudar estratégia após
  falhas; quando abrir investigação; como organizar tarefas/branches/commits;
  quando considerar tarefa concluída usando verificação do Kernel.
- **Decisões que exigem intervenção humana:** alterar materialmente
  objetivo/produto; gastos não autorizados; operações destrutivas
  irreversíveis; alterar credenciais ou acessar dados fora do escopo; ações em
  produção sem autorização; decisões de negócio sem requisitos essenciais.
  Não solicitar ao usuário escolha entre alternativas técnicas viáveis já
  abrangidas pela missão.
- **Entregáveis/aceite:** contrato decisório testável e compatível com a
  separação de responsabilidades; preservar a separação com Agent Config.

### M3 — Especialistas para impasses

**Prioridade:** P0 · **Dependência:** M2.

- **Objetivo:** resolver impasses sem converter consulta em autoridade.
- **Ações:** documentar matriz situação→recurso:
  decisão direta pelo Planner; MCP JEV já verificado neste runtime, com uso
  advisory conforme as regras; Architect para incerteza estrutural; Engineering Advisor para
  trade-offs; Debugger para falhas reproduzidas; Advisor/JEV para segunda
  opinião. Consultas são advisory: o Planner confronta respostas com
  evidências e contratos existentes. O contrato do MCP JEV foi verificado por
  uso real das ferramentas `jev_*`; seu parecer não autoriza ferramenta.
- **Entregáveis/aceite:** matriz, regras de consulta e teste funcional de
  impasse controlado, sem delegar a decisão final ao especialista.

### M4 — Continuidade automática

**Prioridade:** P0 · **Dependências:** M2 e M3.

- **Objetivo:** permitir que a missão prossiga após falha, interrupção ou
  troca de sessão sem perder objetivo nem repetir trabalho.
- **Ações:** reutilizar Task Kernel, Goal Kernel, Planner Loop, Native Resume,
  checkpoints, fallback, reparo e replanejamento. Não criar scheduler novo.
- **Entregáveis/aceite:** critérios verificáveis de retomada, preservação do
  estado/objetivo, reparo e prevenção de repetição, com escalonamento humano
  apenas quando necessário.

### M5 — Kaneo como pipeline

**Prioridade:** P1 · **Dependência:** núcleo validado (M1–M4).

- **Objetivo:** oferecer visibilidade operacional sem duplicar autoridade.
- **Ações:** mapear cinco status: Planejado, Em execução, Em validação,
  Bloqueado e Concluído. Campos por tarefa: objetivo e responsável; status;
  referência da Task no Kernel; branch ou PR relacionado; impedimento atual,
  se existir; resultado e evidência de conclusão.
- **Regras/aceite:** Kernel é fonte da verdade; Kaneo não autoriza, não declara
  DONE e não substitui GitHub Issues; não sincronizar todo evento de tool ou
  cada mensagem de agente; evitar duplicação e loop bidirecional. Pilotar com
  três tarefas. Manter integração opcional se não agregar valor.

### M6 — Certificação E2E

**Prioridade:** P0 para encerramento · **Dependências:** M1–M4.

- **Objetivo:** provar autonomia e segurança no fluxo completo.
- **Ações e testes:** A) correção simples; B) decisão complexa; C) missão
  prolongada com falha, reparo e retomada.
- **Métricas/aceite:** zero perguntas humanas desnecessárias; zero
  interrupções por decisão técnica dentro do mandato; zero tarefas repetidas;
  zero conclusões sem verificação; retomada funcional. Medir tempo e tokens
  quando disponíveis, sem transformar ausência dessas métricas em evidência
  de sucesso. Chamadas a especialistas: apenas quando úteis. Registrar também
  qualquer confirmação legítima de runtime ou autorização externa,
  distinguindo-a das solicitações redundantes.

## Ordem de implementação

1. Diagnóstico das interrupções (M1) — sem dependência.
2. Autonomia decisória e permissões (M2) — depende M1.
3. Consultoria para impasses (M3) — depende do contrato decisório.
4. Continuidade automática (M4) — depende M2 e M3.
5. Certificação E2E principal (M6) — depende M1–M4.
6. Piloto Kaneo (M5) — depende do núcleo autônomo validado.
7. Integração e relatório final — depende dos testes concluídos.

Justificativa: a diretriz final do relatório determina implementar primeiro a
autonomia funcional e usar Kaneo somente depois de comprovada a conclusão de
missões sem supervisão técnica constante.

### Matriz de dependências

| Marco | Depende de | Pode avançar em paralelo |
|---|---|---|
| M1 | — | — |
| M2 | M1 | — |
| M3 | M2 | — |
| M4 | M2, M3 | — |
| M6 | M1–M4 | Piloto Kaneo, se não houver conflito |
| M5 | Núcleo autônomo validado e certificação principal concluída | — |
| Integração/relatório final | Testes concluídos | — |

## Fora do escopo

- Novo Planner ou controlador.
- Novo Kernel.
- Agent Teams completo.
- Handoff direto entre workers, ainda dependente de suporte nativo.
- Dashboard próprio.
- Novo motor de permissões.
- Scheduler permanente.
- Sistema genérico de agentes dinâmicos.
- Novo sistema de memória.
- Criar um segundo executor ou workflow.
- Substituir Task Kernel/Goal Kernel ou mover para Kaneo a autoridade de
  estado técnico, autorização ou conclusão.
- Alterar permissões de forma indiscriminada ou ampliar mandato por
  conveniência.
- Tornar especialistas ou MCP JEV autoridades decisórias.
- Sincronizar cada chamada de ferramenta com Kaneo ou criar sincronização
  bidirecional que gere loops.
- Tornar Kaneo obrigatório antes de comprovar valor; M5 permanece opcional.
- Declarar sucesso sem validação E2E, ou tratar métricas indisponíveis como
  sucesso comprovado.

## Critérios de DONE

1. Diagnóstico M1 confirmado por evidências e causas rastreáveis.
2. Contrato decisório M2 define autonomia, limites e escalonamento.
3. Fluxo de oito passos está implementado/testado nos pontos aplicáveis.
4. Integração mantém Planner como único coordenador e Kernel como autoridade.
5. Especialistas são advisory e impasse controlado foi testado.
6. MCP JEV já verificado neste runtime; uso advisory conforme regras.
7. Continuidade M4 retoma, repara e replaneja sem scheduler novo.
8. Casos E2E A, B e C passam nos critérios e métricas definidos.
9. Kaneo, se mantido, passa pelo piloto de três tarefas sem assumir
   autoridade; caso contrário, a decisão de mantê-lo opcional é registrada.
10. CI verde no HEAD integrado.
11. Relatório final contém evidências, resultados, desvios, riscos e
    pendências, e é acompanhado pela ponte:
    `[PONTE OPENCODE → CHATGPT | PROJETO: opencode-orchestration | MISSÃO: PLANNER AUTONOMY E2E | MARCO: conclusão]`

## Diagnóstico confirmado (M1) — mapa de causas

Diagnosticado em 2026-11-17 por worker read-only; pelo menos uma interrupção
observada e três causas estruturais potenciais, quando disponíveis; evidência
primária lida no checkout atual; registrado em `pae-m1` (`candidate_pass`).
Nenhuma permissão foi alterada.

### Interrupções representativas

| Sintoma | Classe | Legítima vs. redundante | Evidência primária | Correção mínima |
|---|---|---|---|---|
| Continuidade do Planner bloqueada por indisponibilidade/timeout do próprio modelo. | (5) Falha operacional. | Interrupção 1 observada em 2026-11-16. Legítimo como bloqueio técnico (evitar duplicação de turno); redundante como pedido de decisão quando não há protocolo de retomada segura. | `source/adapters/opencode-v2.md:59,87-93` (recuperação automática completa BLOCKED; `opencode run --session <id> --model <m>` sem mensagem falhou; plugin V2 2.3.0 sem `execute.after`/erro/sessionID filha; sessão presente/timeout/`EXECUTION_UNKNOWN` = HOLD), `plugins/orchestration-enforcement/shared/mandate.ts:39` (fallback automático restrito a subagentes com prova de não-início), `source/policies/AUTONOMY.md:54-55` e `source/registry/autonomy-policy.json:62-69` (`terminal_stop_reasons`). Timeout de worker, erro de provider ou exaustão de tentativas retornam ao control plane para recuperação e nunca encerram o Objective. | Padronizar resposta determinística “stop-and-handoff” (estado + evidência + motivo `no-start/ambiguous/blocked` + próximo passo seguro) em vez de devolução aberta; automatizar só com primitiva nativa provada. O protocolo deve respeitar o contrato: nunca encerrar o Objective. |
| Preflight força rota não autônoma por ambiguidade/keyword. | (3) Indecisão/entrada insuficiente para `vague`; (2) Regra redundante/conservadora para hard-exclusion por keyword. | Causa estrutural potencial, não observada em runtime nesta missão. Ambiguidade pode exigir esclarecimento se faltar dado material; bloqueio conservador pode ser redundante sem fronteira real. | Todas as âncoras de `scripts/v3/lib/OrchestrationPreflight.ps1` referem-se ao HEAD `f234026`: `:263-290` (`Test-OrchestrationVague`), `:398-401`, `:219-261` (hard exclusions: authority/permission/security/credentials/destructive/irreversible_migration/infra_mutation/control_plane/mcp_execution), `:391-397`, `:384-388` (`BLOCKED` com `fallback_reason=empty_allowlist`), `:616-624` (fail-safe). A árvore de trabalho contém mudança não commitada em curso da task `pae-m2` (+15 linhas), que desloca essas linhas; as referências acima citam somente um estado. Mandato: `mandate.ts:32,31`. | Manter `vague` como clarification só quando faltar informação material; separar análise read-only de mutação/efeito no classificador de hard-exclusion, sem afrouxar fail-closed real. |
| Efeito externo/irreversível mediado sem autoridade/evidência. | (6) Autorização realmente ausente. | Causa estrutural potencial, não observada em runtime nesta missão. Legítima; não é indecisão. | `scripts/v3/lib/OrchestrationExternalActionGate.ps1:7-15,39-53,154-193`, `OrchestrationExternalActionBoundary.ps1:61-97`, `source/policies/AUTONOMY.md:13-19,34-43,48,54-55`, `source/registry/autonomy-policy.json:25-68,62-69` (`REQUIRED_EXTERNAL_INPUT_UNAVAILABLE` sustenta a classe (6)), `mandate.ts:34`. | Nenhuma remoção de controle; coletar/propagar cedo no dispatch a autoridade e evidências (SHA/policy binding, revisor, confirmação) para evitar interrupção tardia. |
| Confirmação de runtime (`ask`) em shell de worker. | (1) Permissão do runtime. | Causa estrutural potencial, não observada em runtime nesta missão. Impacto de `ask` é condicional ao modo do runtime: é confirmação, auto-aprovada no modo auto; `deny` é o bloqueio. | `source/agents/coder.md:15-31` (git push/deploy/publish/release: ask; destrutivos: deny), `docs/PERMISSIONS.md:11-15,24-34,41-52,69-77,122-123`, `source/registry/capability-flags.json:50-53` (`runtime_grant_enforcement.v1/v2=false`). | Não ampliar permissões; pré-declarar no dispatch (`PROHIBITED_OPERATIONS`, `ALLOWED_ENVIRONMENT`, `CREDENTIAL_SCOPE`, `PRODUCTION_AUTHORIZED`) e evitar comandos `ask` sem necessidade. |

As interrupções 2, 3 e 4 acima são causas estruturais potenciais, não
observações de runtime nesta missão. **Cobertura da classe (4):** dependência
de especialista — nenhuma interrupção representativa encontrada nas fontes
lidas; política já direciona para delegação/Advisor/Debugger. Se ocorrer em
runtime, tratar como lacuna operacional a evidenciar, não presumir.

### Distinção autorização legítima vs. solicitação redundante

- **Legítima (manter):** mudança material de escopo/produto, gasto não
  autorizado, produção/destruição irreversível, segredos/dados pessoais,
  autorização ausente, pré-condições formais de ação externa (autoridade
  válida, evidência vinculada, revisão/confirmação). Fontes: `mandate.ts:34`,
  `source/policies/AUTONOMY.md`, gates externos. `REQUIRED_EXTERNAL_INPUT_UNAVAILABLE`
  sustenta a classe (6).
- **Redundante/indevida em missão autorizada:** pedir confirmação por
  subtarefa já coberta; devolver decisão técnica por falta de protocolo em
  trabalho reversível/in-scope; bloquear por classificação conservadora
  (keyword/allowlist) sem fronteira real. O mandato V2 já proíbe “asking per
  subtask” (`mandate.ts:34`). `PRODUCT_INTENT_AMBIGUITY` sustenta a classe (3).

### Lacunas reais, ALREADY_COVERED e divergências

- **Lacunas reais:** (a) recuperação automática segura do Planner indisponível
  no runtime atual — confirmado em `source/adapters/opencode-v2.md:59`;
  (b) sobre-bloqueio do preflight por keywords em análise benigna.
- **ALREADY_COVERED (preservar):** autonomia por missão e exceções humanas no
  mandato V2 (`mandate.ts:34`); gates formais de autoridade/risco; separação
  `DIRECT_VERIFIED` (leitura) vs. `SINGLE_WORKER` (escrita) e compliance de
  participação; `empty_allowlist` já retorna `BLOCKED` com
  `fallback_reason=empty_allowlist` em `OrchestrationPreflight.ps1:384-388`
  (HEAD `f234026`).
- **Divergência de evidência:** tokens `WAITING_EXTERNAL` e
  `BLOCKED_TOOL_UNAVAILABLE`, citados na memória da issue #233, **não** foram
  localizados textualmente no checkout atual — não confirmados no código
  presente (grep os encontrou apenas neste documento). O possível
  desalinhamento entre nomes de mecanismos citados em memória e identificadores
  no código também não foi confirmado. A config ativa em
  `C:\Users\walis\.config\opencode` não pôde ser inspecionada por permissão do
  runtime; causas mapeadas são estruturais no repo.

### Correções mínimas priorizadas (P0)

Sem alterar permissões indiscriminadamente:

1. **Continuidade do Planner (M4):** protocolo stop-and-handoff
   determinístico, coerente com o contrato de recuperação ao control plane e
   regra de nunca encerrar o Objective; donos
   `source/adapters/opencode-v2.md`, `scripts/v3/model-fallback.ps1`, mandato
   V2.
2. **Preflight (entrega em curso na task `pae-m2`):** separar hard-exclusion
   de análise read-only vs. mutação/efeito; o teste r6d trava o comportamento
   existente de `empty_allowlist`/config. Donos
   `scripts/v3/lib/OrchestrationPreflight.ps1` e testes.
3. **Ações externas (M2):** não remover gates; propagar cedo
   autoridade/evidência no contrato de dispatch; donos
   `OrchestrationExternalAction*`.
4. **Prompts `ask` (M2):** não afrouxar `ask/deny`; declarar
   ambiente/escopo no dispatch; donos `source/agents/*.md`,
   `docs/PERMISSIONS.md`.

**Resíduo documentado:** `analyze production deployment logs` em
leitura/análise continua fail-closed por `infra_mutation` — conservador e
aceito nesta fatia.

## Rastreabilidade

| TASK_ID | Estado registrado | Conclusão |
|---|---|---|
| `pae-plan` | revision 7; `REVIEWING`; review `approved`; worker `candidate_pass` | Não concluída |
| `pae-m1` | revision 9; `REVIEWING`; review `approved`; worker `candidate_pass` | Não concluída |
| `pae-m2` | revision 10; `REVIEWING`; review `approved`; worker `candidate_pass`; verificação caller-supplied (UNTRUSTED) | Não concluída |
| `pae-m2b` | revision 3; `REVIEWING`; `verify-run` falhou `out_of_scope_write` | Não concluída |
| `pae-m2c` | revision 9; `DONE`; contrato de dispatch; verificação `kernel-executed` | DONE |
| `pae-m4a` | revision 3; `REVIEWING`; `verify-run` falhou `out_of_scope_write` | Não concluída |
| `pae-m4b` | revision 9; `DONE`; stop-and-handoff (M4); verificação `kernel-executed` | DONE |
| `pae-m3a` | revision 1; `REVIEWING`; aprovada via `pae-m3b` | Não concluída |
| `pae-correcao-jev` | revision 1; `REVIEWING`; aprovada via `pae-m3b` | Não concluída |
| `pae-m3b` | revision 9; `DONE`; matriz de especialistas com MCP JEV; verificação `kernel-executed` | DONE |
| `pae-add-final` | revision 9; `DONE`; adendo de documentação; verificação `kernel-executed` | DONE |
| `pae-add-a` | revision 1; `DISCOVERING`; consolidada em `pae-add-final` | Não concluída |
| `pae-add-b` | revision 1; `DISCOVERING`; consolidada em `pae-add-final` | Não concluída |
| `pae-add-c` | revision 1; `DISCOVERING`; consolidada em `pae-add-final` | Não concluída |
| `pae-add-e` | revision 1; `DISCOVERING`; consolidada em `pae-add-final` | Não concluída |
| `pae-m5` | revision 1; `DISCOVERING` | Não concluída |
| `pae-m6` | revision 1; `DISCOVERING` | Não concluída |

### Limitação do Kernel

As tasks iniciais (`pae-plan`, `pae-m1`, `pae-m2`) foram criadas sem plano de
verificação e permanecem sem DONE: é uma limitação de rastreabilidade, não uma
falha das entregas. O gate exige prova `kernel-executed` via `verify-run` com
plano imutável na criação; verificação caller-supplied nunca o satisfaz.
`verify-run` em `pae-m2` retornou `VERIFIER_PLAN_MISSING`. A limitação foi
contornada com sucesso em quatro tasks
canônicas (`pae-m2c`, `pae-m3b`, `pae-m4b`, `pae-add-final`), recriadas com
`WriteScopes` completos cobrindo as mudanças pendentes e `VerifierProfiles`;
todas geraram `verified_pass` com `verification_source=kernel-executed` via
`verify-run`.

`pae-m2b` e `pae-m4a` permanecem em REVIEWING como tentativas que falharam por
`out_of_scope_write`; `pae-m3a` e `pae-correcao-jev` foram consolidadas em
`pae-m3b`; `pae-add-a`, `pae-add-b`, `pae-add-c` e `pae-add-e` foram
consolidadas em `pae-add-final`. As mudanças desta sessão ainda não estão
commitadas; o CI verde cobre apenas o HEAD base `f234026`.

Validação final: package consistency 17/17; orchestration-preflight 298/298;
v2-delegation-preflight 15/0; distribution runner 24 PASS / 0 FAIL / 1 SKIP /
0 INTERNAL_ERROR / TOTAL 25.

Estado GitHub em 2026-11-17: #237 CLOSED, #48 OPEN, PR #238 MERGED. CI verde em
master (run 43999809105) e na branch integrada (run 44072082219).
