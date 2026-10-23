# Matriz de Reuso e Invalidação de Evidência (Reuse-First)

**Data:** 2026-10-21  
**Escopo:** OpenCode V2 — Universal Autonomous Orchestration v0.2.0  
**Princípio Central:** *Exact match before semantic similarity. Sem segundo banco de dados.*  

---

## 1. Princípios do Reuso Sistemático

Para eliminar a reexecução redundante de leituras pesadas, testes determinísticos e consultas de IA, a orquestração adota a hierarquia **Reuse-First**:

1. **Correspondência Exata (Tier T0 - Zero Custo):**
   - Antes de qualquer busca por similaridade semântica ou despacho de novos agentes, o sistema consulta se já existe um `ArtifactRef` ou recibo de validação com os mesmos hashes de arquivo e no mesmo commit `HEAD`.
2. **Sem Mecanismos Centrais Paralelos:**
   - Não se cria novo banco relacional, vetor store ou daemon central de memória.
   - O reuso utiliza as estruturas já existentes:
     - Diretório `evidence/` com arquivos JSON tipados.
     - `AI Memory` (`.ai-memory.toml`, workspace `ferramentas`, project `opencode-orchestration`).
     - Metadados de tarefas do Task Kernel (`tasks/*.json`).
3. **Validação Rigorosa de Invalidação:**
   - Evidência só pode ser reutilizada se for considerada estritamente **fresca** e **válida**. Qualquer alteração de código ou expiração temporal invalida o reuso imediatamente.

---

## 2. Matriz de Invalidação de Evidências

| Tipo de Evidência | Identificador Canônico | Critério de Validade (Match Exato) | Condição de Invalidação (Stale Trigger) | Ação Obrigatória ao Invalidar |
|---|---|---|---|---|
| **Resultado de Teste Unitário / Suíte** | Hash SHA-256 dos arquivos de teste + arquivos testados | Commit `HEAD` idêntico + fingerprints dos arquivos coincidentes + idade < 24h | `head_sha` divergiu OU fingerprint de qualquer arquivo do escopo mudou | Reexecução do teste via `DETERMINISTIC_EXECUTION` |
| **Diagnóstico do Capability Doctor** | Hash do binário `opencode` (`binary_sha256`) | Caminho do binário idêntico + SHA-256 do binário coincidente + idade < 7 dias | Versão do binário mudou OU arquivo binário modificado no host | Nova execução de sondagem do Doctor |
| **Parecer do Advisor (`AdvisorConsultationResponse`)** | `intent_hash` (pergunta + problema + restrições) | Problema idêntico + contexto e arquivos relevantes sem alteração | Código-fonte do componente alterado OU nova falha observada | Nova consulta estruturada ao Advisor |
| **Inspeção de Documentação de Biblioteca** | Nome da biblioteca + versão pinada | Versão pinada no `package.json` / `runtime-versions.json` idêntica | Versão da dependência alterada | Nova leitura / pesquisa direcionada |
| **Recibo de Preflight / Decisão** | `task_id` + `objective_hash` | Objetivo idêntico + mesmo commit `HEAD` | Qualquer parâmetro da tarefa alterado | Novo preflight obrigatório |
| **Lease de Escopo de Escrita** | `task_id` + paths | Task ativa no Kernel com lease não expirada | Task concluída, cancelada ou lease TTL expirada | Liberação imediata do lock de escrita |

---

## 3. Algoritmo de Avaliação de Frescor (Fail-Closed)

Implementado no validador `Test-OrchestrationEvidenceFreshness`:

```text
Entrada: Objeto de Evidência, CurrentHeadSha, MaxAgeSeconds

1. Se Evidência for nula:
   Retornar 'invalid-evidence' (fail-closed, refresh_required = true).

2. Se superseded == true:
   Retornar 'stale-superseded' (refresh_required = true).

3. Se head_sha estiver ausente ou vazio:
   Retornar 'invalid-evidence' [missing-head-sha] (fail-closed, refresh_required = true).

4. Se timestamp estiver ausente ou vazio:
   Retornar 'invalid-evidence' [missing-timestamp] (fail-closed, refresh_required = true).

5. Se CurrentHeadSha for fornecido e CurrentHeadSha != head_sha:
   Retornar 'stale-head-mismatch' (refresh_required = true).

6. Se timestamp for ilegível:
   Retornar 'invalid-evidence' [timestamp-unparseable] (refresh_required = true).

7. Se (AgoraUtc - timestamp) > MaxAgeSeconds:
   Retornar 'stale-age-exceeded' (refresh_required = true).

8. Se todas as checagens passarem:
   Retornar 'fresh' (ok = true, refresh_required = false).
```

---

## 4. Integração com o Task Kernel para DONE

- Todo fechamento de tarefa através de `Complete-OrchestrationTask` no Kernel inspeciona as evidências anexadas.
- Se a lista contiver itens com veredito diferente de `'fresh'`, o Kernel recusa a transição e emite `COMPLETION_GATE_FAILED` com o motivo `'EVIDENCE_STALE_BLOCKED'`.
- Isso garante que nenhum falso DONE seja emitido com base em testes passados em commits antigos ou evidências desatualizadas.
