# Phase 2G Closure — Advisory Observability & Real-World Evaluation

**Data:** 2026-10-09  
**Branch:** `feat/capability-advisory-observability-phase-2g`  
**Base:** `b38c92bc8b3ab334a9dffad609f3515350336061`  
**Worktree:** `D:/projetos/opencode-orchestration-2g`

## Phase 2G Verdict

```text
PARTIAL — INSUFFICIENT_REAL_WORLD_DATA
```

A infraestrutura passiva de leitura offline foi implementada e validada. Não
foram encontradas linhas locais `resolver-*.jsonl` para uma observação nova e
nenhuma execução produtiva expõe decisão do Planner/runtime ou outcome com
proveniência escopada. Por isso não se afirma avaliação real de routing,
concordância, sucesso ou estabilidade. O relatório em
`evidence/capabilities-phase-2g/advisory-collector-report-2026-10-09.json`
registra honestamente `UNAVAILABLE / NO_VALID_RESOLVER_ROWS` (zero entradas),
não uma amostra inventada.

## Git

```text
initial master: b38c92bc8b3ab334a9dffad609f3515350336061 (origin/master no fetch inicial)
branch: feat/capability-advisory-observability-phase-2g
feature HEAD: follow-up dos findings Codex validado localmente; commit/push pendentes
PR: #54 — https://github.com/Kusts/opencode-orchestration/pull/54 (OPEN)
CI: run 38001403498 passou nos cinco checks para SHA 66835d0; novo SHA exigirá nova execução
review: Reviewer APPROVED no recorte final de seleção; Security Reviewer APPROVED na revisão final do coletor; Tester validou a suíte e regressões abaixo
merge commit: N/A
final master: não revalidado após a concorrência; nenhum merge executado
```

O PR #54 foi aberto/publicado nesta branch isolada. O checkout principal
compartilhado continua pertencendo à frente Autonomous Core e não foi alterado.
Nenhum merge foi executado; `origin/master` segue no baseline verificado.

## Escopo e arquitetura observada

- `capability-resolve.ps1` escreve recomendações sanitizadas em JSONL apenas
  quando invocado manualmente; não existe produtor autônomo.
- O Router V1 está desligado pelas flags atuais. A telemetria de Kernel não
  prova uso do Resolver e não expõe, de modo correlacionável, a seleção real do
  Planner, skills/MCPs usados ou outcome produtivo.
- O coletor novo (`scripts/v3/lib/CapabilityAdvisoryCollector.ps1`) lê streams
  explicitamente fornecidos, é offline/read-only, recusa `events-*.jsonl`,
  limita arquivos, bytes, linhas e registros, valida schema e allowlists, não
  ecoa caminhos/campos/texto livre e não altera os streams de origem.
- O relatório é `schema_version: 3`. Recomendações são recomendações da CLI;
  observações fornecidas permanecem `SUPPLIED_UNVERIFIED`. Não há junção entre
  streams, pois falta ID comum escopado de projeto/sessão/run e proveniência
  autenticada. Outcomes e seleção runtime permanecem `NOT_OBSERVABLE`.
- Sem daemon/polling, dispatch extra, escrita no Kernel, alteração de grants,
  ativação de MCP, ou mudança em `NativeDispatch`, `AutonomousLoop`, Task/Goal
  Kernel, watchdog ou produtor de telemetria.

### Matriz de eventos (estado verificado no baseline)

| Evento | Fonte | Runtime/status | Proveniência e autoridade | Dado ausente |
|---|---|---|---|---|
| Recomendação Resolver | `capability-resolve.ps1` → `resolver-*.jsonl` | IMPLEMENTED; CLI manual, não WIRED ao Planner | RECOMMENDED; Resolver consultivo | Execução associada |
| Seleção Planner | nenhuma fonte produtiva identificada | NOT_OBSERVABLE / HOLD | Não há evento confiável | Agente/capabilities escolhidos |
| Uso runtime de skill/MCP | nenhuma fonte correlacionável | NOT_OBSERVABLE / HOLD | Não inferido da recomendação | Uso real e necessidade |
| Ciclo de vida do Kernel | `CapabilityObservability` / Task Kernel | ACTIVE; eventos reais do Kernel | Autoritativo apenas para estado/evento do Kernel | Não prova consulta ao Resolver nem seleção Planner |
| Outcome verificado | Verifier/Kernel para tasks do Kernel | IMPLEMENTED no domínio próprio do Kernel | `verified_pass`/DONE seguem seus contratos | Sem correlação autenticada com recomendação Resolver |
| Router V1 acceptance/shadow | route-accept/shadow-route | IMPLEMENTED, flags OFF; HOLD | Não observado pelo coletor 2G | Eventos produtivos do Planner |

