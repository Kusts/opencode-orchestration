# Estado operacional

**Atualizado em 2026-11-18.** Resumo de evidências operacionais; não substitui
os relatórios vinculados nem o [plano de maturidade](plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md).
“Implementado” não significa certificado além do escopo explicitamente provado.

## Implementado e comprovado

| Frente | Estado comprovado | Evidência |
|---|---|---|
| Guardrail de destinos e integridade de caminhos ativos (F1) | Testes do guard, ownership, uninstall e consistência passaram; revisão de segurança aprovada. Ensaio somente em fixtures temporárias. | [F1 — guardrail](../evidence/operational-maturity-2026-11-18/F1-guardrail.md) |
| Certificação de instalação (F2) | Dois ciclos em HOME temporário: instalação, idempotência e uninstall; veredito PASS delimitado e hashes ativos inalterados. | [F2 — instalador](../evidence/operational-maturity-2026-11-18/F2-installer-certification.md) |
| Pós-merge (F4) | CLI Plan/Apply e testes em repositório descartável; não executado contra GitHub real. | [F4 — pós-merge](../evidence/operational-maturity-2026-11-18/F4-post-merge.md) |

## Implementado, mas não certificado

| Frente | Situação |
|---|---|
| Permissões em runtime (F3) | Harness entregue; 8/8 testes e `Plan` OK. `Run` abortou antes de tocar o serviço por `F3_VERSION_MISMATCH` (pin 2.3.0 vs binário 2.3.2). **Allow/ask/deny não estão comprovados.** [Evidência F3](../evidence/operational-maturity-2026-11-18/F3-permissions-hold.md) |
| Backlog e documentação (F5) | Classificação read-only em 2026-11-18: 91 issues abertas, 0 PRs no conjunto; categorias e ressalvas no [relatório M4](../evidence/operational-maturity-2026-11-18/M4-backlog-classification.md). Comentários registrados em #141, #21 e #273. |
| Certificação ponta a ponta (F6) | Ainda não há certificação integrada dos cenários A–E nem medição comparável de eficiência. Primitivas existentes não equivalem a prova integrada. |

## HOLD por limitação externa ou evidência ausente

- Descoberta runtime dos 19 agentes: launcher canônico ausente.
- Smoke Planner→worker: sem prova determinística sem provider.
- Retomada automática do Planner e handoff dinâmico worker→worker (#241):
  limitações/capacidades nativas não demonstradas; spikes do handoff retornaram
  `NOT_SUPPORTED`. Relay via Planner continua suportado.
- Permissões allow/ask/deny: bloqueadas pela divergência de versão descrita em F3.
- Fallback real para 429/quota/503: só há cobertura sintética.
- Eficiência: telemetria disponível não tem baseline comparável; não mensurada.

## Backlog futuro

- Revisar individualmente os itens classificados em M4; não fechar itens em
  massa. A consulta de 2026-11-18 retornou 91 issues abertas (a contagem 90 é
  histórica; ver relatório M4).
- Retomar F3 somente em runtime descartável e com versão compatível; executar
  F6 quando seus cenários e medições puderem ser observados.
- Reavaliar os HOLDs apenas diante de nova capability nativa observável e
  evidência específica, conforme critérios do plano.

Sem daemon, scheduler, segundo Planner ou motor novo. Preservar configuração
ativa e worktrees de terceiros; não usar force-push nem reset destrutivo.
