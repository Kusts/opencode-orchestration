# Capability Advisory Observability — Plano Revisado Fase 2G (2026-10-09)

Branch: `feat/capability-advisory-observability-phase-2g`
(base `b38c92bc8b3ab334a9dffad609f3515350336061`).
Worktree **isolado**: `D:/projetos/opencode-orchestration-2g`.
Modo: **SHADOW + ADVISORY** (inalterado). Sem promoção a Active, sem troca de
flags, sem tocar o Autonomous Core.

**Status deste documento:** a escrita do plano foi o **primeiro entregável**
deste request e está **concluída**; a partir desta revisão ele passa a ser o
**contrato de execução deste mesmo request** — implementação, suíte,
validação, review e (se disponíveis e verdes) closure acontecem **neste
request**, não em um próximo. As seções §3–§9 são o contrato que a execução
em curso deve satisfazer; a situação de cada gate está em §4. Esta revisão
(2026-10-09) incorpora os findings de review independente: **sem correlação
entre streams** (§2.3, §3), leitor limitado por bytes, raiz JSON somente
objeto, duplicata em chave decodificada e schema do relatório (§5.1; a
primeira revisão fixou `schema_version` 2, a revisão 2 abaixo bumpou para 3).

**Revisão 2 (2026-10-09, após a segunda rodada de review independente).**
Findings materiais corrigidos no coletor/suíte (recorte: somente estes 3
arquivos; nada de core, flags, adapters, cache ou escrita em `evidence/`):

1. **`total_bytes` virou UM orçamento compartilhado** por todos os arquivos **e**
   pelos dois streams (antes cada arquivo recebia o cap cheio). O restante é
   passado a cada leitor e o consumo real é debitado; esgotamento é disclosure
   (`inputs.bytes_cap_reached` + arquivo `truncated`/`LIMIT_EXCEEDED`) e os
   candidatos nunca abertos são contados (`inputs.files_omitted_by_records_cap`).
2. **Enumeração de candidatos e array de detalhes de arquivo limitados pelo cap
   `files`**: a entrada não é mais materializada por inteiro (no máximo `files`
   caminhos distintos ficam retidos, os menores na ordem ordinal) e omissão
   virou **contagem** (`files_skipped_by_limit`, `files_omitted_by_records_cap`,
   `candidate_paths_seen`) — nunca entrada sem limite no relatório. Quando o cap
   de `records` é atingido, o resto do arquivo é examinado **sem projeção**
   (para `lines_read` ser verdadeiro), as linhas omitidas são contadas
   (`lines_omitted`) e os candidatos seguintes não são abertos.
3. **Detecção de chave duplicada agora é scanner lexical de passada única**
   (sem regex): custo O(n) no tamanho da linha, sem backtracking dependente de
   engine. Fixture adversária com milhares de aspas escapadas e tempo limitado.
4. **Determinismo entre processos**: todos os mapas serializados são `[ordered]`
   (inclusive `metrics` e os itens de `files[]`/`items[]`) e a suíte compara o
   JSON deste processo com o de um **processo filho separado** — nos dois
   runtimes (PS 5.1 ↔ PS 7). Esse teste pegou um bug real: as entradas de
   `metrics` ainda eram hashtable sem ordem.
5. **`lines_read` passa a contar toda linha REALMENTE lida**: válidas, vazias
   (inclusive as do fim do arquivo), malformadas, a linha-sonda que revela um
   cap e a linha parcial cortada pelo orçamento de bytes. Também foi corrigida
   uma linha fantasma vazia que o leitor emitia no EOF após CRLF final.
6. Teste da lista de métricas corrigido (era vacuo por ordem de inicialização)
   e travado em **exatamente 7** entradas, com igualdade de conjunto.
7. **Schema `schema_version` 3** (§5.1) com o delta documentado.

**Revisão 4 (2026-10-09, após a rodada final de review independente).**
Findings materiais corrigidos no coletor/suíte (mesmo recorte: somente estes 3
arquivos; nada de core, flags, adapters, cache ou escrita em `evidence/`):

1. **O cap de arquivos virou UM orçamento compartilhado pelos dois streams.**
   Antes cada stream (resolver e observação) recebia o cap `files` cheio: com
   `files=1`, um arquivo de cada stream podia ser lido ao mesmo tempo e o array
   `inputs.files` podia terminar com mais entradas que `inputs.limits.files` — o
   relatório exibia mais detalhes de arquivo que o limite que ele mesmo
   declarava. Agora a enumeração de candidatos é **global**
   (`Select-AdvisoryCandidates`): os caminhos dos dois streams concorrem aos
   mesmos `files` slots (ordem ordinal, desempate determinístico por kind),
   `inputs.files` nunca passa de `files` entradas e o candidato omitido vira
   **contagem** (`files_skipped_by_limit`) — precisa mesmo quando o omitido
   seria rejeitado ou recusado, porque a decisão de omissão é anterior a
   qualquer IO (não depende de o caminho existir ou ser legível). Testes
   cross-stream novos: `files=1` com um resolver + uma observação (nos dois
   sentidos da ordem ordinal), candidato inexistente como selecionado, 4
   candidatos com `files=2` provando que a escolha não privilegia stream, e o
   mesmo caminho pedido nos dois streams.
2. **Fronteira exata do orçamento de bytes (`total_bytes`).** O leitor confundia
   "fim do arquivo" com "fim do orçamento": uma linha JSON válida de exatamente
   `total_bytes` — com ou sem terminador final — era descartada como
   `LIMIT_EXCEEDED` (**falso truncation**), escondendo um registro real. Agora o
   leitor distingue EOF **exatamente** no orçamento (a linha final está completa
   e é aceita) de bytes **além** do orçamento (truncamento real, disclosed por
   `LIMIT_EXCEEDED` + `bytes_cap_reached`), **sem consumir ou alocar byte além do
   orçamento**: a distinção usa `Position`/`Length`, que são metadados do stream.
   Stream sem `Length`/seek ou com falha de IO cai no lado conservador
   (truncar e disclosed, nunca aceitar linha possivelmente incompleta).
   Fixtures de fronteira novas: linha sem LF, com LF e com CRLF no limite exato
   (todas aceitas, sem `bytes_cap_reached`) e `cap+1` — com e sem linha completa
   anterior — disclosed/truncado.
