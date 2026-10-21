# Todowrite — Projeção Unidirecional Opt-in — SPEC (Issue #142)

**Projeto:** opencode-orchestration
**Versão:** 0.1 (PROPOSED)
**Tipo:** projeção de UI somente-leitura (read-only projection)
**Status:** PROPOSED — sem implementação; nenhuma flag ativada por esta SPEC
**Escopo de escrita autorizado:** apenas este arquivo

## 1. Problema

Hoje há **zero** presença de `todowrite` no checkout (0 hits em código,
contratos, flags, grants e skills). Não existe contrato, flag, grant ou skill
que referencie todowrite. O acompanhamento de progresso acontece via
Goal/Task Kernel e evidências, sem projeção padronizada para a UI nativa de
todos do runtime.

A issue #142 pede uma projeção para a UI de todos **sem criar uma segunda
autoridade de conclusão**: o DONE canônico continua sendo exclusivamente o
`Complete-OrchestrationTask` do Task Kernel, após verificação determinística
allowlisted. Qualquer leitura da UI como prova de conclusão seria falsa
conclusão — inclusive após compactação de contexto, quando o modelo pode
re-encontrar apenas os todos e inferir estado que o Kernel não atesta.

Restrições de contexto (INV-142, a confrontar com `source/` na implementação):

- Runtime V2 só reconhece `agents` + `permissions` + `subagent_depth = 1`;
  não há superfície de enforcement nova a presumir.
- Padrão PlannerLoop vigente é advisory-only: 1 chamada, envelope tipado,
  fail-open. A projeção segue o mesmo padrão: consulta, não comando.
- As 8 features V2 permanecem `hold-unproven`; nenhuma é todowrite. Esta SPEC
  não promove nenhuma delas.
- Grants não contêm `todo.*`. Esta SPEC não cria grant novo.
- #49 é Control Center/shares, não todowrite. Sem acoplamento.
- Hierarquia vigente é Goal pai de Tasks; não há tabela única. A projeção
  deriva todos de Goal/Phase/Task, sem tabela paralela.

## 2. Objetivo e critério de sucesso

Oferecer **progresso visível na UI sem autoridade**: o Planner (e só ele, via
loop advisory) projeta snapshots do estado canônico Goal/Task para todos
efêmeros, descartáveis e regeneráveis, que a UI pode exibir e o operador pode
ler — sem que nenhum consumidor os trate como DONE, verificação ou autorização.

Sucesso = operador vê progresso coerente com o Kernel; queda ou ausência do
mecanismo experimental **não impede o Planner**; nenhum teste ou revisão
confunde todos com conclusão.

## 3. Escopo e não objetivos

### Incluído

- Projeção unidirecional Kernel → todos (somente leitura do store canônico).
- Opt-in isolado por objetivo/sessão, desligado por padrão.
- Limites de itens, mapeamento explícito de bloqueios, Golden test e caminho
  de fallback/rollback.
- Matriz Objective/Goal/Phase/Task → todos (seção 5).

### Fora do escopo (não autorizar)

- **Sem DONE via todos.** Nenhum todo `completed` conclui Task/Goal, verifica
  critério ou substitui `Complete-OrchestrationTask` / verificador allowlisted.
- **Sem loop bidirecional.** A UI/runtimes nunca escreve de volta no Kernel
  via todos; sem sync reverso, sem reconciliação todo→Kernel.
- **Sem duplicar Kernel.** Sem store paralelo, sem tabela única de todos como
  fonte, sem ownership/generation/revision próprios. Todos são derivados e
  descartáveis.
- **Sem nova autoridade.** Sem flag ativa, sem grant `todo.*`, sem skill nova,
  sem mudança de `agents`/`permissions`/`subagent_depth`, sem promover feature
  `hold-unproven`.
- **Sem acoplamento com #49.** Control Center/shares seguem independentes.

## 4. Invariantes

1. **Kernel é a única autoridade durável.** Goal, Task, tentativa, recibo,
   evidência e conclusão vêm do store/kernel. Todo é claim descartável.
2. **Projeção é unidirecional e efêmera.** Kernel → todos; nunca o inverso.
   Todo pode ser apagado/regenerado sem perda de estado.
3. **Todo nunca autoriza efeito.** Leitura de todo não é grant, não precede
   efeito, não substitui interseção User ∩ Project ∩ Runtime ∩ Grants.
