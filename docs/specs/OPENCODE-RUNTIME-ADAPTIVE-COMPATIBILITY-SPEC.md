# OPENCODE RUNTIME ADAPTIVE COMPATIBILITY SPEC (Issue #50)

**Versão:** 1.0  
**Data:** 2026-10-21  
**Status:** PROPOSED & IMPLEMENTED (F0-F2)  
**Issues Relacionadas:** #50, #137 (Epic), #101 (Regression Gate), #138 (Compat 2.1.x), #21 (Distribution)  
**Baseline de Runtime:** OpenCode V2.1.2 (Host detectado) / V2.0.23 (CI Pin reproduzível)  

---

## 1. Princípio Arquitetural: Capability-First, Não Version-Patch

O OpenCode V2 evolui com lançamentos frequentes (ex.: 2.0.23 → 2.0.28 → 2.0.32 → 2.1.2).
O sistema de orquestração **não deve quebrar nem exigir commits manuais a cada bump de versão menor/patch compatível**.

> [!IMPORTANT]
> **A versão é um metadado de auditoria; contratos e capabilities são os critérios operacionais.**
> Não utilizamos `if ($version -eq '2.0.28')` como lógica principal de decisão. Provas contratuais herméticas determinam o que está suportado.

### 1.1 Invariantes Obrigatórias
1. **Zero Rollout Cego:** Nenhuma versão desconhecida é aceita automaticamente para funcionalidades sensíveis sem conformance.
2. **Fail-Closed Seletivo:** Se uma capability específica estiver degradada ou ausente (ex.: API de sessões indisponível), apenas a funcionalidade dependente entra em fallback/degradação estruturada; o sistema como um todo continua operando nas capacidades seguras.
3. **Imutabilidade de Autoridade:** A presença de uma capability no host não altera grants, permissões, ownership, receipts, verifier ou DONE.
4. **Sem Alteração Silenciosa:** O doctor e detector são estritamente **read-only**; nunca criam arquivos, não realizam mutação de perfil e não instalam pacotes sem ordem explícita.

---

## 2. Taxonomia de Capabilities do Host OpenCode V2

| Capability | Descritor | Método de Verificação (Read-Only) | Estado de Fallback |
|---|---|---|---|
| `cli_core` | Executável base OpenCode | `opencode --version` | Blocker fatal se ausente |
| `subagent_execution` | Suporte a subagents e delegação | Schema de permissões `experimental.subagent_depth` | Execução direta via cheap worker |
| `session_management` | Listagem e ciclo de sessões | `opencode session --help` (subcomando `list`/`delete`) | Reconciliação local via Kernel checkpoints |
| `service_management` | Servidor em background | `opencode service --help` (subcomando `status`) | Execução standalone/in-process |
| `mcp_client` | Suporte a servidores MCP | `opencode mcp --help` (subcomandos `list`/`add`) | Fallback determinístico (pesquisa local/direta) |
| `plugin_system` | Extensibilidade por plugins | `opencode plugin --help` e integridade do bundle sidecar | Admissão estrita local via wrappers |
| `pty_terminal` | PTY persistente Windows | Suporte a streaming/PTY nativo | Windows Job Object local |
| `api_surface` | Endpoint REST OpenAPI | `opencode api --help` | Interação CLI direta |
| `models_discovery` | Enumeração de modelos | `opencode models --help` | Pool estático de models em `models.example` |

---

## 3. Estrutura do Relatório de Compatibilidade

O Compatibility Doctor V2 (`scripts/runtime/detect-opencode-capabilities.ps1`) emite um JSON determinístico contendo:

```json
{
  "doctor_version": "1.0",
  "generated_at": "2026-10-21T19:00:00Z",
  "runtime_identity": {
    "generation": 2,
    "runtime_id": "opencode-v2",
    "version_string": "opencode v2.1.2",
    "binary_path": "C:\\Program Files\\opencode\\bin\\opencode.exe",
    "binary_sha256": "abcdef...",
    "decision": "target"
  },
  "capabilities": {
    "cli_core": { "status": "SUPPORTED", "evidence": "opencode v2.1.2" },
    "subagent_execution": { "status": "SUPPORTED", "evidence": "subagent_depth=1 configured" },
    "session_management": { "status": "SUPPORTED", "evidence": "subcommand session list/delete available" },
    "service_management": { "status": "SUPPORTED", "evidence": "subcommand service status available" },
    "mcp_client": { "status": "SUPPORTED", "evidence": "subcommand mcp list/add available" },
    "plugin_system": { "status": "SUPPORTED", "evidence": "g1-dispatch-admission bundle verified" },
    "pty_terminal": { "status": "SUPPORTED", "evidence": "windows terminal integration supported" },
    "api_surface": { "status": "SUPPORTED", "evidence": "subcommand api available" },
    "models_discovery": { "status": "SUPPORTED", "evidence": "subcommand models available" }
  },
  "known_incompatibilities": [
    {
      "id": "SEC-HIGH-01",
      "issue": 69,
      "severity": "HIGH",
      "status": "HOLD",
      "detail": "Native /shell surface lacks enforced admission mediation; deny rules behave fail-open on host."
    }
  ],
  "overall_verdict": "COMPATIBLE_WITH_HOLDS"
}
```

---

## 4. Matriz de Conformance e Regressão

1. **2.0.23 (Baseline CI):** Todas as capacidades de base suportadas; HOLD em SEC-HIGH-01.
2. **2.1.2 (Host Atual):** Compatibilidade integral confirmada com subcomandos nativos de session, service, mcp, plugin, api, models.
3. **Versão Desconhecida / Canary:** Executar sondagem não destrutiva. Se comandos essenciais falharem, reportar `UNSUPPORTED` ou `DEGRADED` sem falhar o interpretador.