3. **Teste de performance robusto.** O limite absoluto `< 20 s` falhava por ruído
   de host em PS 5.1 (medido nesta rodada: 22 s, 24 s e 44 s sob carga para o
   mesmo trabalho, sempre com os mesmos 1.500 registros aceitos), sem indicar
   regressão de custo. A regressão passou a ser medida por **escala** contra uma
   baseline menor (1/6 do volume para 1.500 chaves distintas; 1/4 para 20 mil
   linhas vazias): a taxa por chave/linha da amostra grande não pode passar de
   3× a da baseline — comportamento quadrático daria ~6× com esses fatores — e o
   tempo absoluto continua verificado com margem generosa (90 s / 60 s / 30 s)
   como rede de segurança contra laço infinito. **Nenhum código de aplicação foi
   alterado para esconder lentidão**: as otimizações já existentes (leitor
   próprio por bytes, `ArrayList`/`HashSet` sem `+=` em array, scanner lexical de
    passada única sem regex) foram preservadas e agora ficam protegidas por uma
    medição que não oscila com a carga do host.
4. **Seleção sem materialização proporcional à entrada.** A função recebe
   diretamente os dois arrays de caminhos, percorre cada stream sem `@(...)` ou
   array intermediário de objetos e retém no máximo `files` pares distintos.
   A contagem é `candidate_paths_seen - retained_distinct`: repetições não
   consomem slots, mas contam como ocorrências omitidas, inclusive quando o par
   repetido foi retido. Isso evita a contagem dependente da ordem que ocorria
   quando uma repetição era observada antes de o candidato ser expulso. Testes
   verificam permutações e incluem uma guarda contra a materialização anterior.
   Review final deste recorte: **APPROVED** (inspeção estática; não substitui a
   suíte).

---

## 0. Contexto de execução, isolamento e workflow

- **Worktrees** (`git worktree list`): este checkout
  (`.../opencode-orchestration-2g`) está em
  `feat/capability-advisory-observability-phase-2g` @ `b38c92b`. O worktree
  principal compartilhado (`.../opencode-orchestration`) está no **mesmo**
  `b38c92b`, mas movido para a branch de aceitação
  `acceptance/autonomous-core-v0.1.2-2026-10-09`, com **mudanças sujas de
  adapter** pendentes. Esse worktree principal é **deixado intocado**; o
  trabalho 2G ocorre só no worktree isolado, que está **limpo**
  (`git status -s` vazio aqui).
- **Baseline/remote**: `origin/master` = `b38c92bc…` — o remote master foi
  *fetchado* e **coincide com o baseline** desta branch. Não há divergência
  de base a resolver.
- **Ajuste explícito de workflow (2G vs 2F)**: diferente do 2F (que avançou
  até PR/merge), **neste request a fase 2G é trabalho local de
  implementação/revisão dentro do worktree isolado** — código, suíte,
  evidência e review acontecem aqui.
  - Nenhum push, PR ou merge foi executado ainda. O usuário pediu abertura de
    PR; ela segue como etapa de publicação a partir desta branch isolada após
    commits e revalidação da base concorrente, conforme
    `docs/github-lifecycle-policy.md` §1–§3. Nenhum merge é presumido.
  - **Checks de GitHub não podem ser afirmados localmente.** Um resultado de
    CI só existe no GitHub, no HEAD do PR; localmente só há suites e
    `git diff --check`. Nada aqui declara CI verde.
  - Consequência para o fechamento: closure já registrado em
    `docs/audits/opencode-capability-phase-2g-closure-2026-10-09.md` com
    veredito `PARTIAL — INSUFFICIENT_REAL_WORLD_DATA`, resultados de teste,
    falhas ambientais e limitações de review/proveniência. Hash de merge e
    resultados finais de CI só poderão entrar após PR/merge, via follow-up.
- **Arquivo de closure (finalizado):**
  `docs/audits/opencode-capability-phase-2g-closure-2026-10-09.md` (nome pedido
  pelo usuário); lacunas documentadas, sem alegar PR/CI/merge.

---

## 1. Objetivo e revisão explícita do escopo 2G fornecido

O escopo 2G como fornecido/intuído (herdado do arco 2D→2E→2F) seria
“**observabilidade de routing**: medir se a recomendação do resolver adere ao
que realmente acontece em runtime e produzir métricas de qualidade”. A
revisão honesta contra os **fatos verificados** (§2) **reduz** esse escopo ao
que é **factível e verificável offline**:

> **2G entregável** = um **coletor read-only/offline** que lê
> (a) o **JSONL sanitizado do resolver** (`resolver-YYYYMMDD.jsonl`,
> produção manual via CLI) e (b) **registros de observação explicitamente
> fornecidos** — aceitos **somente se provenientes** (`provenance: supplied`)
> e sempre rotulados `SUPPLIED_UNVERIFIED`. **Nenhuma correlação é feita
> entre os dois streams**: não existe escopo comum (projeto/sessão/run) nem
> proveniência autenticada que justifique emparelhar linhas. Os dois blocos
> são reportados **em separado**, todo campo de observação fica
> `NOT_OBSERVABLE`, e as contagens de chaves **não correlacionadas** ficam
> explícitas. Sem observações externas reais, o resultado **só pode ser
> PARCIAL**.

Fora do que foi dito acima, tudo permanece como no 2F: resolver `2d-shadow-1`
consultivo, Planner/Kernel com autoridade, flags OFF, Autonomous Core
intocado.

**Restrições duras do escopo (revisão):**

- **NÃO** alegar volume de tarefas reais (ex.: “20 tarefas reais”), prova de
  runtime, merge, PR ou CI.
- **NÃO** criar, ler pela rede, ativar ou correlacionar nada no runtime
  ativo (`~/.config/opencode`), nem acessar projetos externos.
- **NÃO** tratar telemetria de kernel como prova de consulta ao resolver, nem
  dela derivar o agente/skill/MCP que o Planner/runtime **de fato** selecionou
  ou desfechos produtivos (§2.2, §2.4).

---

## 2. Fatos verificados de repositório (baseline)

