# Mellum 2.1 Local Benchmark — SPEC (issue #57)

> **Header obrigatório (fase SPEC): SEM download de pesos nesta fase. SEM execução local nesta fase. SEM auto switch de modelo. V2-only. Default routing intacto.**

- Issue: #57 (candidato `JetBrains Mellum 2.1` como modelo local opcional, advisory-only, opt-in explícito por run).
- Escopo desta SPEC: SOMENTE definir fixtures, metodologia, métricas, feasibility, recomendação por papel e go/no-go. Nenhum download de pesos, nenhuma instalação (llama.cpp/vLLM/Ollama), nenhuma alteração de provider/policy/registry/template/agente, nenhuma chamada de modelo, nenhum commit, nenhum toque no GitHub.
- Estado verificado (usar como fato nesta SPEC, sem re-pesquisa): coleção oficial com 2 itens; GGUF oficial JÁ lançado (blog coming-soon desatualizado); AWQ/GPTQ oficial NÃO existe; MTP head coming soon; HW oficial sem tabela (só "one H200" + tamanhos de arquivo); estimativas derivadas marcadas como não-oficiais; benchmarks do card são self-reported (não validados).

## 1. Verified model specs (links oficiais — única fonte de números permitida)

Pesquisa verificada confirmou existência oficial. Tabela — únicos números permitidos nesta SPEC:

| Campo | Valor verificado |
|---|---|
| Model ID | `JetBrains/Mellum2.1-12B-A2.5B-Thinking` (BF16) |
| Coleção oficial | 2 itens (BF16 + GGUF) |
| Arquitetura | MoE 12B total / 2.5B ativos; 64 experts, 8 ativos; 28 layers |
| Licença | Apache-2.0 |
| Contexto | 131072 tokens |
| Sampling recomendado | `temp 0.6`, `top-p 0.95`, `top-k 20` |
| vLLM | `--reasoning-parser qwen3` |
| GGUF Q4_K_M | 8.1 GB (recomendado oficial) |
| GGUF Q8 | 12.9 GB |
| GGUF Q6 | 10.9 GB |
| GGUF MXFP4 | 7.0 GB |
| BF16 | 24.3 GB |
| HW oficial | Sem tabela; apenas "one H200" + tamanhos acima |
| AWQ / GPTQ oficial | NÃO existe |
| MTP head | coming soon (não usar em plano) |

URLs oficiais:

- https://huggingface.co/collections/JetBrains/mellum21
- https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking
- https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking-GGUF
- https://blog.jetbrains.com/ai/2026/10/mellum2-1-gets-to-work-a-fast-open-model-for-coding-agents/

Regras: nenhum número de tok/s, VRAM em execução, latência ou custo além da tabela acima pode aparecer em plano ou relatório sem run real anexado. Benchmarks do card (self-reported) NÃO contam como evidência — exigem reprodução local antes de qualquer claim. Qualquer estimativa de VRAM/throughput fora da tabela é rotulada `DERIVADO_NAO_OFICIAL` e nunca sustenta go/no-go sozinha.

## 2. Fixtures e metodologia (Golden Workflows #30 + DecisionProvider T13–T22)

Mesmo padrão de `DECISION-1-BENCHMARK-79-SPEC.md` e `MODEL-ROUTER-vNext-SPEC.md §7` (`docs/specs/MODEL-ROUTER-vNext-SPEC.md:143-148`):

- **Base reutilizada:** mesmos Golden Workflows #30 (GW-TRIVIAL / GW-MULTI / GW-RECOVERY / GW-GITHUB / GW-ADVISORY — curto, SPEC+PLAN longo, failure→recovery, rotation, reuse, Jev-fallback, bloqueio seguro) + casos DecisionProvider T13–T22 onde aplicável (admissão, recusa de authority, reserva de model-override, filtro de overreach, fallback honesto).
- **Classes de tarefa cobertas:** repo-nav, small-fix, tests, tool use, recovery.
- **Enquadramento:** candidato é advisory-only, opt-in explícito por run, atrás do mesmo grant-gate local que qualquer advisor; `high-risk` nunca consulta candidato; `default routing` = baseline determinístico atual, intacto em todos os runs; sem delegar policy/autorização ao modelo local.
- **Reprodutibilidade (§1 do aceite):** cada run registra `run_id`, fixture hash, `evidence_refs` (ou `NO_EVIDENCE_YET`), quant usado, janela de contexto usada, backend + versão, comandos exatos, env (GPU/VRAM/driver/backend), envelope completo (`source/reason/confidence/blocked`); `≥ 3 runs` por fixture (§3); relatório inclui fixtures, env, comandos, métricas e IC — sem isso o run é `NO_EVIDENCE_YET`, nunca evidência.

## 3. Feasibility em HW real/remoto + comparação (com IC onde viável)

### 3.1 Tabela oficial vs derivada (§2 do aceite)

| Linha | Conteúdo | Status |
|---|---|---|
| Tamanhos de arquivo (§1) | Q4_K_M 8.1 / Q8 12.9 / Q6 10.9 / MXFP4 7.0 / BF16 24.3 GB | OFICIAL |
| "one H200" | única afirmação oficial de HW | OFICIAL (sem tabela) |
| Qualquer VRAM em execução, tok/s, latência por janela | somente após spike real | `BLOCKED_SEM_RUN` nesta SPEC |
| Qualquer estimativa de cabe em 24GB/16GB/8GB | derivada | `DERIVADO_NAO_OFICIAL` — nunca sustenta promoção |

