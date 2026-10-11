# Closure operacional de capabilities OpenCode — 2026-10-10

Veredito: **PARTIAL**. Esta rodada fecha a causa da falha de uma fixture de
distribution e valida o ciclo de vida V2 isolado. Não fecha a disponibilidade
dos browser MCPs, a conexão dos servidores browser, o isolamento entre sessões
do mesmo serviço nem a invocação por agentes canônicos.

## Git e governança

- `origin/master` no início: `b38c92bc8b3ab334a9dffad609f3515350336061`.
- Branch exclusiva: `feat/opencode-capabilities-runtime-validation`, derivada
  de `origin/master`; o checkout principal e o worktree `2G` permaneceram
  intocados.
- PR #58 permanece aberto. Cinco checks verdes, conversas sem threads, sem
  aprovação GitHub registrada. Resultado: `HUMAN_REVIEW_REQUIRED`; nenhum merge
  ou bypass. A proteção consultada tinha `required_approving_review_count=0`,
  mas não foi usada como substituto da revisão formal solicitada pelo operador.
- PR #54 foi apenas consultado e não modificado.

## Browser MCPs e isolamento

Pins confirmados sem upgrade: OpenCode V2 `2.0.23` (global `2.0.26`),
Playwright MCP `0.0.83` e Chrome DevTools `1.10.1` FULL.

| Verificação | Resultado | Evidência/limite |
|---|---|---|
| Serviço privado V2 | PASS | `serve` em porta dinâmica exclusiva; config/data/state/cache e HOME em diretório temporário. Nenhum acesso à porta `49374`. |
| Profile `testing` no serviço privado | `NOT_VERIFIED` para uso | `/api/mcp` listou os IDs `playwright` e `chrome-devtools`, mas ambos reportaram `pending`; nenhum catálogo de tools conectadas foi comprovado. |
| Processo sem profile | PASS (negativo de configuração) | Segundo serviço, diretórios e porta independentes, config `default` sem MCPs; `/api/mcp` listou zero servidores. |
| Isolamento de configuração entre processos | PASS | O serviço `testing` listou dois IDs configurados; o serviço `default` listou zero. Isso não prova que os MCPs browser conectaram. |
| Isolamento entre sessões no mesmo serviço | `SESSION_ISOLATION_NOT_PROVEN` | O overlay existente grava/remova JSON shadow por `session_id`; não altera a configuração efetiva. A API documentada de connect/disconnect MCP opera no servidor, não por sessão. |
| Ativação/liberação efetiva de `testing` | `NOT_VERIFIED` | Os testes do overlay provam criação/liberação do artefato shadow, não ativação/desconexão runtime. Nenhuma configuração foi persistida. |

Os processos de teste, subprocessos MCP e diretórios temporários próprios foram
encerrados/removidos. `49374` permaneceu ouvindo pelo mesmo processo antes e
depois dos testes. Não houve dependência desse serviço.

## Agentes canônicos

- `tester`: a sessão real do agente não recebeu Playwright nem Chrome DevTools;
  as ferramentas não foram oferecidas e não foram invocadas. O agente executou
  validação de código, não uma tarefa browser. `AGENT_TOOL_INVOCATION_NOT_VERIFIED`.
- `debugger`: nenhuma chamada DevTools por esse agente foi possível/comprovada.
  `AGENT_TOOL_INVOCATION_NOT_VERIFIED`.
- JSON-RPC independente anterior não foi contado como chamada de agente.

## Plugin AI Memory e MCPs core

- O `plugin-healthcheck` observou `ai-memory-opencode2.ts` e
  `orchestration-enforcement.js` presentes, shape `v2_object`, linha
  `loading-plugin` e `healthy=true` para ambos. Isso comprova descoberta/carga
  observada, não execução end-to-end dos hooks AI Memory. Separadamente, o MCP
  AI Memory respondeu `memory_status`.
- `plugin-healthcheck`: **FAIL** somente pelo backup
  `ai-memory-opencode2.ts.bak-1791360135` ainda presente na raiz autodetectada.
  O log examinado não continha linhas de load para esse backup. Isso não o torna
  permitido pela política da raiz. Não foi movido, renomeado ou excluído.
- Issue #25 permanece aberta; a origem da recorrência não foi localizada nem
  resolvida. Não reinstalamos plugin V1.
- `AI Memory`, `Context7` e `Jev` permanecem diretamente configurados no bloco
  MCP global do operador. Nenhuma configuração global foi alterada. A
  recomendação é mantê-los como exceção explícita por ora: a migração seletiva
  só traz isolamento real quando houver suporte de escopo efetivo por sessão;
  custo em tokens e filtragem por agente não foram medidos nesta rodada. Cabe ao
  operador ratificar essa exceção.