Verificado nesta sessão por leitura de arquivo (sem execução de suites):
`scripts/v3/capability-resolve.ps1`, `scripts/v3/lib/CapabilityResolver.ps1`,
`scripts/v3/lib/CapabilityObservability.ps1`,
`scripts/v3/lib/OrchestrationTaskKernel.ps1`,
`scripts/v3/lib/CapabilitySchema.ps1`,
`source/registry/capability-flags.json`.

### 2.1 Resolver JSONL — produção MANUAL via CLI (não autônoma)

`scripts/v3/capability-resolve.ps1` (exit 0 fail-safe; exit 2 só erro de uso)
anexa, **somente quando invocado manualmente** com `-TaskFile <json>`, uma
linha em `cache/v3/telemetry/resolver-YYYYMMDD.jsonl` (ou `-TelemetryPath`
confinado a `cache/v3/telemetry` ou `TEMP`, com recusa de reparse point,
fail-closed). A linha (`capability-resolve.ps1` ~L331-341) é:

```json
{ "task_id": "<16hex>", "task_class": "<enum|unknown>", "profiles": [],
  "agents": [], "skills": [], "risk": "<LOW|MEDIUM|HIGH|CRITICAL>",
  "confidence": "<enum>", "mode": "shadow", "at": "<ISO-UTC>" }
```

- `task_id` é o **hash SHA256 (16 hex, minúsculo, sem prefixo)** do literal de
  `task_id` (`Get-ResolveTaskIdHash`); o literal **nunca** é persistido.
- `task_class` só passa se estiver na allowlist das `task_classes` do routing;
  caso contrário vira `unknown` + reason `AMBIGUOUS`.
- **Isto É a recomendação do adapter** (agentes/skills/profiles/risco/mcps
  recomendados), já sanitizada (hashes + enums; sem prompts/secrets).
- **Não há produtor autônomo**: nenhum caminho do Autonomous Loop/kernel
  invoca `capability-resolve.ps1`. A linha só existe se um operador rodou a
  CLI. Ausência de linhas ≠ ausência de tarefas.

### 2.2 Telemetria de kernel (`events-YYYYMMDD.jsonl`) — o que ela É e o que NÃO é

`Send-TaskKernelTelemetry` (`OrchestrationTaskKernel.ps1` ~L548-596) emite,
via `New-ObservabilityEvent`/`Write-ObservabilityEvent`
(`CapabilityObservability.ps1`, telemetria local “Phase 12”), eventos em
`cache/v3/telemetry/events-YYYYMMDD.jsonl`. Schema do evento
(`Get-ObservabilitySchemaFields`): `trace_id, parent_task_id, task_id,
timestamp, event_type, agent, model, selected_skills, selected_mcps,
routing_reason, risk, status, validation, review_outcome, retry_count,
escalation, duration_ms, metadata, warnings` (+ dims `runtime_id/
runtime_generation/runtime_version/runtime_profile`).

**Ponto crítico (verificado):** o produtor do kernel só preenche
`-TaskId`, `-EventType` e `-Metadata {task_id_hash, runtime_id,
runtime_generation, profile}`. Ou seja, os eventos kernel carregam o
**ciclo de vida** (`event_type` de enum fechado, ~31 valores,
`Get-ObservabilityValidEventTypes`) + `task_id` **hasheado** + dims de runtime
+ um `task_id_hash` (`Get-LogicalHash`, `CapabilitySchema.ps1` ~L322-340 =
`sha256:<hex completo>` do JSON determinístico do literal). Os campos
`agent`, `selected_skills`, `selected_mcps`, `routing_reason` **não** são
alimentados pelo kernel hoje.

Conclusões que o plano decorre:

- **Telemetria de kernel NÃO é evidência de uso do resolver.** Um evento
  `DISPATCHED`/`TASK_CREATED` prova atividade do kernel, não que
  `capability-resolve.ps1` foi consultado para aquela tarefa.
- **Agente/skill/MCP selecionados pelo Planner/runtime e desfechos produtivos
  NÃO estão expostos nem são correlacionáveis hoje** — ninguém emite, de forma
  sanitizada, “o que o runtime realmente escolheu/rodou”. O resolver registra
  a **própria** recomendação, não a decisão efetiva do Planner.

### 2.3 Divergência de formato de hash (e por que a correlação foi REMOVIDA)

- Resolver: `task_id` = **16 hex puro** (`abcdef0123456789`).
- Kernel: `task_id` = **`sha256:` + 16 hex** (`sha256:abcdef0123456789`);
  `metadata.task_id_hash` = `sha256:` + **hex completo** (outro valor).

A **única** junção *mecanicamente* possível seria: mesmo literal de `task_id`
alimentou ambos ⇒ o `task_id` do resolver (16 hex) iguala o `task_id` do kernel
sem o prefixo `sha256:`.

**Revisão (2026-10-09, após review independente): essa junção foi REMOVIDA.**
Igualdade de `task_id` **não prova** que o mesmo literal produziu as duas
linhas — o hash é de 16 hex, sem sal, sem projeto, sem sessão e sem run, e o
JSONL do resolver é produzido por CLI manual enquanto a observação é fornecida
por um produtor não autenticado. Emparelhar por coincidência de hash seria
**inferência**, não correlação. Política vigente: **nenhum par é criado**
até existir um **contrato comum de identificador escopado (projeto/sessão/run)
+ proveniência autenticada**, assinado pelos produtores dos dois lados. Até lá,
os streams são reportados em separado e as chaves ficam explicitamente **não
correlacionadas**.

### 2.4 Não existe consumidor (o coletor é net-new)

Busca (`git grep`) confirma: `resolver-*.jsonl` é **escrito** só por
`capability-resolve.ps1`; `events-*.jsonl` é **escrito** só pelas libs de
kernel/ownership/worktree. **Nenhum** componente lê/agrega esses streams.
O coletor 2G seria o **primeiro leitor**, read-only. Nenhum fixture versionado
existe (são arquivos de runtime em `cache/`, ignorados pelo git).

### 2.5 Flags — OFF e inalteradas

`source/registry/capability-flags.json`: `capability_router.shadow=false`,
`capability_router.active=false` **(Router v1 atualmente OFF)**,
`skill_routing/mcp_routing/adaptive_ranking/routing_telemetry/
capability_reconciler=false`, `runtime_grant_enforcement.v1/v2=false`. Ativos
(e fora do escopo 2G): `capability_registry.enabled=true`,
`task_kernel`, `bounded_execution`, `watchdog`, `jev_advisory`,
`worktree_isolation`, `runtime_support.*`. **Nada muda.**

