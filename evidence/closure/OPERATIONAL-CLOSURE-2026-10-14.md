# Operational Closure Report — refinamento funcional (execução parcial)

**Data:** 2026-10-14. **Status:** PARTIAL/HOLD; não é `FUNCTIONAL_COMPLETE` nem release.
**Plano:** [F0–F7](../../docs/plans/OPERATIONAL-REFINEMENT-FUNCTIONAL-STABILIZATION-PLAN.md).
**SHA inicial:** `3d3ba0eeab8402b519a2edee0177117cc4cc33da`, branch `master`.
**SHA de commit final:** não produzido; alterações de trabalho precisam ser consideradas junto ao SHA.

## Autorização, isolamento e budgets

O usuário solicitou implementação autônoma do plano inteiro após a revisão. O escopo
operacional executado é desenvolvimento local, fixtures próprias e serviço de teste
isolado. Isso não autentica grants do host nem resolve mediação/atestação upstream.
Sem merge/deploy/publicação, instalação global, mudança de pins/flags, provider pago,
criação de credenciais ou mutação nos projetos Synkroo/Ted/IPTV.

- Baseline: até 15 minutos por worker; testes curtos até 120 s; watchdog até 420 s.
- Runtime real: reutilizar pin instalado, sem upgrade; homes/portas/jobs exclusivos,
  sem modelos pagos ou credenciais de modelo; respeitar deadlines dos harnesses existentes.
- Evidências runtime explícitas em `C:/Users/walis/AppData/Local/Temp/opencode/`; outras
  fixtures usam TEMP GUID próprio dos harnesses existentes. Nenhuma chave/log bruto
  de configuração entra neste relatório. Custos de modelo não observados = desconhecidos.
- Preflight: `DETERMINISTIC_FALLBACK`, `hard_exclusion_security_sensitive`; security-reviewer
  aprovou apenas desenvolvimento local delimitado. Architect confirmou lacunas de caller
  distribuído e scheduler, sem recomendar outro kernel/daemon.

## F0 — inventário e baseline

