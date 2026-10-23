# OPENCODE RUNTIME ADAPTIVE COMPATIBILITY PLAN (Issue #50)

**Versão:** 1.0  
**Data:** 2026-10-21  
**Status:** APPROVED — Execução de F0 a F2  
**Referência:** `docs/specs/OPENCODE-RUNTIME-ADAPTIVE-COMPATIBILITY-SPEC.md`  

---

## 1. Fases de Execução da Issue #50

### F0 — Auditoria e Mapeamento de Hardcodes (Concluído)
- Mapeado: `source/registry/runtime-versions.json` fixa o pin do CI em `2.0.23` para reprodutibilidade.
- Identificado: O host atual da máquina de desenvolvimento executa `opencode v2.1.2`.
- Verificado: Incompatibilidades conhecidas (Issue #69 `/shell` deny fail-open) documentadas e mantidas em HOLD seguro.

### F1 — Especificação e Contratos (Concluído)
- SPEC criada em `docs/specs/OPENCODE-RUNTIME-ADAPTIVE-COMPATIBILITY-SPEC.md`.
- Contrato estruturado de capabilities com 9 dimensões operacionais.
- Critérios de saída: `SUPPORTED`, `DEGRADED`, `UNSUPPORTED`, `UNKNOWN`.

### F2 — Discovery e Capability Doctor V2 (Implementação Atual)
- Desenvolver `scripts/runtime/detect-opencode-capabilities.ps1`:
  - Execução estritamente read-only (zero mutações de disco).
  - Descoberta de binário, versão, hash SHA256.
  - Sondagem de subcomandos via flags seguras (`--help`, `--version`).
  - Verificação de bundle de plugin e integridade do sidecar SHA256.
  - Relatório de incompatibilidades conhecidas (#69, #70, #149).
  - Emissão determinística JSON (`-AsJson`) e relatório legível em terminal.
- Desenvolver suíte de testes `scripts/runtime/detect-opencode-capabilities.tests.ps1`.

### F3 — Integração e Validação em Shadow (Próxima Etapa)
- Integrar com o preflight (`scripts/v3/orchestration-preflight.ps1`).
- Comparar decisões em shadow mode sem interromper a rotina de produção.
- Garantir que ambientes heterogêneos (CI Linux com 2.0.23 vs Windows Dev com 2.1.2) passem com status coerente.

---

## 2. Critérios de Aceite da Fase F2

1. **Read-Only Rigoroso:** O script não cria arquivos temporários, não altera configurações e não executa mutações de git.
2. **Deterministic Output:** Saída idêntica e válida sob PS 5.1 e PS 7.
3. **Resiliência a Falhas:** Caso o binário `opencode` não exista ou lance erro, o doctor emite `cli_core: UNSUPPORTED` estruturado com exit code de diagnóstico, sem exception não tratada.
4. **Redação de Segredos:** Nenhum token, senha ou caminho sensível é vazado no relatório.
5. **Autoreview:** Aprovado por Coder, Tester e Reviewer.