### 2.6 Quatro esclarecimentos obrigatórios (fixed)

1. O JSONL do resolver é **manual, via CLI** — não é produzido pelo runtime
   autônomo (§2.1).
2. As flags do **Router v1 estão OFF** agora (§2.5).
3. **Telemetria de kernel não é prova de uso do resolver** (§2.2).
4. **Agente/skill/MCP escolhidos pelo Planner/runtime e desfechos produtivos
   não estão expostos/correlacionáveis** (§2.2) — logo não há “ground truth”
   de runtime para comparar com a recomendação do resolver.

---

## 3. Entrega factível e limitada (o que 2G PODE fazer)

**Entradas do coletor (read-only/offline, sem rede):**

- **A. Resolver JSONL** (`resolver-YYYYMMDD.jsonl`): recomendações sanitizadas
  do adapter, com proveniência “CLI manual”.
- **B. Registros de observação explicitamente fornecidos** (opt-in, autorados
  por operador/Planner): descrevem, por tarefa, o que **de fato** ocorreu
  (agente/skill/MCP efetivamente usados, desfecho). **Aceitos somente se
  confiáveis/provenientes**: entrada explícita, schema validado, marcados
  como `supplied`; **nunca** derivados de telemetria de kernel, nunca
  inventados. Registro sem proveniência/formato válido ⇒ **descartado ou
  quarentenado**, nunca contado como observação real.

**Correlação (política vigente — nenhuma):**

- **NÃO existe correlação** entre a recomendação do resolver e a observação
  fornecida. Não há escopo comum (projeto/sessão/run) no `task_id` opaco de
  16 hex e não há proveniência autenticada na observação fornecida.
- Consequência deliberada: **nenhum par é emitido**, `counts.correlated_pairs`
  é sempre `0`, e `uncorrelated.resolver_keys` /
  `uncorrelated.observation_keys` contam as chaves de cada lado. Chaves iguais
  nos dois streams **não** são emparelhadas.
- **Zero inferência**: sem casamento por similaridade, sem adivinhar
  proveniência, sem preencher lacunas, sem truncar hash para forçar match.
- **Requisito para futura correlação** (decisão do operador, fora do gate 2G):
  contrato comum de identificador escopado **+** proveniência autenticada,
  com os dois produtores assinando o mesmo escopo.

**Saída:**

- Um **relatório JSON** (por execução) em `evidence/capabilities-phase-2g/`
  com: contagens **totais** (linhas examinadas, registros válidos/rejeitados,
  bytes examinados, chaves não correlacionadas), recomendações do resolver
  (deduplicadas, por `task_class`/`risk`/`confidence`), claims fornecidos
  (`SUPPLIED_UNVERIFIED`, com cap de emissão e truncation honesto) e um
  **banner explícito `PARTIAL`** quando não há observações externas reais.
  **Não há bucketing por dia**: a data está no nome do arquivo (entrada do
  produtor, nunca ecoada) e o campo `at` é validado, não agregado.
- **Disclosure de limites é sempre verdadeiro e contável**: `total_bytes` é um
  orçamento **compartilhado** por todos os arquivos e pelos dois streams
  (`bytes_cap_reached` + arquivo `truncated`/`LIMIT_EXCEEDED` quando esgota; EOF
  **exatamente** no último byte do orçamento não é truncamento — a linha final
  completa é aceita); `files` também é **um** orçamento compartilhado pelos dois
  streams e limita a enumeração de candidatos **e** o array de detalhes do
  relatório (omissão vira contagem: `files_skipped_by_limit`,
  `files_omitted_by_records_cap`, `candidate_paths_seen`); `lines_read` conta
  toda linha realmente lida (vazias do fim, linha-sonda de cap e linha parcial
  do orçamento inclusas) e as linhas examinadas **sem** projeção ficam em
  `lines_omitted`; `records`/`output_items` têm omissão contada
  (`unique_keys` − `emitted` em `supplied_claims`).
- **Não** produz métrica de “aderência a runtime”, “estabilidade produtiva”
  ou “acordo” — porque falta ground truth (§2.6.4).

**Desfecho honesto:** sem observações externas genuínas, o coletor só demonstra
**contabilidade honesta** dos dois streams (inclusive o quanto fica **não
correlacionado**), **não** qualidade de routing contra a realidade. Qualquer
afirmação de qualidade exige observações reais fornecidas/provadas — **decisão
do operador**.

---

## 4. Gates e dependências (G0–G6)

Gates são a decupagem verificável do objetivo revisado (§1) e das restrições
(§3). Não são rótulos inventados: cada um ancora um fato verificável.
**Este plano é o contrato de execução deste request.** Situação no momento
desta revisão:

- **G0 — CONCLUÍDO**: baseline documentada em §2 (formatos dos dois streams,
  divergência de hash, produtores, ausência de consumidor, flags OFF),
  verificada por leitura de arquivo nesta sessão, em worktree isolado e
  limpo.
- **G1–G6 — CONCLUÍDOS COM RESSALVAS DOCUMENTADAS** neste request:
  - **G1 — verde**: alterações limitadas a plano, closure, coletor, testes,
    relatório de status vazio e exceção específica no `.gitignore`; nenhum
    core/adapter/registry/flag foi alterado. O checkout principal concorrente
    permaneceu intocado.
  - **G2 - verde**: suíte do coletor com fixtures em TEMP prova read-only
    (hash + `LastWriteTime` + listagem), offline e confinamento; nenhuma
    escrita em `cache/v3/telemetry`. Orçamento de bytes compartilhado
    provado com cap pequeno em multi-arquivo e multi-stream, **incluindo a
    fronteira exata** (linha final de exatamente `total_bytes`, com/sem
    terminador, aceita; `cap+1` disclosed). Cap de arquivos compartilhado
    entre os dois streams provado com `files=1` (um resolver + uma
    observação) e com caminhos rejeitados/inexistentes.
  - **G3 — verde**: nenhum par é criado; `correlated_pairs = 0` mesmo com a
    mesma chave nos dois streams.
  - **G4 — verde**: `provenance != supplied` ⇒ `UNSUPPORTED_PROVENANCE`;
    telemetria de kernel recusada por nome.
  - **G5 — verde com resultado UNAVAILABLE**: relatório determinístico
    `UNAVAILABLE / NO_VALID_RESOLVER_ROWS`, porque não havia resolver JSONL
    novo. Métricas requeridas são `NOT_OBSERVABLE`; avaliação geral
    `PARTIAL — INSUFFICIENT_REAL_WORLD_DATA`.
  - **G6 — parcial (ambiente)**: coletor 401/401 em PS 5.1 e PS 7; 2D 372/0,
    2E 408/408, 2F 991/0, distribuição 20 PASS/0 FAIL/1 SKIP e consistência
    16/0. Reviewer aprovou o finding final de seleção; Security Reviewer
    aprovou com resíduos TOCTOU/hardlink documentados. Runner V3 completo:
    81 PASS/4 FAIL/6 SKIP; três falhas dependem do hash externo `DE22307F` e
    uma do nome do worktree `-2g`. Os seis skips são ambientais. `git diff
    --check` limpo. PR #54 aberto; os cinco checks estavam pendentes na última
    consulta (run 38001327140).