4. **Falha é fail-open para o Planner.** Erro, ausência ou indisponibilidade
   do mecanismo resulta em `PROJECTION_UNAVAILABLE`; o Planner segue pelo
   Kernel. Queda experimental nunca bloqueia dispatch, settlement,
   verificação ou avanço.
5. **Sem falsa conclusão pós-compactação.** Todo persistido pelo runtime além
   da sessão NÃO é evidência. Após compactação/retomada, só o Kernel/store
   revalidado conta; todos órfãos são marcados `stale` e regenerados ou
   descartados, nunca consumidos como prova.
6. **Uma chamada advisory por ciclo.** O Planner consulta o projetor no
   máximo 1 vez por ciclo de loop, com envelope tipado (seção 6); sem polling,
   sem fan-out, sem worker dedicado.
7. **Opt-in isolado.** Desligado por padrão; ativação explícita por
   objetivo/sessão; sem efeito global, sem mudança de default de flag.

## 5. Matriz de projeção Objective/Goal/Phase/Task → todos

DONE está **fora** da matriz: nenhuma linha abaixo conclui, verifica ou
avança nada. A coluna "todo" é apenas rótulo de exibição.

| Nível canônico | Fonte (somente leitura) | Projeção (todo efêmero) | Status exibido | Notas |
|---|---|---|---|---|
| Objective | Objective + Goals filhos | 1 todo-pai `objective:<id>` | `in_progress` enquanto houver Goal não-terminal; nunca `completed` por si | Agrupador visual; sem semântica de conclusão |
| Goal | Goal store (vivo, ownership/generation) | 1 todo `goal:<id>` sob o pai | `pending` / `in_progress` / `blocked:<motivo>` | Terminal do Goal não fecha o todo; o fechamento visual só reflete leitura posterior, sem autoridade |
| Phase | fases da Task multifase (quando houver) | 0..N todos `phase:<goal>/<phase>` | `pending` / `in_progress` | Opcional; omitir quando a Task não tiver fases discretas |
| Task | Task Kernel (tentativa, recibo, verificação) | 0..N todos `task:<id>` sob Goal/Phase | `pending` / `in_progress` / `blocked:<motivo>` | `candidate_pass` projeta no máximo `in_progress (awaiting verification)`; **nunca** `completed` |

Regras da matriz:

- **Limites:** no máximo 1 todo-pai por Objective, 1 por Goal, 1 por
  Phase discreta, 1 por Task ativa; teto total **20 todos por Objective**
  (excesso = truncar por prioridade Goal ativo > Task ativa > resto, e
  sinalizar `truncated:true`). Sem paginação — truncar e sinalizar.
- **Ordenação:** Goal ativo primeiro, depois Tasks ativas por criação;
  terminais por último (ou omitidos quando truncar).
- **Bloqueios (mapping explícito):** `BLOCKED` do Kernel projeta
  `blocked:<MOTIVO_CURTO>` com enum fechado: `awaiting-verification`,
  `awaiting-reviewer`, `budget-exhausted`, `grant-denied`,
  `dependency-blocked`, `reconciliation-required`, `operator-decision`.
  Motivo fora do enum = `blocked:other`. O texto do motivo é exibição;
  a autoridade do bloqueio permanece no Kernel.
- **Stale:** todo cuja fonte (Goal/Task/revision) não é mais viva ou cuja
  sessão de origem terminou sem revalidação = `stale`, a regenerar ou
  descartar. Nunca consumir `stale` como estado.

## 6. Contrato funcional desejado

### PROJECT (advisory, 1 chamada/ciclo)

O Planner, **se opt-in ativo**, chama o projetor uma vez por ciclo com
envelope tipado mínimo:

```json
{ "objective_id": "<id>", "goal_ids": ["<g1>"], "task_ids": [], "limit": 20 }
```

Sem histórico/dumps, sem segredos, sem conteúdo de skill. O projetor lê o
store canônico e devolve somente rótulos + status de exibição + `stale` /
`truncated` flags. Retorno é **dado**, não instrução: não altera rota,
grants, permissões ou plano.

### Falhas

Qualquer erro (store indisponível, schema inesperado, timeout curto e
bounded, exceção) devolve `PROJECTION_UNAVAILABLE` e o Planner segue sem
todos. Sem retry em loop, sem worker de reparo, sem bloqueio. Falha é
observável em log sanitizado (ids + enum, sem texto livre/segredo).

