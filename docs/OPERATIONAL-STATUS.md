# Estado operacional

**Atualizado em 2026-11-19.** Resumo de evidências operacionais; não substitui
os relatórios vinculados nem o [plano de maturidade](plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md).
“Implementado” não significa certificado além do escopo explicitamente provado.

## Implementado e comprovado

| Frente | Estado comprovado | Evidência |
|---|---|---|
| Guardrail de destinos e integridade de caminhos ativos (F1) | Testes do guard, ownership, uninstall e consistência passaram; revisão de segurança aprovada. Ensaio somente em fixtures temporárias. | [F1 — guardrail](../evidence/operational-maturity-2026-11-18/F1-guardrail.md) |
| Certificação de instalação (F2) | Dois ciclos em HOME temporário: instalação, idempotência e uninstall; veredito PASS delimitado e hashes ativos inalterados. | [F2 — instalador](../evidence/operational-maturity-2026-11-18/F2-installer-certification.md) |
| Pós-merge (F4) | CLI Plan/Apply e testes em repositório descartável; não executado contra GitHub real. | [F4 — pós-merge](../evidence/operational-maturity-2026-11-18/F4-post-merge.md) |
| Autonomia ponta a ponta (M3) | PASS delimitado às fatias A/B/C; não equivale à certificação integrada de todos os cenários nem mede eficiência. | [CHANGELOG](../CHANGELOG.md) |
| Backlog/documentação (M4) | Classificação read-only concluída; 93 issues abertas conforme auditoria de 2026-11-19. Sem fechamento em massa. | [Relatório M4](../evidence/operational-maturity-2026-11-18/M4-backlog-classification.md); contagem atualizada pela auditoria de 2026-11-19 |

## Implementado, mas não certificado

| Frente | Situação |
|---|---|
| Permissões em runtime (F3) | Harness rerodado em runtime descartável 2.3.0: `/shell` retornou HTTP 204, mas não houve evento de decisão (`permission_events=[]`). **Allow/ask/deny seguem HOLD: não estão comprovados como gate/evento efetivo; HTTP 204 não certifica permissão.** [Evidência F3](../evidence/operational-maturity-2026-11-18/F3-permissions-hold.md) |
| Backlog e documentação (F5) | Classificação read-only concluída. A contagem de 93 issues abertas é da auditoria de 2026-11-19; a medição de 91 issues/0 PRs no relatório M4 é o snapshot anterior de 2026-11-18. Comentários registrados em #141, #21 e #273. |
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
- Eficiência: telemetria disponível não tem baseline comparável; não mensurada.

## Backlog futuro

- Revisar individualmente os itens classificados em M4; não fechar itens em
  massa. A auditoria de 2026-11-19 reportou 93 issues abertas; o relatório M4
  registra o snapshot anterior de 91 em 2026-11-18.
- F3 foi rerodada em runtime descartável 2.3.0; reavaliar o HOLD somente com
  prova observável de allow/ask/deny. Executar F6 quando seus cenários e
  medições puderem ser observados.
- Reavaliar os HOLDs apenas diante de nova capability nativa observável e
  evidência específica, conforme critérios do plano.

Sem daemon, scheduler, segundo Planner ou motor novo. Preservar configuração
ativa e worktrees de terceiros; não usar force-push nem reset destrutivo.

## Evolução — 19/11/2026

Veredito: implementado e validado; alterações consolidadas em 24 arquivos (+347/−823), sem commit/push.
Incluiu #287 (policy única T1–T4), #286 (remoção de provas sem callers), correções HY4/Fix e atualização documental.
Validações focadas e suíte V3 passaram; distribuição teve 1 falha ambiental: binário OpenCode v2.3.0 ausente.
Permanecem HOLDs de autonomia; Fase 5 não executada por depender de provider/capacidade externa e PR real.
Detalhes, decisões e próximos passos: [relatório da evolução](../evidence/evolution-2026-11-19/RELATORIO.md).
