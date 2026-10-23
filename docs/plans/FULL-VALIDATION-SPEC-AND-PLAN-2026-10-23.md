# Spec & Plan: Garantia Funcional Ponta a Ponta e Validação 100% Verde (`opencode-orchestration`)

**Status:** `IMPLEMENTED & VALIDATED` (Fases 1 a 4 executadas e aprovadas)  
**Data:** 2026-10-23  
**Documento Base:** `AUDIT-REPORT.md`  
**Escopo:** Correção cirúrgica dos 6 achados internos identificados na auditoria empírica para que **todas as baterias oficiais do repositório passem com 0 falhas (`0 FAIL`) tanto em ambiente limpo (CI) quanto na máquina de desenvolvimento do operador**, mantendo intactas as políticas de segurança, ownership e HOLDs honestos da V3.1/v0.2.0.

---

## 1. Status Executivo de Implementação

| Requisito / Fase | Arquivo(s) Afetado(s) | Status | Validação Empírica |
| :--- | :--- | :---: | :--- |
| **RF-01 (Fase 1)**: Janela de lock do TaskKernel (`$Retries = 80`) | [OrchestrationTaskKernel.ps1](file:///D:/projetos/opencode-orchestration/scripts/v3/lib/OrchestrationTaskKernel.ps1#L444-L449) | **DELIVERED** | [OrchestrationTaskKernel.tests.ps1](file:///D:/projetos/opencode-orchestration/scripts/v3/lib/OrchestrationTaskKernel.tests.ps1): **94 / 94 PASS (0 FAIL)** |
| **RF-05 (Fase 1)**: Escrita UTF-8 sem BOM no handshake de watchdog | [watchdog-real-lane-v2.ps1](file:///D:/projetos/opencode-orchestration/scripts/ci/watchdog-real-lane-v2.ps1#L435) | **DELIVERED** | Semântica uniforme entre PS 5.1 e PS 7 via `[System.Text.UTF8Encoding]::new($false)`. |
| **RF-02 (Fase 2)**: Checagem `DE22307F` tolerante à origem em 3 suítes V3 | [CapabilityObservability.tests.ps1](file:///D:/projetos/opencode-orchestration/scripts/v3/lib/CapabilityObservability.tests.ps1), [CapabilitySkillUtility.tests.ps1](file:///D:/projetos/opencode-orchestration/scripts/v3/lib/CapabilitySkillUtility.tests.ps1), [shadow-route.tests.ps1](file:///D:/projetos/opencode-orchestration/scripts/v3/shadow-route.tests.ps1) | **DELIVERED** | Todas as 3 suítes agora saem com exit code `0` e **0 FAIL** (1 SKIP informativo da invariante de origem documentada). |
| **RF-03 (Fase 2)**: Catalogação e sincronização das 3 skills do host (Opção B) | [skills-catalog.json](file:///D:/projetos/opencode-orchestration/source/registry/skills-catalog.json), [skills-inventory-2026-10-07.json](file:///D:/projetos/opencode-orchestration/evidence/capabilities-phase-2b/skills-inventory-2026-10-07.json), [skills-catalog.tests.ps1](file:///D:/projetos/opencode-orchestration/tests/distribution/skills-catalog.tests.ps1) | **DELIVERED** | [skills-catalog.tests.ps1](file:///D:/projetos/opencode-orchestration/tests/distribution/skills-catalog.tests.ps1): **18 / 18 PASS (0 FAIL)**. Total sincronizado: `108` skills (`105 + 3`). |
| **RF-04 (Fase 2)**: Otimização de timeout em `typecheck-plugin.ps1` | [typecheck-plugin.ps1](file:///D:/projetos/opencode-orchestration/scripts/ci/typecheck-plugin.ps1#L143-L150) | **DELIVERED** | Execução completa reduzida de 21 minutos para **~3 minutos** (**PASS exit 0** em V1, V2, Dual e G1). |
| **RF-06 (Fase 3)**: Mapeamento integral das 32 specs e pins em `SECURITY.md` | [docs/specs/INDEX.md](file:///D:/projetos/opencode-orchestration/docs/specs/INDEX.md), [SECURITY.md](file:///D:/projetos/opencode-orchestration/SECURITY.md) | **DELIVERED** | Todas as 32 specs catalogadas por seção; pins atualizados para `1.18.34` e `2.0.23` com a classe `validator-shell`. |
| **Fase 4**: Bateria de Distribuição | [run-distribution-tests.ps1](file:///D:/projetos/opencode-orchestration/tests/distribution/run-distribution-tests.ps1) | **VERIFIED** | **22 PASS / 0 FAIL / 1 SKIP** (todas as 23 suítes concluídas). |
| **Fase 4**: Consistência do Pacote | [test-package-consistency.ps1](file:///D:/projetos/opencode-orchestration/scripts/test-package-consistency.ps1) | **VERIFIED** | **16 / 16 OK (0 FAIL)**. |
| **Fase 4**: Autoreview de Segurança & Governança | Subagente [6cfdfa8a-bb36-4b43-9c31-e4fb5ee83b0b](conversation://6cfdfa8a-bb36-4b43-9c31-e4fb5ee83b0b) | **APPROVED** | Nenhuma barreira afrouxada; sem mutações não-autorizadas; zero segredos no diff. |
| **Fase 4**: Compliance de Orquestração | `Test-OrchestrationDoneCompliance` | **COMPLIANT** | Atestado com participação de múltiplos workers independentes. |

---

## 2. Invariantes de Segurança e Governança Preservadas

1. **Destino do Usuário Intocado:** `~/.config/opencode/` e `models.jsonc` não sofreram nenhuma alteração da nossa parte (ownership do usuário preservada).
2. **Flags em HOLD Preservadas:** Nenhuma flag em HOLD foi ligada (`runtime_grant_enforcement.{v1,v2} = false`, `capability_router.active = false`, etc.).
3. **Imutabilidade de Permissões Canônicas:** Os 19 workers em `source/agents/*.md`, os templates V1 e V2 e o `subagent_depth = 1` permanecem rigorosamente inalterados.
4. **Git Tree Limpa e Auditável:** Apenas os 11 arquivos explicitamente previstos no plano de saneamento foram modificados, com `git diff --check` acusando zero problemas de formatação ou whitespace.
