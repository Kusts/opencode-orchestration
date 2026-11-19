# M6 — baseline de eficiência

**Execução:** 2026-11-19  
**Branch:** `feat/operational-maturity-f3-rerun-20261119`  
**Commit medido:** `1e08cf5e07bbf64a07a256905ff3bffa77282d84`  
**Runtime:** PowerShell 5.1.26100.9818; OpenCode V2 pin 2.3.0  
**JSON completo:** `<TEMP>/m6-efficiency-baseline.json` (temporário, não versionado).

| Cenário | Comando | Exit | Duração (ms) | Asserções/casos |
|---|---|---:|---:|---:|
| Trivial | `scripts/v3/target-guard.tests.ps1` | 0 | 1040 | 14 asserções |
| Médio | `scripts/v3/certify-permissions-runtime.ps1 -Mode Plan` | 0 | 1012 | 3 casos |
| Falha fechada | `scripts/v3/certify-permissions-runtime.ps1 -Mode Run` sem opt-in | 1 | 1022 | F3_RUN_REQUIRES_F3_PERMISSION_RUN_OPT_IN confirmado; servidor não iniciado |

O cenário fail-closed remove `F3_PERMISSION_RUN_OPT_IN` do ambiente de processo
antes de iniciar o filho, mesmo que esteja presente no ambiente externo; exige
que a saída do harness contenha `F3_RUN_REQUIRES_F3_PERMISSION_RUN_OPT_IN=1`.
O teste focado e a execução de validação foram feitos com o opt-in externo
ligado; o cenário filho permaneceu fail-closed e confirmou o token esperado.

Os campos de chamadas ao Planner, subagentes, retries, tokens e custo estão
explicitamente como `not_measured`: as ferramentas usadas não os fornecem.
Este baseline mede duração local, exits e contagem observável de asserções/
casos; eficiência comparativa antes/depois, tokens e custo permanecem não
mensurados. Duração é wall-clock do processo incluindo inicialização do
PowerShell, não uma medição isolada de trabalho interno.