- Tree inicial: somente o plano revisado não rastreado; preservado.
- `git fetch origin` não destrutivo concluído; `origin/master` = SHA inicial acima.
- Remote: `https://github.com/Kusts/opencode-orchestration.git`.
- Consulta remota: nenhum PR aberto no momento da coleta.
- CI do SHA base: [run 38565525111](https://github.com/Kusts/opencode-orchestration/actions/runs/38565525111),
  `completed/success`. **Não valida alterações locais posteriores.**
- [#69](https://github.com/Kusts/opencode-orchestration/issues/69) e
  [#70](https://github.com/Kusts/opencode-orchestration/issues/70): `OPEN`.
- [#86](https://github.com/Kusts/opencode-orchestration/issues/86): `OPEN`; contrato exige
  executor persistente real e wake comprovado, não apenas arquivo/evento de readiness.
- Flags canônicas: task kernel/watchdog/bounded/jev/worktree ativos; enforcement v2,
  roteamento active/shadow, skill/mcp/adaptive continuam desligados.
- Inventário independente: runtime do PATH `2.0.29` via shim local (drift frente ao
  pin `2.0.23`, não corrigido); PS5.1 `5.1.26100.9444`, PS7 `7.6.6`; source 19 workers,
  template V2 21 blocos. Config ativa: somente contagem em disco (~21); carregamento
  efetivo de todos os perfis/providers não atestado. Worktrees preexistentes preservados.
- Baseline inicial: consistência 16/16; Golden 71 assertions/15 casos, Jev 188,
  DecisionWiring 28, McpSafety 203 e PlannerLoop 41 verdes nas duas engines; TaskKernel
  94/94 no PS5.1, 93/94 no PS7 em duas execuções. Watchdog enforcement 432/432 no PS5.1.
  A falha PS7 foi diagnosticada e corrigida abaixo, não ocultada por rerun.
- Distribuição isolada: fresh-install 42/42, idempotency 14/14, config-preservation
  11/11, rollback 33/33 e profile-isolation 39/39 **em PS5.1 e PS7**. Nenhum destino ativo
  alterado, nenhum provision de runtime ou rede. SKIPs do profile-isolation preservados:
  wrapper V1 ausente e cache do cenário d `2.0.18` divergente do pin; essas pernas não
  foram provadas, mesmo com os asserts executados verdes.

## Mapa produtivo e classificação das lacunas

| Frente | Fato observado | Classe / condição para avançar |
|---|---|---|
| F1 | PREPARE/CLAIM/SETTLE/ADVANCE existem na biblioteca; não há caller produtivo distribuído de `Invoke-OrchestrationAutonomousObjective`; instalador não distribui `scripts/v3` como bridge confiável | WIRING + fronteira G1 bloqueada; delimitar B10, localização confiável e origem dos grants antes de integração produtiva |
| F2 | Reconciler escolhia a última observação contraditória; lease futura PS7/pt-BR era considerada inativa | FIXs reproduzidos e corrigidos; fixtures verdes, recovery funcional total ainda parcial |
| F3 | Repo não possui executor agendado sobrevivente provado; APIs V2 storage/prompt não provam scheduler | UPSTREAM_BLOCKED/BLOCKED_OPERATOR conforme capacidade e infraestrutura; não implementar daemon alternativo |
| F4 | Jev/MCP estão expostos nesta sessão; consultas continuam consultivas, sem autoridade de grants/DONE | TEST; integração completa ainda exige workflow real e provas negativas |
| F5 | Healthcheck classificava só amostra de cinco erros e aceitava loading sem tempo verificável após cutoff | FIX/TEST entregue, sem ampliar permissões; fingerprints não são atestação |
| F6 | Golden existente é harness, não a matriz normativa de 15 workflows do usuário | TEST; manter numerações distintas, sem promoção de HARNESS_PASS |
| F7 | Documentação e relatório incrementais | DOC; release depende dos gates e autorização própria |

## Reproduções e implementação

### Reconciliação de sessão (F2)

Reprodução real de função antes da correção: mesmo binding `ses_diag`, observações
`completed/output_ref=artifact-ref` e `missing`. Uma ordem retornou `mark_SESSION_LOST`;
a ordem inversa retornou `recover-output`. Causa: índice `obsById` sobrescrito antes
de validar conflitos. O resultado é recomendação, não prova de perda nem mutação do kernel.

Correção entregue: observações conflitantes/inválidas entre duplicatas produzem
`stale/ambiguous_observations`, output vazio e nenhuma ação, independentemente da ordem.
Duplicatas equivalentes podem colapsar; não adotar heurística de timestamp mais recente.
Fixture: 193 assertions PS5.1/PS7. Review técnico e security APPROVED para a fatia.
Validação integrada final independente concluída (193/193 em cada engine);
não declarar F2 completo por esse fix.

### Expiração de leases (F2)

Reprodução em PS7 `7.6.6`, cultura `pt-BR`: JSON de expiry futuro em 2030 é convertido
em `System.DateTime`. O cast string gera `10/14/2030 12:00:00`, incompatível com parse
cultural pt-BR, e o predicado anterior retorna inativa. Isso explica o FAIL de
`foreign active lease on write scopes yields ownership_conflict` na baseline.

Fix em `Test-OwnershipLeaseActive`: DateTime/DateTimeOffset tratados sem cast cultural;
strings com parsing invariant/UTC; valores não escalares rejeitados. Testes com culturas
pt-BR/en-US e roundtrip JSON: Ownership 82/82 e TaskKernel 94/94 em cada engine segundo
execução do Coder e confirmados independentemente abaixo. Nenhuma alteração em grants,
kernel, schema ou stores de leases reais. Review e security APPROVED.

### Diagnóstico V2 (F5)

Correção entregue no healthcheck: separar total de erros da amostra, selecionar
run exato, respeitar cutoff temporal e manter fingerprints diagnósticos distintos de
atestação/enforcement. Nenhuma execução de script obtido de log nem mudança em config ativa.
Novos testes: 23 assertions com filho PS5.1 ou PS7 real, inclusive erro #6, token prefixado/
sufixado, cutoff sem timestamp, hashes mudados e redaction. Review e security APPROVED;
testes finais integrados confirmados independentemente (23/23 em cada engine).

### Wiring de regressão (F6)

Adicionados steps fail-loud nos jobs existentes `ci-ps51` e `ci-ps7`: healthcheck,
Ownership, SessionReconciler e TaskKernel diretamente pelo engine do job. O runner V3
continua como antes (filhos PS5.1); não confundir seu host com engine do produto.
YAML parseado localmente; seis jobs preservados, sem novos checks ou relaxamento de gates.
Não houve push: CI dessas alterações ainda não executado no GitHub.

## Runtime real e integrações

- Smoke de lifecycle V2: **RUNTIME_REAL_PASS no escopo de lifecycle**, binário pinado
  `2.0.23`; set/start/status/stop owned/settlement, job de teste e porta privada `63532`.
  Porta `49374` ausente antes/depois; home isolado, sem chamada de modelo.
  Evidência: `C:/Users/walis/AppData/Local/Temp/opencode/orfs-lifecycle-20261014-a.json`.
  Não prova F1 normal, recovery consumida por modelo nem GW09.
- Lane cross-session isolada 16/17/19/20/21: **3 pass-real (16/17/19), 2 blocked (20/21),
  0 fail**; exit 1 por bloqueios honestos, sem model key/fallback pago. Tempo ~90 s.
  Evidência: `.../orfs-session-20261014-a-evidence/lane-summary.json`.
  Preservação/rebind/releitura kernel-side provados; consumo/releitura pelo Planner
  substituto com turno de modelo não provados. Esses resultados não passam GW08 inteiro
  nem GW09 e não substituem duas sessões independentes dos gates normativos.
- Jev MCP real: consulta sobre suficiência de storage/prompt sem scheduler sobrevivente;
  probabilidade `0.11`, `likely=false`, 2186 ms. Recomendação considerada: preservar
  bloqueio de retomada automática sem prova de lifecycle/consumo. Não alterou grants/flags.
- AI Memory: consulta remota deste projeto (`ferramentas/opencode-orchestration`) retornou
  histórico. Nenhuma escrita durável nem promoção automática de memória a autoridade.
- Documentação oficial V2 consultada: [API](https://opencode.ai/v2/docs/api) e
  [plugins](https://opencode.ai/v2/docs/build/plugins), mais Context7 V2. Storage durável,
  session.prompt e cleanup de timers são capacidades documentadas, **não** prova no pin
  de scheduler sobrevivente/wake após encerramento.

## Matriz dos gates e Golden Workflows

Nenhum dos 15 GW normativos ganhou PASS funcional nesta execução até este registro.
As classificações abaixo são lacunas atuais, não resultados negativos de teste não executado.

| Gate | Estado atual | Prova que falta |
|---|---|---|
| F0 | PARTIAL | baseline independente completo e validação do ambiente efetivo |
| F1 / GW01–04,15 | HOLD | B10 e bridge confiável; sessão nova, fluxo normal, três fases sem driver |
| F2 / GW07,08,11,13 | PARTIAL | fix com regressão e review; recovery por substituta com ação atribuída; cenários runtime normativos |
| F3 / GW09,10 | BLOCKED_OPERATOR | executor sobrevivente autorizado e wake/consumo reais; CI vermelho com diagnóstico autorizado |
| F4 / GW05,06,12 | PARTIAL | workflow completo consultivo/negativo; permissão kernel não equivale a host deny |
| F5 / GW14 | PARTIAL | diagnóstico corrigido, provas por runtime/config/plugin e versão compatível |
| F6 | HOLD | matriz normativa completa runtime-real, duas sessões críticas independentes |
| F7 | PARTIAL | relatório incremental apenas; sem release/fechamento integral |

## Validação independente do estado entregue

| Suíte / check | PS5.1 | PS7 | Escopo |
|---|---|---|---|
| plugin-healthcheck.tests.ps1 | 23/23 | 23/23 | filho usa engine real; erros/cutoff/token/metadados |
| OrchestrationOwnership.tests.ps1 | 82/82 | 82/82 | expiry tipado/ISO/offset, pt-BR e en-US |
| OrchestrationSessionReconciler.tests.ps1 | 193/193 | 193/193 | ordem, casing ordinal, duplicatas inválidas |
| OrchestrationTaskKernel.tests.ps1 | 94/94 | 94/94 | inclui ownership_conflict que falhava na baseline |
| test-package-consistency.ps1 | 16/16 | 16/16 | consistência do pacote |

Comandos: `powershell -NoProfile -File <suíte>` e `pwsh -NoProfile -File <suíte>`,
sem wrapper que troque a engine. Tester independente: PASS, exits 0, zero falhas no
escopo final. Recovery 61/61 e TaskBindings 29/29 também passaram na validação anterior
dos consumidores; TaskBindings exercita suas duas engines próprias.

Repro PS7/pt-BR pós-fix: expiry JSON 2030 retorna ativo; observações contraditórias em
ambas as ordens retornam `stale/ambiguous_observations`, output vazio e zero ações.
YAML parseado com seis jobs; novos steps propagam falhas das quatro suítes. Review técnico
e security APPROVED para as correções delimitadas; a aprovação não abrange enforcement,
produção ou o programa inteiro. `git diff --check` limpo e links locais validados.
`Test-OrchestrationDoneCompliance` = COMPLIANT para participação/orquestração deste
trabalho; não é `Complete-OrchestrationTask`, Goal COMPLETED ou PASS dos gates funcionais.

## Métricas e prontidão

- Baseline TaskKernel PS7: 93/94; após correção: 94/94 (causa reproduzida, não rerun cego).
- Novas regressões repetíveis: healthcheck 23, ownership +26 e reconciler +37 assertions.
- Runtime parcial: lifecycle PASS; cross-session 3 pass-real, 2 blocked, 0 fail.
- Objetivos normativos concluídos pelo fluxo normal: **não observado**. Não converter em
  taxa de sucesso 100%, custo zero ou retomada automática. Latência CI→resume: não medida.
- Custos de modelo/tokens e efeitos em projetos pilotos: não medidos nesta execução.
- Prontidão: correções locais revisadas e testadas; release **HOLD** até gates obrigatórios.

## Próxima decisão e limitações

F1 exige resolução contratual de B10, bridge distribuído confiável e prova no fluxo normal;
F3 exige executor sobrevivente nomeado/autorizado e wake efetivamente demonstrado. As pernas
20/21 exigem provider/orçamento autorizado para turno real do substituto; não houve troca
para provider pago. Essas condições impedem a implementação integral comprovada nesta rodada.
Os testes/GWs não executados não são FAIL nem PASS.
Não fechar issues pelo CI base nem por fixture. Sem garantias obrigatórias upstream,
não usar `FULL_PRODUCTION_READY`. Merge/deploy/pilotos/scheduling/global install continuam
operações separadas; o pedido de autonomia não remove suas fronteiras.

## Continuação solicitada — observação GitHub e spike F3

**Estado desta fatia:** em execução, sem resultados antecipados. As correções da rodada
anterior são baseline preservada; não constituem autorização para F1 produtivo.

- Preflight da continuação: `MULTI_WORKER`, `non_trivial`; descoberta read-only e parecer
  de Architect delimitaram preparação separada de registro produtivo/wake.
- Implementação delimitada: readiness puro em Delivery e request para `external_dependency`
  em AutonomyWiring, mais CLI `github-await -Action observe` de consulta única bounded.
  A CLI não bloqueia/desbloqueia task, não chama Planner, não concede grants e não faz merge.
- Identidade da espera proposta: repo + número do PR + SHA esperado. Novo SHA é nova
  dependência, não retarget silencioso da espera antiga; run id não redefine a identidade.
  O kernel existente continua dono do fingerprint/persistência. Não criar store paralelo.
- Consulta GitHub: fixed GraphQL, public host explícito, credential profile existente
  somente read-only. Paginação incompleta, erro GraphQL mesmo com HTTP 200, SHA divergente,
  check obrigatório ausente/duplicado e dados inconclusivos não produzem readiness otimista.
- Spike isolado: uma questão — timer após encerramento da sessão e reidratação de storage
  após restart owned do serviço V2 `2.0.23`. Timebox 12 min; homes/portas/jobs próprios em
  TEMP; sem modelos, scheduling global ou webhook. Código experimental não será produto.
  Mesmo um sucesso desse experimento não passa GW09 sem wake/consumo real pelo Planner.
- Bibliotecas mantêm contrato offline. Transporte fica só na CLI; snapshot/readiness são
  dados, não novos estados ou autoridade do kernel. F3 funcional continua condicionado.

## Continuação 2026-10-14 (tarde) — observe GitHub entregue, spike bloqueado

**Fatia observe-only F3 (preparação, não watcher):** readiness puro
(`Get-OrchestrationGitHubReadiness`) + request de wait tipado
(`New-OrchestrationGitHubWaitRequest`, depid `github-ci:v1:<repo>:<pr>:<sha>`)
+ CLI `scripts/v3/github-await.ps1 -Action observe` de consulta GraphQL única
bounded (timeout ≤10 s, cap 256k/stream, hostname fixo `github.com`, sem
mutation/retry/paginação/cache). Snapshot/readiness são dados; a CLI não
bloqueia/desbloqueia task, não chama o Planner, não concede grants e não faz
merge. Registro produtivo no kernel continua com o caller autorizado via
`New-TaskKernelTypedWait` + `Block` existentes — fora desta fatia.

**Endurecimentos revisados (review + security APPROVED):** `errors[]` GraphQL
rejeitado fail-closed sem echo mesmo com data verde; `checks_complete` =
completude da resposta/paginação (required verdes + extra pendente não bloqueia
no snapshot — a pura decide); nomes validados no raw antes de Trim
(controles/vazio/>200 => `check-name-invalid`, sem colapso para required);
`conclusion` restrita aos 7 enums; transporte próprio com dreno concorrente em
blocos 4k e teto cap+1 durante a leitura (testemunha conta, inclusive término
exato em cap+1); `action` inválida com valor fixo; redação de segredos
heurística documentada como não-universal.

**Validação:** `github-await.tests.ps1` **237/237 em PS5.1 e PS7**
(TESTER_PASS), incluindo filho sintético 400k truncado sem OOM/deadlock,
cap−1/cap/cap+1 nos dois streams, controles de borda e allowlist; sonda live
opt-in não executada (offline default). Steps ORFS-F6 do CI passam a executar
a suíte nos dois jobs pelo engine real, sem novos jobs/checks. Review técnico e
security aprovaram a fatia; aprovação limitada, sem cobrir wake/enforcement.

**Spike F3 (3 tentativas, timebox consumido):** causa raiz do trigger
identificada e corrigida (guard `-StdinNul` recusava `--data '{}'` com
exit −3 antes do CLI; remoção pontual no runner TEMP gerou sessão real
`ses_*`). Mesmo com trigger real, o plugin fixture nunca carregou
(`plugin_boot` ausente, zero linhas `loading-plugin`, sink com fallback
hardcoded nunca escrito) — falha isolada no estágio loader, não prova de
capacidade. **Timer com host vivo: NOT_OBSERVED; storage após restart:
NOT_OBSERVED; scheduler/wake + consumo pelo Planner: NOT_TESTED.**
F3/GW09 seguem `BLOCKED` no estágio observado; sem quarta tentativa nesta
rodada. Efeito colateral honesto: `serve --service` escapa do JobObject do
spawn CLI — backstop kill-on-close não provado para ele; stop owned
graceful continua primário.

**Matriz atualizada:** F3 preparação = PARTIAL (observe + readiness + request
testados offline, sem wake); F3 funcional/GW09 = BLOCKED; F1 = HOLD (B10);
programa segue PARTIAL/HOLD, sem `FUNCTIONAL_COMPLETE`.

## Prova F1 2026-10-14 (tarde) — Planner-driven cooperativo, settlement kernel

**Lane:** `supervised-cooperative` delimitada pelo
[ADR](../specs/ORFS-SUPERVISED-COOPERATIVE-LANE-ADR.md) (B10 resolvida como
decisão de escopo; SPEC histórica intacta; strict segue bloqueado #69/#70).
Sessão nova, fluxo normal, sem driver: o Planner executou cada transição do
kernel explicitamente; workers reais via tool nativa `subagent` (V2).

**Resultado:** goal `f1-goal` ACTIVE → COMPLETED via CAS (rev 10,
`progress.satisfied=3/total=3`, `completed=[f1p1,f1p2,f1p3]`). Prova em
[ORFS-F1-PROOF-2026-10-14.md](./ORFS-F1-PROOF-2026-10-14.md) (22 linhas).

| Task | Trabalhadores | Ordem temporal | Estado |
|---|---|---|---|
| f1p1 | coder→tester→reviewer reais | record(4) < verify(6) < review(8) < DONE(9) | DONE rev 9 |
| f1p2 a1 | coder→tester (FAIL honesto: link quebrado declarado) | failed(6) → FIXING(7) | — |
| f1p2 a2 | coder retry → tester PASS → reviewer APPROVED | record(12) < verify(15) < review(17) < DONE(18) | DONE rev 18 |
| f1p2 a3 | reviewer CHANGES_REQUIRED (rótulo a1/a2) → fix → re-verify → APPROVED | record → verify → review → DONE | incluído no DONE rev 18 |
| f1p3 | coder→tester→reviewer reais | record(4) < verify(6) < review(8) < DONE(9) | DONE rev 9 |

Cancelamento explícito: `f1-p1` (bench TEMP) CANCELLED rev 6 com motivo
(superseded pela prova repo-scoped que o verificador exige) — zero tarefas
abandonadas sem estado. Grep `verified_pass` no artefato = 0: nenhum worker
declarou prova; `verified_pass` só do verificador allowlisted
(`package-consistency` + scope check por task). Gates honestos observados:
`INVALID_VERIFIER_RESULT` (laudo fora do shape), `out_of_scope_write`
(ADR não-commitado no diff), `COMPLETION_GATE_FAILED` (compliance/riscos),
`UNTRUSTED_IDENTITY`/`CAS_CONFLICT`/`ILLEGAL_TRANSITION` (identidade e ordem).

**Limites:** proveniência `declared` (sessões `ses_*` desta rodada), sem
atestação host; segunda sessão independente pendente (Onda 2 é a sessão-irmã
com mesmo desenho: 3 fases + fault-injection + CAS). Veredito: F1 caminho
cooperativo = RUNTIME_REAL_PASS (supervised); strict = BLOCKED.

## CI da branch (PR #89)

Run `38603241301` (commit `96fad69`): 5/6 verde; `CI (ps7)` FAIL com 1/95 —
`OrchestrationRuntimeWatchdogEnforcement.tests.ps1` 426/6, os 6 em FIX5-2
(timing de kill/settlement em runner carregado). ps51 verde no mesmo commit;
nenhum arquivo nosso toca watchdog. Classificação: suspeita de flake mesma
classe F1/JOB46/JOB48, causa UNKNOWN até rerun/diagnóstico — sem relaxar
invariante, sem rerun-como-correção. Runs `38606718116`/`38607508804`
em andamento dirão se é intermitência do runner.