| Gate | Requisito | Depende de | Evidência exigida |
|------|-----------|------------|-------------------|
| **G0** | Baseline documentado e confirmado: formatos dos dois streams, divergência de hash, produtores, ausência de consumidor, flags OFF | — | refs arquivo:linha de §2 (já verificado nesta sessão) |
| **G1** | Não-regressão de escopo: resolver `2d-shadow-1` intacto; JSONs 2D/2E intactos; nenhum flag alterado; Autonomous Core intacto; só arquivos net-new + 1 linha `.gitignore` | G0 | `git diff --name-only` (só arquivos previstos §8); registry `note`/`version` intactos |
| **G2** | Coletor **read-only/offline**: lê `resolver-*.jsonl` (e aceita B), nunca escreve nos streams de origem, **sem rede**, leitura confinada, secreto-seguro (re-valida sanização); `total_bytes` é **um** orçamento compartilhado por arquivos e streams, com omissão disclosed | G0,G1 | suíte do coletor com fixtures determinísticas provando read-only + offline; nenhuma escrita em `cache/v3/telemetry` de origem; asserts de orçamento compartilhado (multi-arquivo e multi-stream com cap pequeno) |
| **G3** | **Sem correlação** entre os streams (nenhum par, nem por chave opaca igual); chaves não correlacionadas contadas explicitamente; **zero inferência** | G2 | asserts: `counts.correlated_pairs == 0` com a mesma chave nos dois streams; `uncorrelated.*` preenchido; `source_classification.correlation = NOT_CORRELATED_NO_COMMON_SCOPED_ID`; nenhum marcador de match exato no JSON |
| **G4** | Registros de observação (B) aceitos **só** se confiáveis/provenientes (entrada explícita + schema + marca `supplied`); **nunca** derivados de kernel; inválido ⇒ descartado/quarentenado | G3 | asserts: rejeição de registro sem proveniência/formato; kernel telemetry **não** vira observação |
| **G5** | Saída **honesta/PARCIAL**: contagens + chaves não correlacionadas + banner `PARTIAL` sem observações externas; **sem** claim de acordo/estabilidade/desfecho produtivo | G4 | JSON de relatório inspecionado; ausência de campos de “agreement/runtime outcome” |
| **G6** | Regressão + consistência verdes + review + whitespace | G2-G5 | 2E/2D/2F + `test-package-consistency` verdes (check 9 ainda exige flags routing OFF); nova suíte do coletor verde (PS5.1+PS7), incluindo determinismo entre processos; `git diff --check` limpo; reviewer (+ security se disparar) `APPROVED` |

**Dependências externas fora do gate 2G:** disponibilidade de **observações
reais fornecidas/provadas** (operador) para sair do `PARTIAL`; provider de
modelo/turnos reais (não há runtime real neste ambiente isolado).

---

## 5. Aceitação e verificação (contrato deste request)

Comandos de verificação (a rodar **neste request**; repositório usa
PowerShell 5.1 e 7):

```powershell
powershell -NoProfile -File scripts\v3\lib\CapabilityAdvisoryCollector.tests.ps1   # novo; PS5.1 + PS7, offline determinístico
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1                            # inclui 2F/2D + coletor
powershell -NoProfile -File tests\distribution\run-distribution-tests.ps1           # inclui capability-routing-phase2d, 2E real-world
powershell -NoProfile -File scripts\test-package-consistency.ps1                    # 16 checks; check 9 = flags routing OFF
git diff --check
```

- **Resultados realmente observados neste request:** 2F `991/0`,
  2E `408/408`, 2D `372/0`, `test-package-consistency` `16/0`, distribuição
  `20 PASS/0 FAIL/1 SKIP` e coletor `401/401` nos dois PowerShells. Runner V3
  completo: `81 PASS/4 FAIL/6 SKIP`, exit 1; falhas e skips ambientais não
  foram ocultados.
- Nova suíte do coletor deve provar: read-only, offline, **ausência de
  correlação** (nem por chave opaca igual), quarentena de registros
  não-provenientes, e relatório `PARTIAL` sem observações externas.
- **Resultado realmente observado nesta rodada (2026-10-09, revisão 4):**
   - `CapabilityAdvisoryCollector.tests.ps1`: **401 asserts, 0 falhas,
    0 skips** em PS 5.1 (29,7 s / 33,7 s em execuções consecutivas; 48 s sob
    carga de CPU) **e** em PS 7 (22 s sob carga);
  - determinismo entre processos verdes nos dois sentidos
    (PS 5.1 com processo filho PS 7 e PS 7 com processo filho PS 5.1);
  - `run-v3-tests.ps1 -Name CapabilityAdvisoryCollector`: `PASS`
    (1/1, 30,2 s);
  - `test-package-consistency.ps1`: **16 OK / 0 FAIL**;
  - `run-distribution-tests.ps1` (regressão 2D/2E/2F): **20/20 PASS,
    1 SKIP, 0 FAIL** (163,5 s);
  - `git diff --check`: limpo; arquivos novos ASCII-only (lib/suíte), sem
    trailing whitespace e sem CRLF.
   - Reviewer APPROVED no finding final; Security Reviewer APPROVED com
     resíduos documentados. PR/CI/merge não executados.

