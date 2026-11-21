# Estado operacional

**Atualizado em 2026-11-20.** Resumo de evidências operacionais; não substitui
os relatórios vinculados nem o [plano de maturidade](plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md).
“Implementado” não significa certificado além do escopo explicitamente provado.

## Implementado e comprovado

| Frente | Estado comprovado | Evidência |
|---|---|---|
| Guardrail de destinos e integridade de caminhos ativos (F1) | Testes do guard, ownership, uninstall e consistência passaram; revisão de segurança aprovada. Ensaio somente em fixtures temporárias. | [F1 — guardrail](../evidence/operational-maturity-2026-11-18/F1-guardrail.md) |
| Certificação de instalação (F2) | Dois ciclos em HOME temporário: instalação, idempotência e uninstall; veredito PASS delimitado e hashes ativos inalterados. | [F2 — instalador](../evidence/operational-maturity-2026-11-18/F2-installer-certification.md) |
| Pós-merge (F4) | CLI Plan/Apply e testes em repositório descartável; não executado contra GitHub real. | [F4 — pós-merge](../evidence/operational-maturity-2026-11-18/F4-post-merge.md) |
| Autonomia ponta a ponta (M3) | PASS delimitado às fatias A/B/C; não equivale à certificação integrada de todos os cenários nem mede eficiência. | [CHANGELOG](../CHANGELOG.md) |
| Backlog/documentação (M4) | Classificação read-only concluída; 94 issues abertas na medição de 2026-11-20 (`gh issue list --state open --limit 300`). Sem fechamento em massa. | [Relatório M4](../evidence/operational-maturity-2026-11-18/M4-backlog-classification.md); 93 na auditoria de 2026-11-19 e 91 no snapshot M4 de 2026-11-18 |

## Implementado, mas não certificado