## Collector, correlação e métricas

- **Collector:** leitura explícita de JSONL confinado a `cache/v3/telemetry` ou
  `TEMP`; entrada não é executada nem transformada em fonte de autoridade.
- **Idempotência/determinismo:** recomendação deduplicada por chave projetada;
  relatório não carrega timestamp/caminho livre e serialização foi testada
  entre processos e entre PS 5.1/PS 7.
- **Correlação:** deliberadamente nenhuma (`correlated_pairs=0`); todas as
  recomendações/claims ficam não correlacionados. Ausência de evento nunca é
  convertida em evidência positiva.
- **Proveniência:** `SUPPLIED_UNVERIFIED`; nunca `RUNTIME_OBSERVED`/`VERIFIED`.
  Kernel JSONL é recusado como fonte de observação para esta avaliação.
- **Métricas:** `runtime_adherence`, seleção runtime de agent/skills/MCP,
  `productive_outcome`, acordo e estabilidade são as sete entradas exigidas e
  todas retornam `NOT_OBSERVABLE` com razão. Concordância Resolver/Planner,
  sucesso, over/under-activation e erros críticos: **N/A**, sem denominador
  válido, não `0`.

## Real Evaluation

```text
new real tasks: 0 observações novas verificáveis
projects: nenhum projeto externo consultado ou modificado
fully observed: 0
partially observed: 0
verified outcomes: 0
unknown outcomes: todas as métricas runtime permanecem NOT_OBSERVABLE
2E/2F: somente regressão histórica, não amostras novas
```

O relatório vazio no diretório de evidências é um registro explícito da ausência
de entrada local válida nesta coleta, não uma observação de tarefa. A meta de 20
observações em dois projetos não foi atingida e não bloqueou a entrega da
infraestrutura.

## Routing Metrics

```text
agent agreement: NOT_OBSERVABLE
profile agreement: NOT_OBSERVABLE
skill agreement: NOT_OBSERVABLE
MCP agreement: NOT_OBSERVABLE
over-activation: NOT_OBSERVABLE
under-activation: NOT_OBSERVABLE
critical routing errors: NOT_OBSERVABLE
fallbacks: nenhuma métrica real correlacionável
```

## Performance

```text
collection overhead: não mensurado com fluxo produtivo; suíte inclui testes de limites/escala sintéticos
storage overhead: relatório de status vazio de 3,285 bytes
latency: não mensurada em runtime produtivo
measurement confidence: alta para limites/sintéticos; nenhuma conclusão sobre produção
```

## Safety

```text
permission bypass: nenhum; flags/contratos não alterados
dispatch interference: nenhuma; leitor offline, sem dispatch ou execução externa
session isolation: sem correlação entre sessões; não há prova de isolamento produtivo nova
secret leakage: canários sintéticos cobertos; campos inesperados, IDs e nomes de arquivo não são refletidos
review: Reviewer APPROVED no finding final de seleção; Security Reviewer APPROVED com resíduos TOCTOU/hardlink documentados
```

Resíduo de segurança: a checagem de reparse antecede a abertura, portanto não é
uma defesa atômica contra troca concorrente; hardlinks não são barrados. A
implementação não deve ser tratada como sandbox contra ator local concorrente.

## Regressão e validação

Executado no worktree isolado em PowerShell 5.1 e pwsh 7:

| Comando | Resultado |
|---|---|
| `CapabilityAdvisoryCollector.tests.ps1` | 446/446 PASS em PS 5.1 e PS 7 (pós-findings Codex) |
| `CapabilityRoutingPhase2F.tests.ps1` | 991 PASS / 0 FAIL |
| `CapabilityRealWorldPhase2E.tests.ps1` | 408/408 PASS |
| `tests/distribution/capability-routing-phase2d.tests.ps1` | 372 PASS / 0 FAIL |
| `scripts/test-package-consistency.ps1` | 16 OK / 0 FAIL; flags routing OFF |
| `tests/distribution/run-distribution-tests.ps1` | 20 PASS / 0 FAIL / 1 SKIP (live-hook V2, requisito ambiental) |
| `scripts/v3/run-v3-tests.ps1` completo | 81 PASS / 4 FAIL / 6 SKIP / 91; exit 1 |
| `git diff --check` | limpo após as últimas alterações |

