# Nemotron Embed / Rerank / Parse p/ AI Memory — SPEC piloto (Issue #147 — UNVERIFIED_ID)

> **Header de fase (SPEC): SEM ADOPT generalizado. HOLD. Piloto reversível e isolado. SEM migração irreversível. SEM reindex produtivo. SEM indexar credenciais. SEM credencial paga/produtiva sem autorização explícita por ambiente. SEM hardcode de endpoint/model ID/preço em código, policy, registry, template ou agente.**

- Issue-alvo: `#147` — **UNVERIFIED_ID**: `ai-memory#147` aponta para outro PR (Zen/Go) na verificação disponível; ID da issue-alvo desta SPEC **a confirmar**. Nenhuma implementação, nenhum probe, nenhum commit, nenhum toque em GitHub ou em `docs/specs/INDEX.md` por esta SPEC.
- Escopo desta SPEC: SOMENTE definir família, licenças, baseline, fixtures, metodologia por modalidade/tamanho, métricas, comparação, go/no-go e rollback. Nenhum código, nenhum probe `.ps1`, nenhuma alteração de provider/policy/registry/template/agente, nenhuma chamada de API (paga ou não), nenhum download de pesos, nenhum re-embed produtivo.
- Estado de referência RES-147 (usar como fato nesta SPEC sem re-pesquisa; números do vendor = `SELF_REPORTED_UNVALIDATED` até reprodução local com `≥ 3 runs`):
  - Família 20–21/10/2026: Embed 8B (4096d) + Embed 1B (2048d + variante NVFP4), Rerank 8B cross-encoder, Parse 631M.
  - Licença: OpenMDW-1.1 (uso comercial ok, sem warranty, patent-retaliation); NIM sob licença NVIDIA (termos próprios, reler no dia do run).
  - AI Memory hoje: embeddings via openai / openai-compat / local / voyage / google / copilot (exemplo Nemotron-3-Embed-1B já citado); rerank/parse **sem integração nativa**.
  - Texto congelado: índice atual é texto-only e reutilizável; imagem exige reindex; **triple change (modelo/dimensão/tokenizer) força re-embed** — nunca re-embed silencioso.
  - HW: Linux CUDA, Ampere / Blackwell / Hopper; NIM 2.4 com lista de GPUs suportadas (reler no dia); Rerank referência `1750ms / 500` em H100 (não é claim de latência sem run local).
  - Métricas vendor: ViDoRe / MIRACL / Rerank / ParseBench / agente −13% tokens — todas `SELF_REPORTED_UNVALIDATED` até reprodução.
  - Custo: Dev grátis (16 GPUs, limites do programa) / prod `~$4.5k/GPU/ano` ou `~$1/h` + trial 90d — reler no dia, nunca herdar tabela.
  - Privacidade: self-host sem egress (quando comprovado por run); hosted sai do perímetro; **nunca indexar credenciais** (segredos, tokens, chaves, connection strings) em nenhum braço.

## 1. Problema

AI Memory não tem integração nativa de rerank/parse e cobre Nemotron em embeddings só via caminho genérico openai-compat (exemplo 3-Embed-1B). A família nova promete melhor retrieval (embed + rerank cross + parse), mas traz riscos materiais: triple change invalida índice, imagem exige reindex, licença OpenMDW-1.1 tem patent-retaliation, NIM tem licença própria, hosted vaza dado, e qualquer migração irreversível ou indexação de credencial seria dano permanente. Sem SPEC com HOLD, baseline e rollback, um piloto vira ADOPT silencioso.

## 2. Objetivo e critério de sucesso

Avaliar **se** Embed/Rerank/Parse Nemotron melhoram retrieval do AI Memory de forma mensurável, em piloto isolado e reversível, sem tocar produtivo.

Sucesso = decisão go/no-go por modalidade com evidência pareada (baseline vs candidato, mesmas fixtures, mesmos runs), rollback limpo, zero credencial indexada, zero migração irreversível. **Sem ganho mensurável, sem adoção.**

## 3. Escopo e não objetivos

### Incluído

- Piloto por modalidade: (a) Embed 8B vs 1B (incl. NVFP4) vs baseline; (b) Rerank 8B como estágio a jusante; (c) Parse 631M como ingestão alternativa. Comparação **por modalidade e por tamanho**, nunca agregada cega.
- Baseline + fixtures versionadas, metodologia, métricas, go/no-go por modalidade, rollback.
- Regras de privacidade (sem credenciais, sem produtivo sem autorização) e de licenciamento (reler OpenMDW-1.1 + NVIDIA no dia).

### Fora do escopo (não autorizar)