## Baseline e validação

- Package consistency: **16/16 PASS**.
- V3: **80 PASS / 4 FAIL / 6 SKIP**, sem falha de execução interna. As falhas
  observadas nesta rodada foram:
  - `session-bootstrap-context.tests.ps1`: `w1c` e `w14` esperam
    `project_id=opencode-orchestration`, mas o builder deriva o ID do basename
    do checkout (`capabilities-runtime-validation-b38c92b`). Classificação:
    dependência de identidade/nome no teste/ambiente, não bug do builder
    demonstrado.
  - `CapabilityObservability.tests.ps1`, `CapabilitySkillUtility.tests.ps1` e
    `shadow-route.tests.ps1`: uma asserção em cada compara config global
    user-owned com prefixo histórico `DE22307F`; hash observado
    `C1BB84F2…`. Classificação: teste não hermético/ambiente; não prova que a
    suíte alterou a configuração. Nenhum hash esperado foi alterado.
- Distribution antes da correção: **19 PASS / 1 FAIL / 1 SKIP**. Suíte
  isolada identificada: `capability-routing-phase2d.tests.ps1`, duas falhas no
  teste de containment.
- Correção aplicada somente a
  `tests/distribution/capability-routing-phase2d.tests.ps1`: o filho recebe
  `TEMP`/`TMP` efêmeros que não incluem o checkout, e as variáveis do pai são
  restauradas em `finally`. Os asserts originais (`exit 2` e nenhum arquivo)
  foram mantidos. Tester independente: **372/372 PASS** em PowerShell 5.1 e 7;
  Reviewer independente: `APPROVED`.
- Distribution completa pós-correção: **20 PASS / 0 FAIL / 1 SKIP**.
- Focalizadas: MCP profiles 8/8, capability registry V2 48/48, capability
  planning 12/12, skills catalog 18/18. Healthcheck de skills: PASS.
- Smoke de lifecycle V2 exato `2.0.23`: **PASS, 14 checks**, home isolado,
  serviço explicitamente iniciado/parado/settled. Evidência temporária
  confirmou a mesma identidade de listener `49374` antes/depois. Esta prova
  não cobre conexão de browser MCP.
- Plugin healthcheck: FAIL conforme descrito acima. V1 smoke:
  `V1_NOT_VERIFIED` (nenhum binário/perfil V1 disponível; sem instalação).

## Segurança e configuração

- Nenhum segredo real impresso ou persistido; verificações de healthcheck
  expuseram nomes/presença de variáveis, não valores. Senha sintética foi usada
  apenas no servidor privado de teste.
- Nenhuma permissão, flag, registry, plugin ativo ou config global foi alterada.
  Nenhum MCP browser foi persistido. `runtime_grant_enforcement`, `mcp_routing`,
  `skill_routing`, `adaptive_ranking`, `routing_telemetry` e
  `capability_reconciler` permaneceram inalterados/off.
- O runner de distribution criou `models.jsonc` ignorado no worktree de teste;
  foi preservado, não versionado. Nenhum artefato temporário de browser ou
  serviço permaneceu.

## Pendências

| Item | Status |
|---|---|
| Corrigir fixture de containment que falhava por repo sob `$TEMP` | `RESOLVED` |
| Isolamento MCP de configuração entre processos (IDs listados; ainda `pending`) | `PARTIAL` |
| Browser MCP conectado e tools descobertas no runtime V2 | `EXTERNAL_DEPENDENCY` |
| Isolamento por sessão no mesmo serviço e profile efetivo on-demand | `FUTURE_BACKLOG` (runtime atual não provado) |
| Uso de Playwright pelo `tester` e DevTools FULL pelo `debugger` | `OPERATOR_ACTION_REQUIRED` (sessão/serviço que ofereça MCPs conectados) |
| Backup AI Memory na raiz ativa e investigação da recorrência (#25) | `OPERATOR_ACTION_REQUIRED` |
| V3: basename fixo e comparação de hashes do config vivo | `FUTURE_BACKLOG` (sem alterar expectativas nesta rodada) |
| Decisão de manter os três MCPs core globais | `OPERATOR_ACTION_REQUIRED` |
| V1 smoke | `EXTERNAL_DEPENDENCY` |
| PR #58 aprovação/decisão de merge | `HUMAN_REVIEW_REQUIRED` |

Evidência estruturada e sanitizada: `evidence/capabilities-runtime-validation-2026-10-10/runtime-audit.json`.