Os quatro failures do runner V3 completo são ambientais, não atribuídos ao 2G:
três assertions do hash vivo `opencode.json` esperam prefixo `DE22307F` e a
máquina tem `C1BB84F2…`; uma suíte de bootstrap assume o diretório de projeto
`opencode-orchestration`, não o worktree `opencode-orchestration-2g`. Os seis
SKIPs são guards/pré-requisitos ambientais. O run completo terminou todas as
suítes, inclusive o coletor 2G. Nenhum dado do usuário, adapter ou registry foi
alterado pelo trabalho 2G; suítes históricas podem produzir telemetria em
`cache/`, conforme seu próprio contrato.

## Eficiência e segurança operacional

- Caps por arquivos, bytes agregados, bytes por linha, linhas por arquivo,
  registros, arrays e saída; leituras incrementais e scanner lexical de
  passagem única. Os caps foram testados em fronteiras e entre os dois streams.
- O coletor não escreve nos inputs. O relatório é escrito separadamente pelo
  fluxo de closure; nenhum JSONL local do Resolver foi encontrado nesta coleta.
- Não foi executada medição de overhead produtivo porque não existe integração
  produtiva observável.

## Gaps de runtime e decisões

- Para habilitar correlação futura, é necessário contrato explícito com
  `project_id`, `session_id`/`run_id`, IDs estáveis e proveniência verificável
  para recomendação, escolha do Planner, execução e resultado verificado. Essa
  mudança compartilhada está fora da 2G atual e não foi introduzida.
- Não coletar de projetos externos sem sessão/autorização própria. Não mudar
  flags para obter amostras.
- Active Mode permanece HOLD. Não é recomendada SPEC de Active Pilot até haver
  dados reais, escopados e verificáveis.

## Commits, PR e veredito

**Follow-up de review do PR #54 (2026-10-09, rodada 2):** os quatro findings
pendentes do review foram endereçados localmente no coletor e na suíte: (1) renomeação do
conjunto local em `Get-AdvisoryIdentifierArray` (sem coincidência de nome
insensível à caixa com `$SetName`), com testes de agentes/skills/profiles/
MCPs conhecidos e arrays de claim fornecidos; (2) confinamento de caminho com
comparação própria da plataforma (Windows `OrdinalIgnoreCase`, Unix
`Ordinal`); (3) `dropped_input_keys_count`/`sensitive_keys_dropped` passam a
cobrir toda propriedade desconhecida de primeira nível (Unicode e nomes com
mais de 64 caracteres), sem ecoar nome/valor; (4)
`uncorrelated_observation_keys` passa a contar toda chave distinta aceita,
inclusive a ambígua (a emissão de claim conflitante segue omitida). A suíte
2G fecha em 446/446 em PS 5.1 e em PS 7 (`schema_version` permanece 3; nenhuma
chave do relatório foi acrescentada ou removida). As threads não foram
marcadas como resolvidas; depois do push do follow-up, aguardar CI do novo SHA.
Nenhum merge foi executado.

Commits anteriores: `2e581d1` (plano), `c1139a4` (coletor, suíte e relatório),
`ffc9055` (closure) e `66835d0` (PR/CI). O follow-up dos findings Codex está
validado localmente; commit/push em separado. O PR #54 permanece aberto. A CI
do SHA `66835d0` passou nos cinco checks; o novo SHA precisará executar CI
novamente após push. `origin/master` foi revalidado e continua em
`b38c92bc8b3ab334a9dffad609f3515350336061`. Nenhum merge foi executado. A
outra sessão do Autonomous Core permaneceu isolada; os
arquivos `source/adapters/opencode.md` e
`source/adapters/opencode-v2.md` do worktree principal não foram tocados.

```text
Resolver: SHADOW/ADVISORY
Observer: VALIDATED (offline; real-world evaluation PARTIAL/UNAVAILABLE)
Planner authority: UNCHANGED
Kernel authority: UNCHANGED
Active Mode: HOLD
Flags: UNCHANGED
Next Recommendation: COLLECT_MORE_REAL_DATA
```
