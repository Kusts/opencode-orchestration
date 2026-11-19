# M4 — Classificação do backlog de issues

**Data da consulta:** 2026-11-18.  
**Fonte:** GitHub REST API pública, `GET /repos/Kusts/opencode-orchestration/issues?state=open`: **91 issues abertas e 0 PRs** no conjunto. O número 90 que aparece no pedido e no contexto anterior do plano é histórico; a consulta desta classificação retornou 91.  
**Método e limite:** classificação read-only baseada em títulos, corpos, amostras e evidências locais. Itens sem base segura estão marcados “requer leitura”. Esta classificação não autoriza encerrar issues; revise cada item individualmente antes de qualquer encerramento. Ver também o [estado operacional](../../docs/OPERATIONAL-STATUS.md) e o [plano de maturidade](../../docs/plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md), especialmente o marco M4 e seus critérios de aceite.

## Baldes da classificação

Os baldes representam sinais de classificação, não uma autorização de fechamento. Há sobreposições intencionais; por isso, as contagens abaixo não devem ser somadas como uma partição exclusiva das 91 issues.

| Balde | Contagem | Issues |
|---|---:|---|
| Defeito reproduzível atual | 0 | #25 requer leitura |
| Implementação parcial | 22 | #1, #2, #4, #8, #9, #10, #11, #21, #30, #50, #60, #64, #139, #140, #141, #177, #183, #184, #185, #200, #208, #270 |
| Entregue/encerrável com ressalva | 3 | #143, #200, #273 — revisão individual obrigatória |
| Duplicata confirmada | 0 | Nenhuma comprovada |
| Pesquisa/evolução futura | 63 | #3, #5, #6, #7, #12, #13, #14, #15, #16, #17, #20, #29, #42, #49, #52, #55, #56, #57, #77, #78, #79, #80, #102, #103, #104, #105, #111, #113, #114, #115, #116, #138, #142, #145, #147, #148, #176, #178, #179, #182, #186, #187, #188, #189, #190, #191, #192, #193, #194, #195, #196, #197, #198, #199, #202, #203, #205, #211, #220, #221, #241, #281, #25 |
| Dependência externa | 3 | #69, #70, #241 |

## Sobreposições e divergências relevantes

As sobreposições observadas não comprovam duplicação: #273/#140 (pós-merge vs. worktrees nativos), #270/#1 (GitHub nativo vs. política de delivery) e #194/#200 (avaliação vs. implementação). Nenhuma duplicata foi confirmada.

| Issue(s) | Observação |
|---|---|
| #208 | O texto histórico T3→Sol→Astra conflita com `source/registry/model-routing-policy.json:754-764`: Sol é candidato same-tier T4, não degrau. Não alterar a policy. |
| #50 | Pins estão em `source/registry/runtime-versions.json`; permanece allowlist residual hardcoded em `scripts/v3/lib/OrchestrationModelRouter.ps1:2665`. |
| #141 | Ownership parcial e HOLDs de enforcement. |
| #69/#70 | Dependência upstream. |
| #241 | HOLD/NOT_SUPPORTED para handoff direto; relay via Planner é suportado. |
| #193 | Comentário desalinhado sobre retomada do Planner; requer triagem. |

## Registro e próximos passos

Comentários já registrados em 2026-11-18: #141, #21 e #273 (F1/F2/F4). Comentários individualizados sugeridos para o Planner: #208, #270, #1, #50, #241, #30 e #193. Não fechar issues nesta etapa.

Riscos: a classificação usa títulos e amostras, não leitura integral de cada issue; a revisão individual é necessária para evitar fechamento indevido. O estado retornado pela API pode mudar após 2026-11-18.
