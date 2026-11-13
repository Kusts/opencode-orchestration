# Admissao lenta seletiva — #184 fatia 3

## Escopo

Implementado `OrchestrationEventAdmissionSlowPath.ps1`, CLI `event-admission-slow-path.ps1` e registry `event-admission-slow-path-policy.json`. A fatia decide deterministicamente se uma ambiguidade humana allowlisted pode gerar um pedido externo; limites de uso ausentes ou zerados fazem skip. A policy versionada nasce `enabled=false`.

Isto **nao** chama LLM, rede, webhook ou Kernel, nao cria Task e nao executa acao. `shadow=true` e `executable=false` sao invariantes. O custo de chamada real segue pendente de teto numerico e credencial aprovados pelo operador.

## Contrato e protecoes

O request fechado tem chaves ordenadas: `version`, `policy_version`, `dedup_key`, `thread`, `trigger`, `summary`, `signals`, `classes`, `max_rationale_chars`, `min_confidence`, `request_digest`. SHA-256 usa serializacao canonica UTF-8 com ordem fixa, comprimento dos valores em bytes e formatacao numerica invariant culture; nao depende de `ConvertTo-Json`, ordem de chaves do objeto, whitespace ou runtime PS. O validador exige shape e tipos exatos, vincula campos de policy e classes ao request, recalcula digest e valida a resposta.

Digest fornece integridade de conteudo, **nao autenticidade**: nao prova quem produziu uma resposta. HMAC/autenticacao de provider e decisao futura, junto com custo/teto aprovados. Campos extras ou ausentes geram `SLOWPATH_REQUEST_INVALID`; divergencia de policy gera `SLOWPATH_POLICY_DRIFT`; mismatch do digest gera `SLOWPATH_DIGEST_MISMATCH`. A resposta valida classe, confidence finita, rationale, metadata e rejeita campos extras. Rationale e resumo passam por redacao e rationale recebe `rationale_trust='untrusted-external'`. Confidence abaixo do minimo vira `context_only`/`low-confidence`. Nenhuma resposta torna algo executavel.

Erros do loader: `SLOWPATH_POLICY_PATH_NOT_FOUND`, `SLOWPATH_POLICY_PATH_INVALID`, `SLOWPATH_POLICY_TOO_LARGE`, `SLOWPATH_POLICY_INVALID_JSON`, `SLOWPATH_POLICY_SCHEMA_INVALID`. A policy exige todas as nove chaves, rejeita UNC/device e ancestrais reparse. Validacao usa `SLOWPATH_REQUEST_INVALID`, `SLOWPATH_POLICY_DRIFT`, `SLOWPATH_POLICY_INVALID`, `SLOWPATH_POLICY_DISABLED`, `SLOWPATH_DIGEST_MISMATCH`, `SLOWPATH_CLASS_INVALID`, `SLOWPATH_CONFIDENCE_INVALID`, `SLOWPATH_RATIONALE_INVALID`, `SLOWPATH_METADATA_INVALID` e `SLOWPATH_RESPONSE_INVALID`.

Uma sugestao de REPLAN foi reavaliada: os vetores eram irredutiveis porque autenticidade, serializacao e fail-closed pertencem ao mesmo contrato; a correcao permaneceu nesta unica fatia. A chamada externa nao foi implementada.

## Evidencia

`OrchestrationEventAdmissionSlowPath.tests.ps1`: 97 assertions em Windows PowerShell 5.1 e pwsh. Cobertura inclui digest cross-order e Unicode/HTML, request adulterado, drift de policy, redacao, NaN/Infinity, entradas estritas, CLI e truncamento surrogate-safe. Validacao: Admission 3/3, Event 6/6 nos dois runtimes; package-consistency 17/17; `git diff --check` limpo.