- Nenhuma evidência observável ⇒ classificar `REVIEW_FALLBACK`, nunca
  `REVIEW_APPROVED`/`PASS` inventado (política §5 de
  `github-lifecycle-policy.md`).

### 5.1 Schema do relatório implementado (`schema_version` 3)

`Get-AdvisoryCollectorReport` devolve um objeto ordenado serializado por
`ConvertTo-AdvisoryCollectorJson`. Chaves de topo (fechadas):

`schema`, `schema_version`, `producer`, `authority`,
`collection_status`, `collection_failure_reasons`, `evaluation_status`,
`evaluation_status_reason`, `inputs`, `counts`, `recommendations`,
`supplied_claims`, `uncorrelated`, `ambiguous`, `source_classification`,
`missing`, `metrics`, `rejection_reasons`, `integrity`.

- `inputs`: `allowed_roots`, `capability_allowlist_loaded`, `files[]`
  (`kind`, `status`, `reason`, `lines_read`, `lines_omitted`,
  `records_valid`, `records_rejected`, `bytes` = bytes **realmente
  examinados**), `dropped_input_keys_count`, `sensitive_keys_dropped`,
  `limits` (`files`, `total_bytes`, `line_bytes`, `file_lines`,
  `records`, `array_items`, `output_items`), `records_cap_reached`,
  `lines_cap_reached`, `bytes_cap_reached`, `files_skipped_by_limit`,
  `files_omitted_by_records_cap`, `candidate_paths_seen`,
  `bytes_examined_total`.
- `counts`: linhas lidas, **linhas omitidas** (`resolver_lines_omitted` /
  `observation_lines_omitted`), registros válidos/rejeitados,
  recomendações únicas, observações aceitas/rejeitadas, duplicadas,
  ambíguas, **`correlated_pairs` (sempre 0)**,
  `uncorrelated_resolver_keys`, `uncorrelated_observation_keys`,
  `supplied_claim_keys`, `supplied_claims_emitted`.
- `recommendations`: `unique_total`, `by_task_class`, `by_risk`,
  `by_confidence` (ordem ordinal).
- `supplied_claims`: `trust` (`SUPPLIED_UNVERIFIED`), `correlation`
  (`NOT_CORRELATED_NO_COMMON_SCOPED_ID`), `accepted_total`, `unique_keys`,
  `duplicate_keys`, `ambiguous_keys`, `emitted`, `truncated`, `fields`
  (`claimed_*` = `CLAIMED_NOT_OBSERVED`; `observed_*` = `NOT_OBSERVABLE`) e
  `items[]` (`task_key`, `trust`, `claimed_task_class`, `claimed_agent`,
  `claimed_skills`, `claimed_mcps`).
- `uncorrelated`: `resolver_keys`, `observation_keys`, `reason`.
- `ambiguous`: `observation_keys` (claims fornecidos conflitantes).
- `missing`: `external_observations`, `runtime_ground_truth`,
  `proven_observations`, `correlation_contract`.
- `metrics`: 7 entradas, **todas** `NOT_OBSERVABLE` com razão em enum.
- `integrity`: `read_only`, `network_access`, `input_files_mutated`,
  `telemetry_written`, `kernel_telemetry_read`, `workers_or_mcp_invoked`,
  `resolver_invoked`, `rows_correlated` (`false`).

**Mudança de schema nesta revisão (revisão 2): `schema_version` 2 → 3.**
Do 1 → 2 (revisão anterior) já valiam: remoção de `pairs`,
`pairs_truncated` e `unmatched` (substituído por `uncorrelated`) e dos
contadores `pairs_matched_total`/`pairs_emitted`/
`unmatched_resolver_keys`/`unmatched_observation_keys`; acréscimo de
`supplied_claims`, `uncorrelated`, `counts.correlated_pairs`,
`counts.uncorrelated_*`, `counts.supplied_claim_keys`,
`counts.supplied_claims_emitted`, `inputs.bytes_examined_total`,
`missing.correlation_contract`, `integrity.rows_correlated` e
`source_classification.correlation`; o limite `output_pairs` virou
`output_items`. Do 2 → **3** (esta rodada):

- **Orçamento de bytes compartilhado**: `total_bytes` passa a valer para
  TODOS os arquivos e para OS DOIS streams em conjunto (antes cada arquivo
  recebia o cap cheio). Acrescentados `inputs.bytes_cap_reached` e
  `inputs.candidate_paths_seen`.
- **Enumeração e detalhes de arquivo limitados pelo cap `files`**: a entrada
  não é materializada por inteiro (no máximo `files` caminhos distintos, os
  menores na ordem ordinal) e o array `inputs.files` tem no máximo `files`
  entradas — **não existe mais entrada `status: "skipped"`**. Omissão virou
  contagem: `inputs.files_skipped_by_limit` (cap de arquivos) e
  `inputs.files_omitted_by_records_cap` (cap de registros, candidato não
  aberto).
- **Linhas honestas**: `lines_read` conta toda linha REALMENTE lida —
  válidas, vazias (inclusive as do fim do arquivo), malformadas, a
  linha-sonda que revela um cap e a linha parcial cortada pelo orçamento.
  Acrescentados `lines_omitted` por arquivo e
  `counts.{resolver,observation}_lines_omitted` (linhas examinadas e **não**
  projetadas). Invariante: `lines_read = records_valid + records_rejected +
  lines_omitted`.
- **Determinismo entre processos**: todos os mapas serializados (inclusive
  `metrics`, `files[]` e `supplied_claims.items[]`) são dicionários
  **ordenados**, e a suíte compara a serialização com a de um processo
  filho separado (PS 5.1 ↔ PS 7), byte a byte.

**Revisão 3: `schema_version` permanece 3** (nenhuma chave acrescentada ou
removida; só semântica mais honesta de contadores já existentes):

- `files_skipped_by_limit` / `candidate_paths_seen` passam a ser **globais**
  (os dois streams concorrem ao mesmo orçamento de `files`); `inputs.files`
  nunca tem mais entradas que `inputs.limits.files`.
- `bytes_cap_reached` só fica `true` quando existem bytes **além** do
  orçamento: EOF exatamente no último byte do orçamento não é truncamento e
  a linha final completa é aceita.