- **Sem ADOPT generalizado.** Nenhum default alterado, nenhum router/policy apontando para Nemotron, nenhum hardcode de endpoint/ID/preço.
- **Sem migração irreversível.** Nenhum re-embed produtivo, nenhum drop do índice atual, nenhum schema change permanente, nenhum reindex de imagem fora de fixture.
- **Sem credenciais no índice.** Segredos nunca entram em fixture nem em índice piloto; detecção = FAIL + descarte.
- **Sem produtivo sem autorização.** Runs só em fixtures locais/sintéticas salvo autorização explícita por ambiente.
- **Sem promoção por replay/shadow.** Replay offline só valida formato (`SYNTHETIC_FORMAT_ONLY`); nunca mede ganho causal, nunca promove.

## 4. Invariantes

1. **HOLD por padrão.** Tudo `BLOCKED_SEM_RUN` até experimento controlado autorizado existir.
2. **Baseline intacto.** Índice texto-only atual reutilizado; triple change nunca silenciosa — qualquer troca de modelo/dimensão/tokenizer é novo experimento, não upgrade in-place.
3. **Piloto isolado.** Índice piloto separado, descartável, com prefixo/namespace próprio; rollback = apagar índice piloto.
4. **Privacidade primeiro.** Self-host sem egress só vale com prova por run; hosted = dado sai do perímetro; credencial indexada = FAIL imediato + rollback.
5. **Licença relida no dia.** OpenMDW-1.1 (patent-retaliation, sem warranty) + licença NIM verificadas no dia de cada run autorizado.
6. **Sem auto switch.** Candidato nunca vira default, nunca é selecionado automaticamente; uso futuro só opt-in explícito por run com gate humano.

## 5. Baseline + fixtures versionadas

- **Baseline:** configuração atual do AI Memory (provider de embedding vigente + sem rerank/parse nativos), pinada por run (provider, modelo, dimensão, tokenizer, revisão/digest quando observável).
- **Fixtures (versionadas, hash registrado):** conjunto curto de ingestão (texto limpo, sem segredos) + queries com gold labels independentes (expectativa pré-registrada, sem consultar candidato) + 1 fixture negativa de credenciais sintéticas (`sk-SYNTHETICSECRET` e equivalentes — deve NUNCA aparecer no índice).
- **Modalidades:** Embed (8B 4096d / 1B 2048d / 1B NVFP4), Rerank 8B (só sobre top-K do baseline ou do embed candidato, K pré-registrado), Parse 631M (só ingestão alternativa sobre os mesmos docs). Cada modalidade = experimento próprio; sem herdar veredito de outra modalidade ou de outro tamanho.
- **Braços:** baseline vs candidato, mesmos tasks/queries, mesmos runs pareados (`≥ 3 runs` por fixture), mesmos K/limites, preservando permissões/DONE do orquestrador onde aplicável.

## 6. Metodologia e métricas

- **Runs pareados:** `≥ 3 runs` por fixture; cada run registra `run_id`, fixture hash, modelo + dimensão + tokenizer + digest/revisão, provider/endpoint, licença lida no dia, GPU/runtime ou hosted, `evidence_refs` (ou `NO_EVIDENCE_YET`), comandos exatos.
- **Métricas obrigatórias por run e por braço (tabela — sem valores nesta SPEC):**

| Dimensão | Métrica |
|---|---|
| Qualidade | `recall@K / nDCG@K` vs gold labels independentes, denominadores explícitos; `false-hit rate` (claim sem evidência = falha) |
| Parse | fidelidade de extração (tabela/texto/layout) vs gold, taxa de documento falhado |
| Custo | `tokens/docs-to-ingest`, `cost-to-index` (pricing do dia) + `latência de indexação`; `cost/query` + `p50/p95` por chamada |
| Latência | `p50/p95` por modalidade, medida separada; referência vendor (`1750ms/500` H100) nunca é claim local |
| Falhas | erros, timeouts, truncamento (dimensão/tokenizer), degradação NVFP4 vs FP |
| Privacidade | binário passa/falha: zero segredo no índice (fixture negativa); egress comprovado ou não (self-host vs hosted) |
| Licença | OpenMDW-1.1 + NVIDIA relidas no dia (sim/não + referência) |

- **Estatística:** média + IC (ou range honesto se n pequeno); promoção só por comparação pareada agregada (§7), nunca por run isolado ou número do vendor.
- **Vendor numbers:** ViDoRe/MIRACL/Rerank/ParseBench/agente −13% tokens = `SELF_REPORTED_UNVALIDATED` até reprodução com `≥ 3 runs`; nunca sustentam go/no-go sozinhos.

## 7. Go / no-go por modalidade, reversão, rollback

### 7.1 Vereditos nesta SPEC (sem valores — todos bloqueados)

