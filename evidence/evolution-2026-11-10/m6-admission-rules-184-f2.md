# Admissao de regras de operador — #184 fatia 2

Entregues registry versionado, loader fail-closed e entrada CLI `-RulesRegistry`. O exemplo nasce `enabled=false` para impedir que regras novas ampliem admissao por padrao. O contrato continua shadow-only (`shadow=true`, `executable=false`): nada executa, cria Task ou chama LLM; sem HMAC (fatia 6).

Erros: `RULES_PATH_NOT_FOUND`, `RULES_TOO_LARGE`, `RULES_INVALID_JSON`, `RULES_SCHEMA_INVALID`, `RULES_POLICY_VERSION_INVALID`, `RULES_RULE_INVALID`, `RULES_RULE_ID_DUPLICATE`, `RULES_LIMIT_EXCEEDED`, `RULES_CONFIG_INVALID`.

Validacao real: AdmissionIntent + AdmissionRules passaram 2/2 suites em Windows PowerShell 5.1 e pwsh; a suite nova tem 20 asserts. `test-package-consistency.ps1` passou 17/17; `git diff --check` limpo.

Pendencias #184: slow path LLM, auto executavel com policy/grant, criacao de Task e ingest autenticado.