**Limites honestos deste disclosure (não mascarados):**

- `files_skipped_by_limit` conta **entradas de caminho candidato** não
  lidas; a seleção mantém no máximo `files` candidatos distintos em memória
  adicional e percorre diretamente os arrays fornecidos (sem criar um array
  de objetos por caminho). Repetições contam como ocorrências omitidas,
  inclusive quando o par repetido foi retido; não consomem slot, mas ficam
  contabilizadas. Assim, a contagem é determinística e independe da ordem de
  entrada, sem armazenar todos os caminhos para deduplicação global.
- Quando `lines_cap_reached` ou `bytes_cap_reached` interrompem a varredura,
  a contagem de linhas **além** do cap não é conhecida sem nova leitura: a
  omissão fica sinalizada pelos flags, não por um número inventado.
- Quando o cap de `records` é atingido, os registros que **seriam** válidos
  após o cap são incontáveis (não há projeção): a omissão de registros/claims
  fica em `records_cap_reached` + `lines_omitted` + `truncated`
  (`supplied_claims`).

---

## 6. Não-objetivos (non-goals)

- **Fora do fluxo deste request:** `git push`, abertura de PR, `merge`,
  ação em `master` e afirmação de checks de CI — só com autorização
  explícita do operador; localmente esses resultados não são afirmáveis.
- **Não** editar: `NativeDispatch`, `AutonomousLoop`, `TaskKernel`,
  `GoalKernel`, `watchdog`, nem o produtor de telemetria
  (`CapabilityObservability.ps1` — tratado como baseline read-only); nenhum
  flag; nenhum `capability-*.json`, `mcp-profiles.json`, `skills-catalog.json`;
  `source/adapters`; destino ativo `~/.config/opencode`; JSONs 2D/2E; projetos
  externos.
- **Não** ativar/promover routing (Active), `skill_routing`, `mcp_routing`,
  `adaptive_ranking`, `routing_telemetry`; **não** criar capability nova.
- **Não** derivar desfecho/agente/skill/MCP reais de telemetria de kernel;
  **não** inferir correlação; **não** acessar rede.
- **Não** reabrir escopo 2E/2F (ver §9); **não** alegar volume de tarefas
  reais, prova de runtime, merge/PR/CI.

---

## 7. Riscos, segurança e rollback

**Riscos residuais (honestos):**

- **Falsa correlação entre streams**: eliminada por construção — **nenhum
  par é criado**; chaves iguais não são emparelhadas (G3). O residual é o
  oposto: o coletor **sub-conta** (não correlaciona o que talvez fosse
  correlacionável), nunca super-conta.
- **Registros fornecidos não-confiáveis**: mitigados por validação de
  proveniência/schema + quarentena (G4); nunca viram “observação real” e
  todo campo de observação fica `NOT_OBSERVABLE`.
- **Deriva de “ground truth”**: o coletor **não** pode medir acordo com
  runtime; resultado é `PARCIAL` sem observações externas (G5, §2.6.4).
- **Amostra/deriva de ambiente**: invariante `opencode.json` vivo
  (`DE22307F`) pode falhar 4 suítes V3 — **invariante de ambiente, não
  regressão 2G** (`docs/TROUBLESHOOTING.md`); registrar, não mascarar.
- **Formato de hash frágil** (§2.3): a divergência resolvedor↔kernel deixa de
  gerar par por policy (G3); a direção continua conservadora.
- **Crescimento do arquivo durante a leitura**: o leitor é limitado pelos
  bytes realmente examinados e abre com `FileShare.Read` (escritor
  concorrente impede a abertura onde a plataforma suporta); linha acima de
  `line_bytes` é descartada sem materialização e UTF-8 inválido falha
  fechado. O orçamento `total_bytes` é **compartilhado** por todos os
  arquivos e streams e nunca é estourado: o total examinado
  (`bytes_examined_total`) é no máximo o orçamento, e esgotamento é
  disclosure (`bytes_cap_reached` + arquivo `truncated`/`LIMIT_EXCEEDED`).
  Fronteira exata (revisão 3): EOF no último byte do orçamento **não** é
  truncamento — a linha final completa é aceita; a distinção usa
  `Position`/`Length`, sem consumir byte além do orçamento, e stream sem
  essa informação cai no lado conservador (truncar e disclosed).
- **Cap de arquivos por stream (corrigido na revisão 3)**: a enumeração de
  candidatos e o array `inputs.files` ficam sob **um** orçamento
  compartilhado pelos dois streams, então o relatório não pode exibir mais
  detalhes que `inputs.limits.files`; a omissão é sempre contagem, inclusive
  de candidato que seria rejeitado ou recusado.
- **Flutuação de medição em host carregado (corrigido na revisão 3)**: os
  testes de custo medem **escala** contra baseline menor (taxa por
  chave/linha, limite 3×) além do tempo absoluto com margem generosa, para
  que carga de máquina não falhe um teste sem regressão de custo — e para
  que comportamento quadrático continue sendo detectado.
- **Custo de agregação**: helpers de ordenação/contagem usam `ArrayList` +
  `HashSet` (sem `+=` em array), testados com 1.500 chaves distintas.
- **Determinismo de serialização**: todos os mapas do relatório são
  dicionários ordenados; a suíte compara a saída com a de um processo filho
  separado (PS 5.1 ↔ PS 7). Sem isso, a enumeração de hashtable depende de
  seed por processo e o mesmo relatório sairia com ordem de chaves
  diferente — foi exatamente o bug encontrado nas entradas de `metrics`.
- **Custo do detector de duplicata**: substituído por scanner lexical de
  passada única (O(n) no tamanho da linha), sem backtracking dependente de
  engine; fixture adversária com milhares de aspas escapadas trava o tempo.

**Segurança:** leitura confinada e offline; JSONL de origem já é sanitizado, e
o coletor **re-valida** (nunca propaga texto livre/segredo); sem escrita nos
streams de origem; sem credenciais.

**Rollback:** a entrega é composta por arquivos 2G novos e uma exceção
específica no `.gitignore`; não altera schema/flag/contrato de terceiros.
Reversão = remover os arquivos net-new, o relatório de status e a linha
`!evidence/capabilities-phase-2g/`. Nada global ou no runtime ativo é mutado.