| Modalidade | Veredito | Critério futuro para mudar |
|---|---|---|
| Embed 8B | `BLOCKED_SEM_RUN` | melhoria mensurável agregada em ≥1 dimensão pré-registrada (recall/nDCG) + não-inferioridade nas demais dentro das margens pré-registradas + custo/latência dentro dos budgets pré-registrados, em fixtures de embedding |
| Embed 1B (incl. NVFP4) | `BLOCKED_SEM_RUN` | idem + sem degradação material NVFP4 vs precisão plena dentro da margem pré-registrada |
| Rerank 8B | `BLOCKED_SEM_RUN` | melhoria mensurável agregada sobre top-K fixo (K pré-registrado) em ≥1 dimensão pré-registrada + não-inferioridade nas demais dentro das margens pré-registradas + custo/latência dentro dos budgets pré-registrados; sem reordenar sem prova |
| Parse 631M | `BLOCKED_SEM_RUN` | melhoria mensurável agregada em ≥1 dimensão pré-registrada (fidelidade ou taxa de falha) + não-inferioridade nas demais dentro das margens pré-registradas, sem resíduo de schema |

Nenhuma modalidade recebe veredito diferente de bloqueado nesta fase. Margens de não-inferioridade, dimensões-alvo e budgets de custo/latência são pré-registrados antes dos runs (parte do critério futuro; sem pré-registro, sem promoção). Promoção exige experimento controlado separadamente autorizado, por modalidade e por tamanho, com melhoria mensurável agregada demonstrada em ≥1 dimensão pré-registrada + não-inferioridade nas demais + budgets respeitados + zero violação de privacidade/DONE + gate humano explícito. **Sem ganho mensurável, sem adoção.** **Inconclusivo** se o IC da diferença cruzar zero ou se 1 regressão extrema anular os ganhos.

### 7.2 Reversão (qualquer um)

Violação de privacidade (credencial no índice, egress não autorizado, hosted com dado real); triple change silenciosa; re-embed produtivo sem autorização; custo acima do aprovado; latência p95 estourando budget sem fallback; degradação NVFP4/parse sem fallback; licença não confirmada no dia.

### 7.3 Rollback = apagar o piloto

Voltar ao índice/baseline atual sem debate: descartar índice piloto (namespace separado), remover config de run, nenhuma dependência permanente de endpoint/provider/pesos. Rollback não toca flags, grants, agents ou pins. Pós-rollback, verificação binária: índice produtivo inalterado (hash) + fixture negativa ausente.

## 8. Requisitos e aceite

| ID | Critério |
|---|---|
| AC-01 | Baseline + fixtures versionadas com hash; comparação por modalidade e por tamanho (sem herança cross-modalidade/tamanho). |
| AC-02 | Zero credenciais indexadas (fixture negativa PASS) e zero dado produtivo sem autorização explícita por ambiente. |
| AC-03 | Nenhuma migração irreversível: índice produtivo inalterado, sem triple change silenciosa, sem reindex de imagem fora de fixture. |
| AC-04 | Adoção incremental só com ganho mensurável agregado (`≥ 3 runs` pareados, IC/range honesto); vendor numbers nunca decidem sozinhos. |
| AC-05 | Rollback limpo verificado (índice piloto descartável, produtivo intacto). |
| AC-06 | `git diff --check` limpo; só este arquivo tocado; nenhum commit por esta SPEC. |
| AC-07 | Issue-alvo confirmada (resolver UNVERIFIED_ID) antes de qualquer run autorizado. |

## 9. Segurança e modos de falha

Cobrir: credencial sintética vazando para índice (FAIL + descarte); fixture com segredo real (recusar run); hosted com dado sensível (recusar sem autorização + prova de egress); triple change não declarada (FAIL); reindex de imagem fora de fixture (recusar); NVFP4 degradando sem registro (FAIL); Parse alterando schema (recusar); licença NIM/OpenMDW não relida no dia (run inválido); tentativa de tornar candidato default (recusar; gate humano decide). Nenhum log de piloto carrega segredo ou texto livre sensível.

## 10. Baseline de runtime e limitações observadas

- Pins vigentes em `source/registry/runtime-versions.json`; loader fail-closed.
- Superfície V2 assumida: `agents` + `permissions` + `subagent_depth = 1`.
- 8 features V2 `hold-unproven` — esta SPEC não alega prova nem promove nenhuma.
- HW/latência/custo vendor (Ampere/Blackwell/Hopper, NIM 2.4, `1750ms/500` H100, `$4.5k/GPU/ano` / `$1/h`, Dev 16 GPUs, trial 90d) são referência a reler no dia, nunca claim local.

## 11. Classe e decisão de escopo

Classe: `FEATURE_REEVALUATION` (piloto de retrieval, sem autoridade). Mudança de default, flag, grant, runtime, permissão, pin ou índice produtivo exige gate humano e prova específica; **esta SPEC não autoriza nenhuma dessas alterações**. Não criar ADR até haver decisão durável nova. Ativação de qualquer run com custo/egress em ambiente real é decisão de operador com evidência, nunca inferência desta SPEC. Resolver o BLOCKER UNVERIFIED_ID (§header, AC-07) antes de autorizar runs.
