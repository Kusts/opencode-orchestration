# M3 — Certificação de autonomia operacional E2E

**Data:** 2026-11-18  
**Escopo:** cenários A–E observados na missão. Esta certificação não declara
autonomia integral.

## O que está comprovado

| Cenário | Classificação | Evidência | Limitações | Critério de reavaliação |
|---|---|---|---|---|
| A — tarefa simples | **PASS delimitado** | Tarefas delimitadas executadas por worker único com verificação focada, incluindo correção do guardrail de CI e resolução do conflito de `CHANGELOG`; `git diff --check` e comandos focados. | Não prova que todo pedido simples seja sempre roteado corretamente. | Reavaliar com novas tarefas simples representativas e seus resultados e verificações observáveis. |
| B — Coder → Tester → Reviewer → PR → CI → merge → pós-merge | **PASS nas fatias exercitadas** | Cadeias F1/F2/F4; F1: 14/0 no guard, 9 checks, ownership 17/17 e uninstall 22/22; F2: 9 checks e harness real; F4: 16 assertions e ownership 82/82. Security-reviewer aprovou cada fatia. PRs #279/#280 mescladas (`f5e3e10`, `6586f2e`), CI 6/6 verde nos commits finais. Pós-merge: sync local por fast-forward e exclusão segura com `git branch -d`; worktrees alheios preservados. | Certifica as execuções desta missão, não cobertura de todo fluxo ou ambiente. Os harnesses incluem fixtures/fakes onde indicado nos relatórios F1–F4. | Repetir o fluxo em outras mudanças e manter evidência ligada a commits, checks e resultado pós-merge. |
| C — falha e reparo | **PASS nas falhas observadas** | Revisões e validações encontraram e motivaram reparos: HIGH fail-open do guard em agente interativo (3 rodadas), 4 achados médios no harness F2, fail-open de checks pendentes no pós-merge, conflitos de merge e regressões de CI (`-ProfileRoot`, `ProfileRoot` do Both e flake FIX4-2b reexecutado). | Não demonstra tratamento de todas as classes de falha nem reparo sem intervenção. | Reavaliar com falhas novas, reproduzíveis e evidência de causa, correção e regressão coberta. |
| D — fallback de modelos | **HOLD** | Cobertura disponível é sintética; nenhum 429/quota/503 real foi observado. A política canônica `source/registry/model-routing-policy.json:754-764` prevalece: Sol é same-tier T4, não degrau T3→Astra; a divergência histórica da #208 foi registrada em comentário. | Sem evento real e correlacionado, não há prova de fallback operacional nem de não-início. | Reavaliar somente com evento real, evidência independente de não-início e fluxo autorizado pela política vigente. |
| E — interrupção e retomada | **HOLD** | Retomada automática do Planner não foi comprovada. Handoff direto worker→worker retornou `NOT_SUPPORTED` nos spikes com depth 1/2; relay via Planner é o fluxo suportado. Nenhum supervisor paralelo foi criado. | Não há prova de retomada automática após interrupção; o relay suportado não equivale a retomada automática. | Reavaliar quando houver execução real que comprove interrupção, continuidade segura do Planner e reconciliação sem duplicar efeitos. |

## O que permanece HOLD

- **Permissões allow/ask/deny no runtime:** F3 terminou em `F3_VERSION_MISMATCH`
  (pin 2.3.0 versus binário 2.3.2), antes de executar casos ou endpoints;
  hashes ativos permaneceram inalterados. Ver `F3-permissions-hold.md`.
- **Descoberta runtime dos 19 agentes** e **smoke Planner→worker sem provider
  determinístico:** não comprovados no harness F2.
- **Eficiência:** sem baseline comparável, não certificada.
- A missão original não autoriza declarar autonomia integral enquanto a
  retomada do Planner e os comportamentos críticos de permissão permanecerem
  sem comprovação.

## Evidências da missão

- `F1-guardrail.md`, `F2-installer-certification.md`,
  `F3-permissions-hold.md` e `F4-post-merge.md` neste diretório.
- Referências de integração: PRs #279/#280 e commits `f5e3e10`, `6586f2e`.
- Resultados são limitados às execuções e contagens registradas; não implicam
  certificação de capacidades não exercitadas.