---

## 8. Arquivos previstos (menor mudança defensável)

**Já entregue neste request:**

- `docs/plans/CAPABILITY-ADVISORY-OBSERVABILITY-PHASE-2G-PLAN.md` **(novo)** —
  este plano (escrita concluída; agora é o contrato de execução).
- `scripts/v3/lib/CapabilityAdvisoryCollector.ps1` **(novo)** — coletor
  read-only/offline (§3). Estado: implementado, com leitor limitado por
  bytes e orçamento de bytes **compartilhado** (todos os arquivos + os dois
  streams, com fronteira exata: EOF no último byte do orçamento aceita a
  linha final completa), enumeração de candidatos e array de detalhes sob
  **um** orçamento de arquivos compartilhado pelos dois streams, rejeição de
  raiz não-objeto, detecção de duplicata por scanner lexical de passada
  única (sem regex), `lines_read` contando toda linha realmente lida e
  **sem** correlação entre streams.
- `scripts/v3/lib/CapabilityAdvisoryCollector.tests.ps1` **(novo)** — suíte
  determinística (read-only, offline, ausência de correlação, quarentena,
  `PARTIAL`). Estado: **401 asserts / 0 falhas / 0 skips em PS 5.1 e PS 7**
  (inclusive sob carga de CPU), incluindo orçamento compartilhado
  multi-arquivo/multi-stream, fronteira exata do orçamento de bytes (linha
  de exatamente `total_bytes`, com/sem terminador, aceita; `cap+1`
  disclosed), cap de arquivos compartilhado entre os dois streams
  (`files=1` com um resolver + uma observação, candidato inexistente como
  selecionado e o mesmo caminho pedido nos dois streams), enumeração
  limitada com contagem de omitidos, fixture adversária de aspas escapadas,
  performance medida por escala contra baseline menor e determinismo
  comparado com processo filho separado (PS 5.1 ↔ PS 7).

**Também entregues neste request:**

- `evidence/capabilities-phase-2g/advisory-collector-report-2026-10-09.json`
  **(novo)** — relatório de status gerado pelo coletor sem inputs; registra
  `UNAVAILABLE / NO_VALID_RESOLVER_ROWS`, zero tarefas e zero correlações. Não
  é amostra real nem resultado de routing.
- `.gitignore` (**+1 linha**) — `!evidence/capabilities-phase-2g/` (espelha
  2b–2f).
- `docs/audits/opencode-capability-phase-2g-closure-2026-10-09.md` **(novo)** —
  closure deste request com resultado `PARTIAL` e gaps explicitados.

**Explícita e intencionalmente NÃO tocados:** resolver
(`CapabilityResolver.ps1`, `resolver_version` `2d-shadow-1`),
`source/registry/capability-routing.json`, flags e demais
`capability-*.json`/`mcp-profiles.json`/`skills-catalog.json`, Autonomous Core
(`NativeDispatch`/`AutonomousLoop`/`TaskKernel`/`GoalKernel`/`watchdog`) e o
produtor `CapabilityObservability.ps1`, JSONs 2D/2E, `source/adapters`,
destino ativo `~/.config/opencode`, do `master` (sem commit direto/force-push).

---

## 9. Histórico 2E/2F — regressão apenas

2E e 2F permanecem **baseline de regressão**, não são reabertos:

- **2F** (`docs/audits/opencode-capability-routing-phase-2f-closure-2026-10-08.md`):
  PASS SHADOW+ADVISORY, resolver `2d-shadow-1` refinado, corpus 43/43,
  `CONTINUE_ADVISORY`, flags OFF.
- **2E**: replay 13/13; suites `408/408`.
- **2D**: contrato de regressão preservado; `372/0`.

2G **não** altera nenhum JSON/saída dessas fases; só acrescenta um leitor
observacional. A suíte 2G deve manter esses números verdes (G6).

---

## 10. Veredito e recomendação

- **Escopo 2G revisado** ao que é verificável offline **sem fabricar ground
  truth** (§1, §3).
- **Entrega máxima honesta**: coletor read-only/offline, **sem correlação
  entre streams** (`correlated_pairs = 0`), claims fornecidos
  `SUPPLIED_UNVERIFIED` com campos de observação `NOT_OBSERVABLE`, chaves não
  correlacionadas contadas explicitamente e relatório **`PARTIAL`**; qualidade
  de routing contra o real **só** com observações externas
  fornecidas/provadas **e** um contrato de escopo comum — **decisão do
  operador**.
- **Recomendação**: `COLLECT_MORE_REAL_DATA`; **Active segue HOLD**; **flags
  UNCHANGED (OFF)**; **Planner/Kernel authority UNCHANGED**.
- **Workflow**: implementação, testes e closure locais concluídos; commits
  locais publicados na branch isolada e PR #54 aberto para `master`. Na última
  consulta, os cinco checks reais do GitHub estavam `pending` (run 38001327140);
  nenhum CI verde ou merge é afirmado. O merge permanece pendente.
- **Dívida explícita (não mascarada)**: zero observações reais novas; não há
  contrato de correlação com runtime. O relatório em `evidence/` registra a
  ausência de input (`UNAVAILABLE`), não dados sintéticos. Revisões independentes
  aprovam o finding final e a segurança, com limitações TOCTOU/hardlink
  explicitadas na closure; runner V3 completo mantém failures ambientais
  documentados (§4 e closure).

---

## Referências

- `docs/audits/opencode-capability-routing-phase-2f-closure-2026-10-08.md`
- `docs/plans/CAPABILITY-ROUTING-PHASE-2F-PLAN.md`
- `docs/capability-routing-phase-2d.md`, `docs/github-lifecycle-policy.md`,
  `docs/GOVERNANCE.md`, `docs/ARCHITECTURE.md`, `docs/TROUBLESHOOTING.md`
- `scripts/v3/capability-resolve.ps1`,
  `scripts/v3/lib/CapabilityResolver.ps1`,
  `scripts/v3/lib/CapabilityObservability.ps1`,
  `scripts/v3/lib/OrchestrationTaskKernel.ps1`,
  `scripts/v3/lib/CapabilitySchema.ps1`
- `source/registry/capability-flags.json`,
  `source/registry/capability-routing.json`