### 3.2 Protocolo de feasibility (ordem obrigatória)

1. **Começar com contexto reduzido** (não 131k no primeiro run).
2. **3 janelas obrigatórias:** 8k / 32k / 114k tokens — cada janela mede `tok/s` + pico de VRAM como pré-requisito para qualquer experimento opt-in futuro (sem criar default; default segue expressamente FORA DE ESCOPO desta SPEC).
3. **Spike antes de qualquer experimento opt-in futuro:** nenhum experimento opt-in futuro (sempre por run explícito, nunca recorrente, nunca default) sem o spike `tok/s + pico VRAM` publicado por janela e por quant. Default segue expressamente FORA DE ESCOPO desta SPEC — esta SPEC não cria default nem plano de default.
4. **HW real/remoto:** runs em HW real documentado (local ou remoto autorizado por ambiente); sem HW = feasibility `BLOCKED`, sem exceção.

Métricas obrigatórias por run (tabela — sem valores nesta SPEC, só runs reais futuros preenchem):

| Dimensão | Métrica |
|---|---|
| Qualidade | `pass rate` por fixture vs gold labels independentes com denominadores explícitos; `false-success rate` (claim de sucesso sem DONE verificado = falha); calibração prevista vs observada |
| Custo | `tokens-to-DONE`; `cost-to-DONE` (tokens + wall-clock + escalations — padrão MODEL-ROUTER §7); `retries` contabilizados |
| Latência | `tok/s` por janela (8k/32k/114k); `p50/p95` por chamada; latência do candidato medida separada do despacho; nunca bloqueia (fallback determinístico) |
| Recursos | pico VRAM/RAM por janela e por quant; backend + versão |
| Primária | **`cost-to-DONE`** — somente demonstrável em experimento controlado até DONE (§4); replay/shadow nunca mede `cost-to-DONE` causal |

- Estatística: `≥ 3 runs`; reportar média + IC (ex. t-Student ou bootstrap) onde n permitir; n pequeno => reportar range honesto, sem alegar significância. Para promoção vale somente a comparação pareada agregada de §4.2, nunca contagem de runs.
- Vendor numbers (card/blog) não validados: qualquer comparação contra número do vendor é rotulada `SELF_REPORTED_UNVALIDATED` até reprodução local com `≥ 3 runs`.

## 4. Recomendação por papel, go / no-go, rollback, default inalterado

### 4.1 Recomendação explícita por papel (§3 do aceite — SOMENTE após runs; abaixo o formato, sem valores)

| Papel | Veredito nesta SPEC | Critério futuro para mudar |
|---|---|---|
| Explorer | `BLOCKED_SEM_RUN` — leitura não justifica escala sem tok/s+VRAM reais | spike 8k/32k por quant + comparação pareada agregada (§4.2) com pass rate repo-nav agregado não inferior ao baseline |
| Coder | `BLOCKED_SEM_RUN` — small-fix/tool-use exigem prova até DONE | comparação pareada agregada (§4.2): `cost-to-DONE` total agregado menor com pass rate agregado não inferior |
| Tester | `BLOCKED_SEM_RUN` — assurance a jusante; escala é de escopo, não de modelo | idem Coder + zero false-success |

Nenhum papel recebe veredito diferente de `BLOCKED_SEM_RUN` nesta fase. **Sem auto switch** em qualquer cenário (§4 do aceite): o modelo nunca se torna default, nunca é selecionado automaticamente por router/policy, e qualquer uso futuro é opt-in explícito por run com gate humano.

### 4.2 Promoção (todos obrigatórios, SOMENTE via experimento controlado separadamente autorizado)

Braços baseline vs candidato nos mesmos tasks até DONE, preservando permissões/DONE; comparação **pareada agregada**: mesmas fixtures, mesmos runs pareados por fixture/run, somando custo total (`cost-to-DONE` total inclui falhas, retries e escalations — sem excluir run desfavorável); promoção exige **redução agregada** de `cost-to-DONE` total **+ não inferioridade agregada** de pass rate (nunca contagem de runs tipo `≥ 2/3`); tratamento de outliers pré-registrado (winsorização com limite declarado antes dos runs, ou análise de sensibilidade com/sem outlier); resultado **inconclusivo** se o IC da diferença agregada cruzar zero ou se 1 regressão extrema anular os ganhos agregados; zero violação de authority/cota/DONE; zero false-success não detectado; spike `tok/s + pico VRAM` publicado nas 3 janelas; promoção via gate humano explícito, por papel (§4.1), nunca global automática. **Promoção BLOCKED até esse experimento existir e ser autorizado.**

### 4.3 Reversão (qualquer um)

Violação de authority/cota/DONE; `WRONG/SUBOPTIMAL` recorrente; false-success; VRAM/latência fora do envelope aprovado para o ambiente; custo acima do aprovado.

### 4.4 Rollback = remover o candidato

Voltar ao baseline determinístico atual, sem debate, sem migração de estado; nenhuma dependência do modelo local em nenhum papel.

### 4.5 Default routing intacto (§4 do aceite)

O despacho padrão continua o baseline atual em todas as fases; o candidato só aparece como probe explícita opt-in por run, nunca como rota default; **no automatic model switch** — sem paid/silent switch, sem promoção por replay/shadow, sem delegar policy/autorização ao modelo.

## 5. Fora de escopo desta fase

Baixar pesos, instalar backend (llama.cpp/vLLM/Ollama), executar qualquer run, editar provider/policy/registry/template/agente, commitar, tocar GitHub ou `docs/specs/INDEX.md`.