### Sem escrita reversa

Não existe operação todo→Kernel. Nenhum endpoint, hook ou worker consome
todo como input de settlement, verificação, avanço ou recovery. Teste que
demonstrar escrita reversa = FAIL da feature.

## 7. Golden test + fallback/rollback

**Golden (hermético, sem runtime real):** fixture com 1 Objective, 1 Goal,
2 Tasks (uma `candidate_pass` aguardando verificação, uma `BLOCKED` por
`grant-denied`) projeta exatamente: pai `in_progress`, Goal `in_progress`,
Task-1 `in_progress (awaiting verification)` — nunca `completed` —,
Task-2 `blocked:grant-denied`. Asserts negativos obrigatórios: nenhum todo
com status de conclusão; nenhuma mutação do store fixture; nenhuma chamada
fora da única chamada advisory.

**Fallback (runtime):** com projetor ausente/falhando, o Planner completa o
ciclo Objective→Goal→Task→settlement→verificação sem todos e o teste registra
`PROJECTION_UNAVAILABLE` sem FAIL funcional.

**Rollback:** desligar o opt-in (único interruptor) remove todos os efeitos
visíveis: nenhum todo novo é projetado; todos existentes são descartáveis e
podem ser limpos sem migração, sem resíduo de autoridade, sem mudança de
store. Rollback não toca flags, grants, agents ou pins.

## 8. Requisitos e aceite

| ID | Critério |
|---|---|
| AC-01 | UI exibe progresso (pai/filhos, bloqueios com motivo do enum) sem nenhum elemento tratado como DONE. |
| AC-02 | Nenhum caminho todo→Kernel existe (teste negativo de escrita reversa PASS). |
| AC-03 | Queda/ausência do projetor devolve `PROJECTION_UNAVAILABLE` e o Planner conclui o ciclo pelo Kernel (fallback PASS). |
| AC-04 | Sem loop bidirecional: nenhuma reconciliação consome todo como prova, antes ou depois de compactação (stale descartado/regenerado). |
| AC-05 | Pós-compactação: sessão retomada revalida só pelo Kernel; todos órfãos marcados `stale`, nunca consumidos (teste de falsa conclusão PASS). |
| AC-06 | Limites respeitados: teto 20/Objective, truncagem sinalizada, 1 chamada advisory/ciclo, sem polling/fan-out. |
| AC-07 | Opt-in isolado: default desligado; ativação por objetivo/sessão; rollback limpo sem resíduo (Golden + rollback PASS). |
| AC-08 | `git diff --check` limpo; nenhum arquivo fora desta SPEC tocado; nenhuma flag/grant/pin alterado; nenhum commit por esta SPEC. |

## 9. Segurança e modos de falha

Cobrir: store indisponível, revision stale, Goal/Task terminal, todo órfão
pós-compactação consumido como prova (deve FAIL se consumido), motivo de
bloqueio fora do enum (→ `other`), excesso de itens (truncar + sinalizar),
dupla chamada por ciclo (2ª ignorada), opt-in ligado globalmente por engano
(configuração deve recusar escopo global — só objetivo/sessão), tentativa de
usar todo como autorização de efeito (recusar; Kernel/grants decidem).
Nenhum teste transforma `runtime_grant_enforcement` OFF em autorização; nenhum
log de projeção carrega segredo ou texto livre do modelo.

## 10. Baseline de runtime e limitações observadas

- Pins vigentes em `source/registry/runtime-versions.json`; loader fail-closed.
- Superfície V2 assumida: `agents` + `permissions` + `subagent_depth = 1`.
- PlannerLoop advisory-only (1 chamada, envelope tipado, fail-open) é o único
  padrão de invocação permitido ao projetor.
- 8 features V2 `hold-unproven`, nenhuma todowrite — esta SPEC não alega prova
  nem promove nenhuma.

## 11. Classe e decisão de escopo

Classe: `FEATURE_REEVALUATION` (projeção nova, sem autoridade). Mudança de
autoridade, flag, grant, runtime, permissão ou pin exige gate humano e prova
específica; **esta SPEC não autoriza nenhuma dessas alterações**. Não criar
ADR até haver decisão durável nova não coberta pelo ADR vigente. Ativação do
opt-in em qualquer ambiente real é decisão de operador com evidência, nunca
inferência desta SPEC.
