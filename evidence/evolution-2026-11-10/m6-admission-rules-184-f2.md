# Admissao de regras de operador — #184 fatia 2

Entregues registry versionado, loader fail-closed e entrada CLI `-RulesRegistry`. O exemplo nasce `enabled=false` para impedir que regras novas ampliem admissao por padrao. O contrato continua shadow-only (`shadow=true`, `executable=false`): nada executa, cria Task ou chama LLM; sem HMAC (fatia 6).

Erros: `RULES_PATH_NOT_FOUND`, `RULES_PATH_INVALID`, `RULES_TOO_LARGE`, `RULES_INVALID_JSON`, `RULES_SCHEMA_INVALID`, `RULES_POLICY_VERSION_INVALID`, `RULES_RULE_INVALID`, `RULES_RULE_ID_DUPLICATE`, `RULES_LIMIT_EXCEEDED`, `RULES_CONFIG_INVALID`.

Validacao real: AdmissionIntent + AdmissionRules passaram 2/2 suites em Windows PowerShell 5.1 e pwsh; Event* passou 5/5 suites nos dois hosts. A suite nova do loader tem 32 asserts, incluindo junction criada com sucesso. `test-package-consistency.ps1` passou 17/17; `git diff --check` limpo.

Pendencias #184: slow path LLM, auto executavel com policy/grant, criacao de Task e ingest autenticado.

## Hardening pos-revisao

O reviewer aprovou a fatia com 2 achados MINOR de corretude e 4 ressalvas LOW de seguranca. A decisao automatica sugeriu REPLAN por escopo amplo; o Planner classificou como endurecimento coeso do mesmo modulo (loader, CLI e testes), sem ampliar autoridade.

Correcoes: (1) CLI retorna o shape completo do classificador no erro de registry; (2) regex usa terminador `\z`; (3) rejeita UNC/device e caminhos com reparse point; (4) schema raiz rejeita campos desconhecidos; (5) `scope_allowlist` aplica charset restrito; (6) verificacao de chaves permitidas e case-sensitive.

Testes de follow-up cobrem registry vazio, thread valida, limite exato, conflitos CLI, shape de erro, normalizacao habilitada, novas linhas finais, raiz desconhecida, scope fora do charset, UNC e junction.