| Frente | Situação |
|---|---|
| Permissões em runtime (F3) | Harness rerodado em runtime descartável 2.3.0: `/shell` retornou HTTP 204, mas não houve evento de decisão (`permission_events=[]`). **Allow/ask/deny seguem HOLD: não estão comprovados como gate/evento efetivo; HTTP 204 não certifica permissão.** [Evidência F3](../evidence/operational-maturity-2026-11-18/F3-permissions-hold.md) |
| Backlog e documentação (F5) | Classificação read-only concluída. A medição de 2026-11-20 registra 94 issues abertas; 93 na auditoria de 2026-11-19 e 91 issues/0 PRs no relatório M4 (snapshot de 2026-11-18). Comentários registrados em #141, #21 e #273. |
| Modo híbrido (Claude + Orca + OpenCode, #289) | Integração mesclada; instalação certificada em HOME temporário (P1-04: `TESTED_IN_ISOLATION=PASS`), mas perfil real não verificado (`ACTIVE_PROFILE_VERIFIED=NOT_VERIFIED`); P1-05 (interrupção/retomada com coordenador Claude headless) em HOLD — o CLI exige login e as credenciais reais não foram usadas nem copiadas. | [Certificação 2026-11-20](../evidence/v3.1/claude-hybrid/certification-2026-11-20.json); [HYBRID-ORCHESTRATION](HYBRID-ORCHESTRATION.md) |
| Certificação ponta a ponta (F6) | Ainda não há certificação integrada dos cenários A–E nem medição comparável de eficiência. Primitivas existentes não equivalem a prova integrada. |
| Permissões de shell dos workers | Política alterada: shell irrestrito nos 19 workers; `edit` por papel, `task: deny` e `subagent: * deny` preservados. Isso não constitui controle técnico contra escrita: comandos shell podem alterar arquivos mesmo com `edit: deny`. Ver [issue #141](https://github.com/Kusts/opencode-orchestration/issues/141) e CHANGELOG. |

## HOLD por limitação externa ou evidência ausente

- Descoberta runtime dos 19 agentes: launcher canônico ausente.
- Smoke Planner→worker: sem prova determinística sem provider.
- Retomada automática do Planner e handoff dinâmico worker→worker (#241):
  limitações/capacidades nativas não demonstradas; spikes do handoff retornaram
  `NOT_SUPPORTED`. Relay via Planner continua suportado.
- Permissões allow/ask/deny: F3 foi executada no runtime 2.3.0, mas segue HOLD por ausência de evento/gate efetivo observável. Alterações de permissões/segurança não estão certificadas.
- Shell irrestrito nos 19 workers: risco comportamental residual; `edit: deny` não impede escrita via shell. A restrição de shell não é um limite técnico de contenção.
- Fallback real para 429/quota/503: só há cobertura sintética.
- Eficiência: conclusão causal `NOT_MEASURED`/HOLD. A telemetria disponível não tem baseline comparável e o comparativo local do gate JEV (PR #296, mesclada (fb6185e); `evidence/v3.1/runtime-reliability/efficiency-comparison-2026-11-20.json`) cobre apenas forma/estado do gate, sem tokens, custo ou latência de runtime vivo. Exige A/B controlado com runtime V2 vivo.
- Instabilidade conhecida em CI (watchdog): os casos FIX5-2, FIX4-2b, JOB46 e F-B de `OrchestrationRuntimeWatchdogEnforcement.tests.ps1` falharam de forma intermitente nos runs 44745856311, 44756797911 e 44781078525 e passaram em reexecução com o mesmo código; sem causa raiz provada.

## Backlog futuro

- Revisar individualmente os itens classificados em M4; não fechar itens em
  massa. A medição de 2026-11-20 reportou 94 issues abertas; a auditoria de
  2026-11-19 registrou 93 e o relatório M4, 91 em 2026-11-18.
- F3 foi rerodada em runtime descartável 2.3.0; reavaliar o HOLD somente com
  prova observável de allow/ask/deny. Executar F6 quando seus cenários e
  medições puderem ser observados.
- Reavaliar os HOLDs apenas diante de nova capability nativa observável e
  evidência específica, conforme critérios do plano.

Sem daemon, scheduler, segundo Planner ou motor novo. Preservar configuração
ativa e worktrees de terceiros; não usar force-push nem reset destrutivo.

## Consolidação híbrida — 21/11/2026 (registro parcial)

Registro parcial da missão de consolidação híbrida: sem conclusões novas, sem declaração de conclusão da missão e sem autonomia integral. Autoridade: [missão 2026-11-21](../evidence/v3.1/claude-hybrid/mission-2026-11-21.json). Inventários consolidados (Claude Code 2.1.330, Orca 1.4.267, OpenCode 2.3.2): [capacidades nativas](../evidence/v3.1/claude-hybrid/native-capabilities-2026-11-21.md).

| Teste | Status |
|---|---|
| T0 Instalação/upgrade | PASS (ACTIVE_PROFILE_VERIFIED) |
| T1 OpenCode direto | HOLD |
| T2 Híbrido sequencial | FAIL parcial |
| T3 Híbrido paralelo | PASS |
| T4 Erro de envio | HOLD |
| T5 Retomada real | HOLD |
| T6 Delivery Git | PASS parcial |
| T7 A/B de eficiência | NOT_MEASURED |
| T8 Config sanitizada | HOLD |
| T9 Skills e hooks | FAIL |

Run `run_569a183e6205`; base `master@843d801`, estado `master@004b567`; PRs #302 e #301, CI 6/6. HOLDs e FAILs permanecem conforme a evidência; detalhes e achados A1–A9 no JSON vinculado.

## Evolução — 19/11/2026

Veredito: implementado e validado; alterações consolidadas em 24 arquivos (+347/−823). PR #288 mesclado (617a3c1).
Incluiu #287 (policy única T1–T4), #286 (remoção de provas sem callers), correções HY4/Fix e atualização documental.
Validações focadas e suíte V3 passaram; distribuição: 24 PASS / 0 FAIL / 1 SKIP. B2 foi resolvido com provisionamento reversível do binário v2.3.0. Anchors de pins resolvidos por conteúdo estável, com falha fechada se o padrão não for único.
PR #288 mesclado (617a3c1); permanecem HOLDs de autonomia. Fase 5 depende de provider/capacidade externa; conclusão causal de eficiência exige runtime V2 vivo e A/B controlado.
Detalhes, decisões e próximos passos: [relatório da evolução](../evidence/evolution-2026-11-19/RELATORIO.md).

## Evolução — 20/11/2026

Mesclados: #288 (617a3c1), #289 (684290e, modo híbrido), #291 (44f832e),
#292 (a09a1a2, policy como fonte única de modelos), #293 (8e37c0e,
encerramento pelo orquestrador), #295 (69e3309, certificação isolada P1-04;
P1-05 em HOLD), #296 (fb6185e, leitura única do gate de flag JEV no PlannerLoop)
e #297 (e8ea179, reconciliação do estado operacional). Nenhum HOLD de autonomia
foi fechado por estes merges; a conclusão causal de eficiência segue
`NOT_MEASURED`.
