# Admissao lenta seletiva — #184 fatia 3

## Escopo

Implementado `OrchestrationEventAdmissionSlowPath.ps1`, CLI `event-admission-slow-path.ps1` e registry `event-admission-slow-path-policy.json`. A fatia decide deterministicamente se uma ambiguidade humana allowlisted pode gerar um pedido externo; limites de uso ausentes ou zerados fazem skip. A policy versionada nasce `enabled=false`.

Isto **nao** chama LLM, rede, webhook ou Kernel, nao cria Task e nao executa acao. `shadow=true` e `executable=false` sao invariantes. O custo de chamada real segue pendente de teto numerico e credencial aprovados pelo operador.

## Contrato e protecoes

O pedido ordenado inclui versao, policy, dedup key, thread, trigger, resumo limitado/redigido, sinais, classes permitidas e limite de rationale. SHA-256 sobre JSON compacto UTF-8 sem `request_digest` vincula a resposta ao pedido; divergencia retorna `SLOWPATH_DIGEST_MISMATCH`. A resposta externa valida classe, confidence, rationale, metadata e rejeita campos extras. Confidence abaixo do minimo vira `context_only`/`low-confidence`. Nenhuma resposta torna algo executavel.

Erros do loader: `SLOWPATH_POLICY_PATH_NOT_FOUND`, `SLOWPATH_POLICY_PATH_INVALID`, `SLOWPATH_POLICY_TOO_LARGE`, `SLOWPATH_POLICY_INVALID_JSON`, `SLOWPATH_POLICY_SCHEMA_INVALID`. A policy rejeita UNC/device e ancestrais reparse. Validacao da resposta usa `SLOWPATH_CLASS_INVALID`, `SLOWPATH_CONFIDENCE_INVALID`, `SLOWPATH_RATIONALE_INVALID`, `SLOWPATH_METADATA_INVALID` e `SLOWPATH_RESPONSE_INVALID`.

## Evidencia

`OrchestrationEventAdmissionSlowPath.tests.ps1`: 15 assertions em Windows PowerShell 5.1 e pwsh. Suites de admission/event e package-consistency sao reportadas no CHANGELOG apos execucao. Comandos focados: `run-v3-tests.ps1 -Name 'OrchestrationEventAdmission*'`, `run-v3-tests.ps1 -Name 'OrchestrationEvent*'`, `test-package-consistency.ps1` e `git diff --check`.
