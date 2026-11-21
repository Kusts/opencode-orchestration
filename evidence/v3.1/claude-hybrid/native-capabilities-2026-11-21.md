# Capacidades nativas consolidadas — 2026-11-21

> **Escopo e cautela.** Este arquivo consolida, em modo de registro, os três inventários somente leitura produzidos em 2026-11-21 para Claude Code 2.1.330, Orca 1.4.267 e OpenCode 2.3.2. As colunas "decisão sugerida" das tabelas registram **sugestões**, não decisões aprovadas: nada foi adotado, substituído ou removido com base nelas. **Toda afirmação de "sem caller de produção" exige prova própria antes de qualquer remoção** — a ausência observada em uma leitura não autoriza excluir código; `OrchestrationPlannerWait.ps1`, por exemplo, é referenciado pelo plugin. Status, IDs e achados da missão estão em `mission-2026-11-21.json`.
>
> Caminhos locais absolutos foram anonimizados (`<USER_HOME>` para a raiz do perfil, `<REPO_ROOT>` para a raiz do repositório). Não há e-mail, ID de conta do Orca nem valor de segredo neste registro; o único token com prefixo de segredo presente é o canário sintético `sk-SYNTHETICSECRET`.

## Claude Code 2.1.330

Tarefa somente leitura. Nenhum comando que chama modelo foi executado, nenhuma configuração foi alterada e nenhum valor de `env`, token ou `.credentials.json` foi lido.

### Provas coletadas no host

- `claude --version`: `2.1.330 (Claude Code)`.
- `claude --help` e `--help` de `mcp`, `plugin`, `agents`, `doctor`, `auto-mode`, `ultrareview`, `gateway`, `import`, `purge`, `install` e `setup-token`.
- `claude doctor`: instalação nativa 2.1.330, "No installation issues found", auto-update habilitado no canal latest.
- `~/.claude/settings.json`: somente nomes de chaves. Há 17 eventos de hooks configurados, além de `skillListingBudgetFraction` (0.1), `CLAUDE_CODE_SUBAGENT_MODEL` em `env`, `disableAgentView: true`, `autoCompactEnabled: false` e `promptSuggestionEnabled: false`.
- `claude respawn`, `stop`, `attach` e `logs` retornam "disabled by the 'disableAgentView' setting". A própria flag `--bg` e o `claude agents` ficam fora de uso por esse ajuste.
- Documentação oficial (complemento, não prova de disponibilidade): `agent-teams` (experimental, habilitado por `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), `skills` (`disable-model-invocation`, `paths`, locais de carga) e `hooks` (25 de 33 eventos confirmados, incluindo `SubagentStop`, `PostToolBatch`, `TeammateIdle` e `PostCompact`). Não li `settings` nem `cli-reference` até o fim; o item `skillListingBudgetFraction` ficou sem confirmação na parte lida.
- Repositório: `source/claude/` (CLAUDE.hybrid.md e a skill `hybrid-orchestration` com 3 references), `scripts/claude/install-claude-hybrid.ps1` (chamado por `install.ps1 -ClaudeHybrid` em 4 pontos) e `docs/HYBRID-ORCHESTRATION.md`. A busca mostrou que o repositório não tem hooks Claude, subagentes `.claude/agents`, `claude -p` em produção nem chamada a `--resume`. `docs/HYBRID-ORCHESTRATION.md` registra `claude -p` como `HOLD_NOT_VERIFIED`.

### Tabela de capacidades

Colunas: capacidade | comando/API exato | prova no host | componente nosso equivalente (arquivo) | caller de produção | status de uso | limitação | ganho esperado | decisão sugerida | teste de paridade necessário.

| Capacidade | Comando/API exato | Prova no host | Componente nosso equivalente (arquivo) | Caller de produção | Status de uso | Limitação | Ganho esperado | Decisão sugerida | Teste de paridade necessário |
|---|---|---|---|---|---|---|---|---|---|
| CLAUDE.md, auto-discovery | `CLAUDE.md`; desligado por `--bare` | PASS (help de `--bare`) | `scripts/claude/install-claude-hybrid.ps1` (bloco marcado em CLAUDE.md) e `source/claude/CLAUDE.hybrid.md` | `install.ps1 -ClaudeHybrid` (linhas 77-79, 1427, 2063, 2666), acionado pelo usuário | PARCIAL | Sintaxe de `@import` e rules não verificada neste host (HOLD) | Eliminar gerenciamento de bloco, manifesto e backup do instalador | REPLACE (candidato) | CLAUDE.md resolvido em sessão isolada com `CLAUDE_CONFIG_DIR` temporário carrega o conteúdo; perfil real intocado |
| Imports e rules (`@import`, `.claude/rules`) | sintaxe em CLAUDE.md | HOLD (não lida na documentação) | nenhum | nenhum | NÃO USADO | Sem prova de sintaxe e precedência | Substituir o bloco marcado por import | DEFER até ler docs de memória | Mesmo teste acima, com import apontando para arquivo versionado |
| Auto memory | flag/recurso citado em `--bare` | PASS (help) | nenhum no repo; ai-memory é MCP externo e opcional | nenhum | NÃO USADO | Duplicaria o ai-memory e o estado do Orca | Nenhum a curto prazo | KEEP desligado | nenhum |
| Skills: descoberta e carga | `~/.claude/skills/<nome>/SKILL.md`; `/hybrid-orchestration` | PASS (skill listada na sessão; caminho pela doc) | `source/claude/skills/hybrid-orchestration/` (+ references), copiado pelo instalador | instalador; invocação pelo modelo não provada em headless | PARCIAL | Turno real com `claude -p` está em HOLD_NOT_VERIFIED | Descoberta sem código próprio | KEEP | Turno isolado com `claude -p --output-format json` invoca a skill (ver linha de `-p`) |
| Orçamento da listagem de skills | `skillListingBudgetFraction` (settings, valor 0.1) | HOLD (chave presente; doc não confirmada na parte lida) | nenhum | nenhum | NÃO USADO de forma consciente | Descrição truncada em 1.536 caracteres na listagem | Garantir que a skill entre na listagem | KEEP (não alterar valor do usuário) | Verificar que a descrição de `hybrid-orchestration` aparece completa na listagem |
| `disable-model-invocation` e `paths` | frontmatter da skill | HOLD (somente doc) | nenhum | nenhum | NÃO USADO | Sem teste | Evitar carga da skill em tarefas triviais | DEFER | A skill não dispara em pergunta simples; dispara em missão multi-etapa |
| Subagentes nativos | `claude agents`; `--agents <json>` | PASS (help) | workers OpenCode (`source/agents/*.md`, 19 workers) via `orca orchestration worker-start` | `scripts/v3` (Planner loop) e Orca | USADO, em outro runtime | Subagente nativo não substitui o worker OpenCode, por política do repo | Nenhum; criaria camada paralela | KEEP (OpenCode/Orca executa) | nenhum |
| Modelo do subagente | `CLAUDE_CODE_SUBAGENT_MODEL` em `env` (chave presente) | PASS (chave) + doc | `source/registry/model-routing-policy.json` (OpenCode) | nenhum para subagente Claude | NÃO SE APLICA | A variável afeta só subagentes nativos, não o roteamento OpenCode | Nenhum | KEEP | Confirmar que a variável não altera a escolha de modelo de worker |
| Hooks (17 eventos configurados) | `hooks` em settings: PreToolUse, PostToolUse, Stop, SubagentStop, SessionStart, UserPromptSubmit, PreCompact, PostCompact e outros | HOLD (chaves presentes; eventos confirmados na doc; disparo não provado) | hooks nativos do Orca (citados em `docs/HYBRID-ORCHESTRATION.md`); `scripts/v3/lib/OrchestrationBootstrapContext.ps1` (papel parecido com SessionStart) | Não confirmado; o instalador não toca hooks | PARCIAL (config do usuário, não do repo) | Valores não lidos por restrição; possível duplicação com Orca | Redução de lógica própria se houver lacuna | DEFER (auditoria dos 17 grupos com o dono) | Disparo real em sessão isolada e ordem de execução em relação ao Orca |
| Stop e SubagentStop como checklist de encerramento | evento `Stop` / `SubagentStop` | HOLD (doc confirma os eventos; sem disparo provado) | checklist manual em `source/claude/skills/hybrid-orchestration/SKILL.md` (seção CONCLUIR) | nenhum | NÃO USADO | Hook novo é proibido sem necessidade comprovada (AGENTS) | Lembrar `worker-release` e higiene | DEFER | Hook dispara só com worker não liberado; não bloqueia missão concluída |
| Sessões resumíveis | `claude --resume`, `--continue`, `--fork-session` | PASS (help) | retomada pelo Orca: `run-current`, `worker-list`, `inbox` (`source/claude/skills/hybrid-orchestration/references/resume.md`) | a skill instrui; não automatizado | USADO (Orca é autoridade) | Retomar sessão Claude não restaura estado de missão | Nenhum; duplicaria estado | KEEP (Orca) | Retomada de missão só pelo Orca, sem reiniciar Dispatch sem prova |
| Modo não interativo | `claude -p`, `--output-format json`, `--json-schema`, `--max-budget-usd`, `--bare` | PASS (help); execução de turno não feita (regra: sem chamada a modelo) | nenhum para Claude; `opencode run` para OpenCode | nenhum; `docs/HYBRID-ORCHESTRATION.md` registra HOLD_NOT_VERIFIED | NÃO USADO | Turno real exige credencial do perfil isolado, que não foi usada | Fecha o HOLD da skill e limita custo no teste | ADOPT (somente teste de paridade) | Turno isolado invoca a skill, retorna JSON e respeita `--max-budget-usd` |
| Isolamento de teste | `--bare` (pula hooks, LSP, auto-memory, keychain e CLAUDE.md) | PASS (help) | testes que usam `CLAUDE_CONFIG_DIR` temporário em `tests/distribution/claude-hybrid.tests.ps1` | testes | PARCIAL | Exige credencial explícita via settings ou API key | Teste sem ler o perfil real | ADOPT (somente teste) | Mesmo resultado do teste atual com `--bare` |
| Agent SDK | biblioteca (sem comando) | HOLD (somente doc) | nenhum | nenhum | NÃO USADO | Sem necessidade demonstrada | Nenhum agora | DEFER | n/a |
| Worktrees internos | `claude --worktree [nome]`, `--tmux` | PASS (help) | `scripts/v3/lib/OrchestrationWorktree.ps1` (`git worktree add`) e worktrees do Orca; flag `worktree_isolation` ativa | `scripts/v3` com flag ativa (caller exato não rastreado nesta leitura) | PARCIAL | Duplicaria o Orca e o kernel | Nenhum comprovado | DEFER (regra do usuário) | n/a |
| Agent Teams | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (não aparece no help) | HOLD (experimental; doc) | nenhum | nenhum | NÃO USADO | Experimental; subagente nomeado vira teammate; sem retomada de teammates in-process | Nenhum comprovado | DEFER (regra do usuário) | n/a |
| Hot reload de settings | reaplicação de `env` ao salvar (doc de agent-teams) | HOLD (somente doc) | nenhum | nenhum | NÃO USADO | Sem teste | Nenhum | DEFER | n/a |
| `/status` e `claude doctor` | `claude doctor`; `/status` (dentro da sessão) | PASS (doctor executado, sem problemas); HOLD (`/status` não executável daqui) | nenhum script próprio | nenhum | NÃO USADO em automação | Diagnóstico manual | Diagnóstico rápido do host | KEEP | nenhum |
| Monitor, agendamento e routines | ferramenta `Monitor`; skill `schedule` | PASS (listadas na sessão) | nenhum; o repo usa `worker_done` do Orca e proíbe polling | nenhum | NÃO USADO | Monitor é polling, vedado pelo CLAUDE.hybrid | Nenhum; conflita com a regra de não fazer polling | DEFER | n/a |
| Notificações | evento `Notification` (hooks) | HOLD (somente doc) | `worker_done`, `ask` e `escalation` do Orca | Orca | USADO (Orca) | Sem teste | Nenhum | KEEP (Orca) | n/a |
| Revisão em nuvem | `claude ultrareview [alvo] [--post]` | PASS (help) | reviewer e security-reviewer read-only do OpenCode, com policy em `source/registry/verification-policy.json` | Planner (`scripts/v3`) | USADO (OpenCode) | Custo em nuvem; `--post` publica no PR | Revisão independente adicional | DEFER | Comparar achados em um PR de amostra com o reviewer atual |
| Validação de plugin e skill | `claude plugin validate <caminho>`; `plugin test`; `plugin eval` | PASS (help) | validação de frontmatter em `tests/distribution/claude-hybrid.tests.ps1` | suíte de distribuição (`tests/distribution/run-distribution-tests.ps1`) | PARCIAL | Não confirmei se aceita skill solta fora de plugin; sem execução | Menos código próprio de validação | REPLACE (parcial, só frontmatter) | `plugin validate` dá o mesmo veredito que o teste atual para frontmatter válido e inválido |
| Permissões de CLI | `--permission-mode`, `--allowedTools`, `--disallowedTools`, `--settings` | PASS (help) | permissões dos workers em `source/agents/*.md` e `templates/opencode.v*.json.tmpl` | `scripts/` de geração e reconcile | USADO (OpenCode) | Não governa o coordenador Claude | Nenhum para o coordenador | KEEP | nenhum |
| `claude agents`, `--bg`, `attach`, `stop`, `logs`, `respawn` | comandos listados acima | NOT_AVAILABLE (bloqueados por `disableAgentView: true`) | Orca (`orca orchestration ...`) | Orca | NÃO USADO | Desligado no perfil do usuário | Nenhum; Orca cobre | KEEP (não alterar config) | nenhum |

### Cinco maiores oportunidades (com evidência)

1. **CLAUDE.md com import no lugar do bloco gerenciado (REPLACE).** `scripts/claude/install-claude-hybrid.ps1` tem 268 linhas para gerir um bloco marcado em `CLAUDE.md`, manifesto e backup. Se `@import` funcionar neste host, o instalador encolhe para copiar um arquivo. Pré-requisito: ler a documentação de memória e provar a sintaxe em perfil isolado.
2. **Validação do frontmatter da skill com `claude plugin validate` (REPLACE parcial).** `tests/distribution/claude-hybrid.tests.ps1` verifica `name` e `description` por código próprio. O comando existe no help. Pré-requisito: confirmar se aceita skill solta.
3. **Turno real isolado com `claude -p --output-format json --json-schema --max-budget-usd` (ADOPT só como teste).** Fecha o HOLD_NOT_VERIFIED de `docs/HYBRID-ORCHESTRATION.md` e prova a invocação da skill por modelo. Exige credencial do perfil isolado, que depende de autorização explícita do usuário.
4. **`--bare` para isolar os testes (ADOPT só como teste).** O help confirma que ele pula hooks, auto-memory, keychain e descoberta de CLAUDE.md. Isso permite testar o instalador sem ler o perfil real.
5. **Auditoria dos 17 grupos de hooks configurados (DEFER, com possível REMOVE).** Há hooks em `settings.json` que podem duplicar o Orca. Só o dono pode revisar os valores, porque não os li por restrição.

### Decisões de escopo

- Agent Teams e worktrees internos ficaram como DEFER, como pedido. Não há evidência forte que justifique adoção.
- Nenhum arquivo do repositório ou de `~/.claude` foi editado. O único arquivo escrito é este.
- Pendências: sintaxe de import (HOLD), `skillListingBudgetFraction` (HOLD) e disparo de hooks (HOLD).


## Orca 1.4.267

Somente leitura. Prova primária: `orca --help`, `--help` de subcomandos exatos, `orca status --json` (capabilities), `orca skills get orchestration --full`, `orca agent hooks status --json`. Docs oficiais (orca.dev) apenas como complemento.

Regra de disponibilidade (revalidada nesta rodada): PASS = `--help` do comando exato retorna exit 0. NOT_AVAILABLE = `--help` do comando exato retorna exit 1 (`Unknown command`) em todas as variantes testadas. HOLD = comando não encontrado, mas capability/UI existe, ou divergência docs x CLI. Teste de controle: `orca orchestration bogus-zz-no-such --help` retorna exit 1, então exit 0 não é falso positivo.

Runtime: `orca status --json` → app running, runtime `ready`, `appVersion 1.4.267`, 352 flags em `runtime.capabilities`.

Caminhos relativos a `<REPO_ROOT>\`.

Legenda de caller: "produção" = chamada fora de `*.tests.ps1` e fora do próprio arquivo.

| Capacidade | comando/API exato | prova no host | componente nosso equivalente (arquivo) | caller de produção | status de uso | limitação | ganho esperado | decisão sugerida | teste de paridade necessário |
|---|---|---|---|---|---|---|---|---|---|
| Run (criar, listar, mostrar, vincular) | `orchestration run-create/run-list/run-show/run-current/run-use` | PASS | `scripts/v3/lib/OrchestrationTaskKernel.ps1` (sem Run explícito) | não verificado como Run | NÃO USADO (Orca) | Run do Orca não tem semântica de DONE | estado compartilhado com Orca | DEFER | confirmar se o kernel precisa de Run; não substituir DONE |
| Task (criar, listar, atualizar) | `orchestration task-create/task-list/task-update` | PASS | `scripts/v3/lib/OrchestrationTaskKernel.ps1:1068` (`New-OrchestrationTask`); `:4776` (`Complete-OrchestrationTask`) | `scripts/v3/task-kernel.ps1:735`; `scripts/v3/github-wake-auto-dispatch.ps1` | PARCIAL (só instruções da skill) | `task-update` não emite DONE verificado | sobreposição de status | DEFER | DONE só via `Complete-OrchestrationTask` |
| Dispatch (despachar task) | `orchestration dispatch --task --to --inject`, `dispatch-show` | PASS | `scripts/v3/lib/OrchestrationNativeDispatch.ps1:3437` (`Invoke-OrchestrationNativeDispatch`) | `scripts/v3/github-wake.ps1`, `scripts/v3/objective-step.ps1`, `scripts/v3/native-dispatch-claim.ps1` | USADO (nosso); Orca NÃO USADO em código | modelo de despacho diferente | nenhum ganho óbvio | KEEP | — |
| Worker start (spawn supervisionado) | `orchestration worker-start --task/--spec --worktree --agent [--retry-of] [--on]` | PASS | `scripts/v3/lib/OrchestrationNativeDispatch.ps1`; `scripts/v3/lib/OrchestrationDispatchPipeline.ps1:528` | Pipeline: sem caller de produção (ver seção 4) | NÃO USADO em código (Orca só na skill) | `--spec` cria nova Task; `--retry-of` não herda placement | spawn gerenciado pelo Orca | DEFER | prova de início de turno antes de qualquer troca |
| Receipt e prova de início de turno | `worker-show --json`, `worker-read --limit 50 --json`, `terminal read` (procedimento da skill) | PASS (comandos existem) | nenhum equivalente direto | — | NÃO USADO em código | procedimento manual | verificação de início sem depender de `ready` | DEFER | — |
| Retry (`--retry-of`) e breaker de 3 falhas | `worker-start --retry-of <dispatch_id>` | PASS | nenhum equivalente direto | — | NÃO USADO | breaker só conta falhas de start | retry rastreado pelo Orca | DEFER | — |
| request-show (a mutação já foi aplicada?) | `orca orchestration request-show --request <id>` | PASS (exit 0, corrigido) | nenhum equivalente | — | NÃO USADO | somente leitura; `absent` não prova que nada ocorreu | verificar mutação após resposta perdida, sem reenviar | DEFER | cenário de resposta perdida com `--retry-request` |
| ask / reply | `orchestration ask --question --wait`, `reply --id` | PASS | `scripts/v3/lib/OrchestrationPlannerWait.ps1` (sem caller de produção) | nenhum | NÃO USADO em código | depende de wake do Orca | `ask-returns-at-once` evita bloqueio | DEFER | comparar latência com a espera nativa |
| Inbox / check / send (mail) | `orchestration send/check/inbox` | PASS | nenhum mail próprio; `github-wake*.ps1` é outro domínio | — | PARCIAL (skill) | `check` marca como lido | comunicação sem polling | DEFER | — |
| Wake (acordar coordenador) | mail do Orca | PASS (capability `orchestration.peer-mail`) | `scripts/v3/github-wake.ps1` (wake de GitHub) | sim | USADO (nosso) | não substitui wake de GitHub | — | KEEP | — |
| Decision gates | `orchestration gate-create/gate-resolve/gate-list` | PASS | `scripts/v3/lib/OrchestrationDecisionProvider.ps1` (ver seção 3) | nenhum de produção | NÃO USADO em produção | — | gates persistidos pelo Orca | DEFER | — |
| Heartbeat | `orchestration send --type heartbeat`; intervalo em Settings (1–60 min, padrão 5) | PASS (tipo existe no help de `send`) | watchdog `scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1` (NO_PROGRESS/HARD_TIMEOUT) | watchdog: só lib, E2E e CI | PARCIAL | heartbeat é do Dispatch; watchdog é por PID | sinal de progresso sem polling | DEFER | sinal de progresso vs NO_PROGRESS |
| worker-release | `orchestration worker-release --dispatch` | PASS | nenhum | — | NÃO USADO | só após worker settled | libera terminal sem `terminal close` | DEFER | estados `release_pending`/`release_unknown` |
| worker-keep-open | `orchestration worker-keep-open --dispatch` | PASS | nenhum | — | NÃO USADO | — | — | DEFER | — |
| worker-retain (nome antigo) | `orchestration worker-retain --dispatch` | PASS (exit 0, corrigido; help: "old name of worker-keep-open") | nenhum | — | NÃO USADO | alias legado; usar `worker-keep-open` | — | DEFER | não usar; preferir `worker-keep-open` |
| worker-stop / worker-abandon | `orchestration worker-stop/worker-abandon --dispatch` | PASS | `scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1` (kill por PID pinado, Job Object, P26) | watchdog: parcial | PARCIAL | Orca não prova exit; `stop_unknown` exige reconciliação | fencing de assignment | KEEP | não substituir o kill nativo sem prova de processo |
| worker-list (contabilidade) | `orchestration worker-list --run --terminal-state` | PASS | nenhum | — | NÃO USADO | accounting, não status de Task | visão de terminais órfãos | DEFER | — |
| Hibernação de agentes | `agent list` (estado "asleep": PASS); controle CLI: `worktree sleep`, `worktree hibernate`, `agent sleep`, `agent hibernate`, `agent wake` → exit 1; `settings` → exit 1 | HOLD (listagem PASS; controle por CLI não encontrado; capability `agent-session.workspace-sleep-mark.v1` existe; docs: hibernação pela UI em Settings → Experimental) | nenhum | — | NÃO USADO | sem comando CLI de controle | economia de recurso em workers ociosos | DEFER | — |
| Worktree create / rm | `worktree create --name --agent --no-parent`, `worktree rm --worktree` | PASS | `scripts/v3/lib/OrchestrationWorktree.ps1:352` (`New-OrchestrationWorktree`, `git worktree add` em :423); `:517` (`Remove-OrchestrationWorktree`) | `New-`: nenhum; `Remove-`: `scripts/v3/github-post-merge.ps1` | PARCIAL | nosso usa git puro | menos código próprio | DEFER | layout de path, branch e limpeza |
| Worktree current / ps | `worktree current`, `worktree ps` | PASS | nenhum | — | NÃO USADO | — | visão de workspaces | DEFER | — |
| Worktree checkpoint | testados: `worktree checkpoint`, `worktree checkpoints`, `checkpoint`, `checkpoints` → todos exit 1 | NOT_AVAILABLE (comandos testados; docs citam só a página "Worktree checkpoints") | — | — | — | nome exato do comando não confirmado | — | DEFER | — |
| Placement new-child / new-top-level | `worker-start --worktree new-child\|new-top-level` (listado no `--help` de `worker-start`); `worktree create --parent-worktree` | PASS (corrigido: new-top-level está no help do CLI) | `OrchestrationWorktree.ps1` (sem nesting) | — | NÃO USADO | `--on` exige `--repo` para ambos | — | DEFER | — |
| Notificações | testados: `notification`, `notifications`, `notify` → exit 1. Capabilities existem: `notifications.remote-push.v1`, `notifications.desktop-presence.v1`, `settings.host-notification-settings.v1` | HOLD (capability sem comando CLI verificado) | nenhum | — | — | controle só via UI/settings | — | DEFER | — |
| Hooks de agente | `orca agent hooks status` (leitura; on/off não executados) | PASS | `scripts/claude/install-claude-hybrid.ps1` (menções a Orca) | não verificado | PARCIAL | `status`: Claude e Codex instalados | — | KEEP | não ligar/desligar sem decisão |
| Automations / schedule | `automations list/show/runs` (create/edit/remove não executados) | PASS | nenhum equivalente de agendamento do Orca no repo | nenhum caller no repo | NÃO USADO | — | agendamento sem cron próprio | DEFER | — |
| Servidores pareados / SSH / environment | `environment list/show`, `host list` | PASS | nenhum | — | NÃO USADO | — | execução remota | DEFER | — |
| Usage analytics | testados: `usage`, `usage analytics`, `analytics` → exit 1. Capability `usage.analytics.v1` existe | HOLD (capability sem comando CLI) | nenhum | — | NÃO USADO | sem CLI verificável | custo por worker | DEFER | — |
| Diagnóstico | `vm env doctor`, `vm recipe doctor`, `diagnostics memory`, `status --json` | PASS | `scripts/v3/capability-healthcheck.ps1`, `scripts/v3/lib/OrchestrationCapabilityDoctor.ps1`, `scripts/v3/orchestration-preflight.ps1` | preflight: entrypoint | PARCIAL | doctor do Orca não cobre o DONE gate | manter nosso gate | KEEP | — |
| Browser automation | `tab create/list`, `snapshot`, `goto`, `click`, `screenshot` | PASS | nenhum no repo | — | NÃO USADO | — | — | DEFER | — |
| Computer use | `computer capabilities/list-apps/get-app-state/click` | PASS | nenhum no repo | — | NÃO USADO | exige permissão de SO | — | DEFER | — |

### Totais por decisão (30 linhas)

- KEEP: 5 (dispatch próprio, wake GitHub, worker-stop/abandon nativo, hooks só leitura, diagnóstico/preflight).
- ADOPT: 0. REPLACE: 0. REMOVE: 0.
- DEFER: 25.

Status de disponibilidade após revalidação: NOT_AVAILABLE só em checkpoint (comandos testados); HOLD em hibernação, notificações e usage analytics; os demais estão PASS ou são procedimento. Os 25 DEFER dependem de teste de paridade ainda não feito.

### 1. Mudanças em relação à versão anterior

- `request-show`: NOT_AVAILABLE → PASS (exit 0).
- `worker-retain`: HOLD → PASS como alias legado de `worker-keep-open` (exit 0).
- `new-top-level`: HOLD → PASS (aparece no `--help` de `worker-start`).
- Notificações: NOT_AVAILABLE → HOLD (capability existe, nenhum comando testado).
- Hibernação: NOT_AVAILABLE/PASS → HOLD (listagem PASS, controle CLI não encontrado nos 5 nomes testados e em `settings`).
- Checkpoint: continua NOT_AVAILABLE, agora com exit codes registrados.
- Usage analytics: continua HOLD, agora com exit codes registrados.

### 2. Exit codes dos `--help` exatos

| Comando | exit | Observação |
|---|---|---|
| `orca orchestration request-show --help` | 0 | PASS |
| `orca orchestration worker-retain --help` | 0 | PASS (alias legado) |
| `orca orchestration worker-keep-open --help` | 0 | PASS |
| `orca orchestration bogus-zz-no-such --help` | 1 | controle negativo |
| `orca worktree checkpoint --help`; `worktree checkpoints`; `checkpoint`; `checkpoints` | 1 | Unknown command |
| `orca notification --help`; `notifications`; `notify` | 1 | Unknown command |
| `orca worktree sleep`; `worktree hibernate`; `agent sleep`; `agent hibernate`; `agent wake` | 1 | Unknown command |
| `orca usage --help`; `usage analytics`; `analytics` | 1 | Unknown command |
| `orca settings --help` | 1 | Unknown command |

### 3. Callers de produção pendentes

- `scripts/v3/lib/OrchestrationPlannerWait.ps1` (função `Invoke-OrchestrationPlannerWaitBinding`, linha 206): sem caller de produção. O único arquivo que o carrega é `scripts/v3/lib/OrchestrationPlannerWaitBridge.ps1:127`, que também não tem caller de produção. Fora disso, só testes (`OrchestrationPlannerWait.tests.ps1`, `scripts/v3/github-wake-86-settlement.tests.ps1:252`).
- `scripts/v3/lib/OrchestrationDecisionProvider.ps1`: carregado por `OrchestrationDecisionWiring.ps1:51` (lista de libs). `Invoke-OrchestrationDecisionWiring` (`OrchestrationDecisionWiring.ps1:238`) não tem caller de produção; testes: `OrchestrationDecisionWiring.tests.ps1:25`, `OrchestrationCorrectiveE2E.tests.ps1:63`, `OrchestrationGoldenWorkflows.tests.ps1:16`. Conclusão: sem caller de produção.
- Automações do Orca (`orca automations`): nenhuma ocorrência em scripts, source, templates ou docs do repo, fora do help. Sem caller.
- `scripts/v3/github-watch.ps1`: entrypoint standalone com uso manual documentado (linhas 19 e 25). Sem chamador interno em código; citado em `docs/plans/AUTONOMY-FULL-DELIVERY-vNEXT.md:494` e `docs/plans/NATIVE-FIRST-IMPLEMENTATION-2026-10-21.md:73`. É de produção só como ferramenta manual; não é wrapper de Orca.

### 4. Verificação de `Invoke-OrchestrationDispatchPipeline` (`OrchestrationDispatchPipeline.ps1:528`)

Busca em todo o repositório (excluindo `node_modules`, `.git`, `evidence`), incluindo `source/`, `templates/`, plugins e docs:

- Definição: `scripts/v3/lib/OrchestrationDispatchPipeline.ps1:528`.
- Uso fora de testes: nenhum. Só `OrchestrationDispatchPipeline.tests.ps1` e `OrchestrationObjectiveController.tests.ps1:113`.
- `source/`, `templates/`, plugins: nenhuma ocorrência.
- Confirmação em docs: `docs/plans/AUTONOMY-FULL-DELIVERY-vNEXT.md:48` diz "nenhum caller produtivo".

Contradição encontrada: `docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-WIRING-MATRIX.md:17` marca o componente como "ACTIVE record-only", e `CHANGELOG.md:2334` e `docs/ARCHITECTURE.md:373` o tratam como ativo. Pelo código, ele não é chamado em produção. A afirmação de "sem caller" se sustenta; o rótulo ACTIVE na matriz está errado.

### 5. Maiores duplicações (evidência)

1. Dispatch dois caminhos, um sem uso: `scripts/v3/lib/OrchestrationDispatchPipeline.ps1:528` sem caller de produção; caminho ativo `scripts/v3/lib/OrchestrationNativeDispatch.ps1:3437`. Candidato a REMOVE, após decisão sobre a matriz de wiring.
2. Worktree: `scripts/v3/lib/OrchestrationWorktree.ps1:352` (`New-OrchestrationWorktree`, `git worktree add` na :423) sem caller de produção; `Remove-` (:517) usado por `scripts/v3/github-post-merge.ps1`.
3. Estado de Task: `scripts/v3/lib/OrchestrationTaskKernel.ps1:1068` sobrepõe `task-create/task-update`; sobreposição parcial, o kernel deve manter DONE.
4. Progresso e timeout: `scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1` (NO_PROGRESS, HARD_TIMEOUT) sobrepõe `worker-list`, `worker-show` e heartbeat; caller só em lib, E2E e CI.
5. Espera ao coordenador: `scripts/v3/lib/OrchestrationPlannerWait.ps1:206` sobrepõe `orchestration ask --wait`; sem caller de produção, portanto a duplicação é de código morto, não de uso concorrente.

### 6. Limitações

- Nenhum comando que altere estado foi executado (sem worker-start, run-create, send, reply, worktree create/rm, terminal send/close, automations create, hooks on/off, reset, stop, release).
- Hibernação e notificações: se o runtime expuser controle por algum outro nome que não testei, a marcação HOLD pode mudar; não consultei `orca --help` completo além da lista de grupos.
- Checkpoint: testei 4 nomes; o nome exato de um comando de checkpoint pode existir sob outro grupo que não listei.


## OpenCode 2.3.2

Data: 2026-11-21. Repositório: `<REPO_ROOT>` (branch master, sem alterações).

### 1. Escopo e método

- **Binário instalado:** `opencode v2.3.2` (confirmado por `opencode --version`).
- **Pin do repositório:** `2.3.0` em `source/registry/runtime-versions.json` (`runtimes.v2.version`). Não foi alterado.
- **Prova no host (PASS):** a flag ou subcomando aparece no `--help` do binário instalado (executado com `--help`). `opencode debug paths` foi executado (leitura).
- **HOLD:** a capacidade está documentada (changelog ou docs oficiais), mas não é comprovável pelo `--help` e exige execução de modelo ou sessão real. Não foi executado nada que chame modelo.
- **NOT_AVAILABLE:** não aparece no `--help` do binário nem nas docs consultadas.
- **Não executado (restrição):** `opencode run`, TUI, `serve`, `upgrade`, `import`, `session delete`, `worktree create/remove`, `mcp add/auth`, `auth list/export`, `debug agents/config` (podem tocar estado ou credenciais). Nenhum `auth.json` foi lido.
- **Caller de produção:** chamada fora de testes (`*tests*`), a partir de `scripts/`, `plugins/`, `templates/`, `source/`, `install.ps1` ou `uninstall.ps1`. Chamada apenas em CI (`scripts/ci/`) ou em script de prova/pilot não conta como produção.
- **Subagentes:** o binário não expõe `task` no CLI. A ferramenta documentada é `subagent`.

### 2. Diferenças relevantes 2.3.0 (pin) x 2.3.2 (instalado)

| Versão | Mudança relevante | Impacto no repositório |
|---|---|---|
| 2.3.0 | Subagentes rodam em background por padrão; relatório de subagente ocioso; flag experimental `shell_timeout_background`; shell sobrevive a handoffs; hook `session.fork`; evento `experimental.mcp.event` (flag `mcp_events`); `write`/`edit` retornam string; `skill` retorna diretório e conteúdo; `execute.before` pode rejeitar com `Tool.Error` | Muda o modelo de espera de subagente. O mandate do plugin assume dispatch por `subagent` sem regra de background. Verificar. |
| 2.3.1 | Timeout de shell passa para background; `timeout: 0` = 120 s; correção de PTY zumbi; `schedules` virou `automations` (`/automation`, `automation_*`; schedules com condição são descartados na migração); fallback para `CLAUDE.md` quando não há `AGENTS.md`; `OPENCODE_DISABLE_CLAUDE_CODE`; env `OPENCODE_SESSION_ID`; `compaction.background`; erro HTTP 500 com `UnknownError` | Risco de instrução duplicada se o `CLAUDE.md` global for lido junto com `AGENTS.md`. `OPENCODE_SESSION_ID` é candidato a substituir `planner-session-binding` (a verificar). |
| 2.3.2 | System prompt do GPT-6.2 enviado como mensagem `developer` (cache a partir da 2.ª etapa); correção de saída estruturada do `webfetch` | Sem impacto de contrato conhecido. Melhora custo com GPT-6.2. |

Observações:
- A página 2.3.0 não cobre worktree, `session.execution`, PTY, permissões, config reload, stats, cache nem logs. Esses itens foram conferidos apenas em docs e `--help`.
- O registry `source/registry/v2-native-capabilities.json` declara que as 8 features V2 nativas estão `hold-unproven` e que nenhuma tem prova `exact-binary-live` para 2.3.0. Isso vale também para 2.3.2.
- A 2.3.2 não tem smoke de lifecycle registrado. Se o pin for movido, o smoke precisa ser refeito no binário exato.

### 3. Inventário (41 capacidades)

Legenda de status: USADO (caller de produção), PARCIAL (caller só em CI, pilot, script de prova ou sem caller verificado), NÃO USADO (sem caller de produção).

| # | Capacidade | comando/API exato | prova no host | componente nosso equivalente (arquivo) | caller de produção | status de uso | limitação | ganho esperado | decisão sugerida | teste de paridade necessário |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Serviço compartilhado | `opencode service start/restart/status/stop/get/set/unset` | PASS | nenhum direto | nenhum | NÃO USADO | Não executado; estado do serviço não verificado | Liveness central de sessões | DEFER | Sessão sobrevive a restart do serviço; dois clientes na mesma sessão |
| 2 | Modo privado | `opencode --standalone` | PASS | `scripts/runtime/lib/SpikeProcess.ps1`, `scripts/runtime/lib/RuntimePortPreflight.ps1` | `scripts/ci/*-v2*.ps1` e `scripts/runtime/New-OrchestrationProfile.ps1` | PARCIAL | Só CI e instalação de perfil | Isolamento de lane sem serviço compartilhado | KEEP | Smoke lifecycle no binário exato |
| 3 | API/web local | `opencode serve --hostname --port --cors --service --stdio` | PASS | nenhum | nenhum | NÃO USADO | Não executado; porta e exposição não testadas | Nenhum para o fluxo atual | DEFER | Não aplicável sem caso de uso |
| 4 | Worktree por run | `opencode run -w [nome]` / `--worktree` | PASS | `scripts/v3/lib/OrchestrationWorktree.ps1` | `scripts/v3/github-post-merge.ps1:11,168,176` (sem caller de produção) | PARCIAL | Worktree nativo sem prova de criação e limpeza; `worktree_isolation` ON no registry | Remove wrapper próprio de git worktree | DEFER | Criar e limpar worktree com branch; limpeza segura sem `--force`; comparar caminho e nome |
| 5 | Worktree API | `GET/POST/DELETE /api/worktree`, `POST /api/worktree/refresh`; eventos `worktree.updated`, `worktree.resolved` | HOLD (docs) | `OrchestrationWorktree.ps1` | idem #4 | PARCIAL | Só docs; API não executada | Gestão por API sem git direto | DEFER | Idem #4 via API |
| 6 | Fork de sessão | `opencode run --fork`; `POST /api/session/{id}/fork`; hook `session.fork` | PASS (flag); HOLD (API e hook) | `plugins/orchestration-enforcement/shared/identity.ts:59` (parentID) | plugin (identidade de worker) | PARCIAL | Fork não usado no fluxo | Retomada a partir de estado anterior | DEFER | Fork preserva contexto e não duplica execução |
| 7 | Listagem de sessões | `opencode session list -n N --format json` | PASS | `scripts/runtime/SessionBootstrapContext.ps1`; `scripts/v3/planner-session-binding.ps1` | nenhum (sem caller verificado) | NÃO USADO | Lista é do projeto atual; sem filtro de arquivadas no `--help` | Descoberta de sessão sem código próprio | DEFER | Mesmo conjunto de IDs que o bootstrap atual |
| 8 | Export com sanitização | `opencode session export [id] --sanitize` | PASS | `scripts/v3/lib/CapabilitySanitize.ps1` | sem caller de produção verificado | PARCIAL | Redação nativa não comprovada nos campos do repositório | Remove sanitizador próprio | DEFER | Canários sintéticos (`sk-SYNTHETICSECRET`) não aparecem na saída |
| 9 | Import de sessão | `opencode session import <arquivo\|URL> --directory` | PASS | nenhum | nenhum | NÃO USADO | Não executado (escrita) | Nenhum atual | DEFER | Não aplicável sem caso de uso |
| 10 | Delete de sessão | `opencode session delete <id>` | PASS | nenhum | nenhum | NÃO USADO | Destrutivo; exige confirmação | Nenhum atual | DEFER | Não executar sem autorização |
| 11 | Sessão arquivada na CI | `opencode run --archived` | PASS | nenhum | nenhum | NÃO USADO | Sem filtro de arquivadas em `session list` no `--help` | Runs de CI fora da lista | ADOPT | Lane CI não polui lista; sessão continua acessível por ID |
| 12 | Subagentes e allowlist | ferramenta `subagent`; permissão `action: subagent`; `experimental.subagent_depth: 1` | HOLD (ferramenta e depth só em docs e template) | `source/agents/*.md` (19 workers); `templates/opencode.v2.json.tmpl:5,8-27` | plugin (mandate) e templates gerados | USADO | `subagent_depth` não consta nas docs consultadas | Allowlist nativa deny-by-default | KEEP | `subagent_depth=1` efetivo; deny-by-default no binário 2.3.2 |
| 13 | Subagentes em background e relatório ocioso | comportamento 2.3.0; `<subagent>` ao ficar ocioso | HOLD | `scripts/v3/github-wake.ps1`; `scripts/v3/prove-native-subagents.ps1` (sem caller de produção) | nenhum | PARCIAL | Mudou em 2.3.0; mandate não trata background | Menos espera ativa | DEFER | Pai recebe relatório; sem duplicar dispatch; kernel continua dono da reconciliação |
| 14 | Eventos de execução | `session.execution.started/succeeded/failed/interrupted` | HOLD (docs) | `scripts/v3/task-kernel.ps1` (estado próprio) | nenhum consumidor (grep em `scripts/` e `plugins/` sem resultado) | NÃO USADO | Sem consumo; não capturado no 2.3.2 | Liveness sem polling | DEFER | Capturar sequência real de eventos no 2.3.2 |
| 15 | Progresso de tool | `session.tool.progress` | HOLD (docs) | `OrchestrationRuntimeWatchdog.ps1` (NO_PROGRESS) | nenhum | NÃO USADO | Sem consumo | Detecção de travamento sem heurística própria | DEFER | Evento presente em tool longa |
| 16 | Espera de sessão | `POST /api/experimental/session/{id}/wait`; `session.idle` | HOLD (docs) | `scripts/v3/github-watch.ps1:98` (instrução `block external_dependency`) | nenhum | PARCIAL | Rota experimental | Espera sem polling | DEFER | Espera retorna ao ficar ociosa; sem corrida com `worker_done` |
| 17 | Shell em background e timeout | `shell` com `background`, `timeout`; flag `shell_timeout_background` (experimental) | HOLD (docs) | `scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1` | somente `scripts/ci/watchdog-real-lane-v2.ps1:1541` (CI). Flag `watchdog` ON em `source/registry/capability-flags.json` | NÃO USADO em produção | Flag ON sem caller de produção; o watchdog não está no bundle `plugins/dist/orchestration-enforcement.js` | Kill nativo de processo | DEFER | Watchdog com identidade pid+creation-ticks versus timeout nativo; sem kill de PID desconhecido |
| 18 | PTY | `GET/POST /api/pty`, `GET/PUT/DELETE /api/pty/{id}`, `GET /api/pty/{id}/connect` (WebSocket); eventos `pty.*` | HOLD (docs) | `scripts/runtime/lib/SpikeProcess.ps1`; `scripts/runtime/lib/RuntimeJobObject.ps1` | CI (SpikeProcess) | PARCIAL | Prova PTY Windows pendente (#191); sem `pty` no CLI | Terminal persistente nativo | DEFER | Prova PTY Windows real (#191) |
| 19 | Automações | `automations` (flag); `/automation`; ferramentas `automation_*`; gatilhos cron, intervalo, evento MCP | HOLD (changelog 2.3.1; não aparece no `--help`) | `scripts/v3/github-wake-controller.ps1:104`; `scripts/v3/github-wake-auto-dispatch.ps1:158`; `evidence/v3/etapa6d-live/tick-scheduled-task.xml` | nenhum de produção (scripts de prova e tarefa agendada de evidência) | PARCIAL | Migração descarta schedules com condição; flag ainda não verificada | Substitui agendador próprio | DEFER | Mesma cadência e mesmo resultado de wake; migração de schedules |
| 20 | Goal | `/goal` | NOT_AVAILABLE (não está no `--help` nem nas docs consultadas) | `scripts/v3/lib/OrchestrationGoalKernel.ps1` | `scripts/v3/full-delivery-pilot-driver.ps1` (pilot) | PARCIAL | Sem equivalente nativo | Nenhum nativo disponível | KEEP | Não aplicável |
| 21 | Skills | ferramenta `skill` (retorna diretório e conteúdo, 2.3.0) | HOLD (docs) | `scripts/v3/skill-bridge.ps1`; `source/registry/skills-catalog.json` | `install.ps1:1178` (distribuição); `scripts/v3/measure-skills-discovery-cost.ps1:96` (medição) | PARCIAL | Roteamento de skill desligado (`skill_routing` OFF) | Carregamento nativo sem código próprio | DEFER | Mesma skill carregada pelo gatilho; catálogo íntegro |
| 22 | MCP (configuração) | `opencode mcp list`; `mcp add`; `mcp auth`; `mcp logout` | PASS | `source/registry/capabilities-v2.json`; `scripts/ci/agent-mcp-integration-lane-v2.ps1` | CI | PARCIAL | `add` e `auth` não executados | Gestão de servidores MCP | KEEP | Lista de servidores igual à config do repositório |
| 23 | Eventos MCP | `experimental.mcp.event`; flag `mcp_events`; eventos `mcp.status.changed`, `mcp.resources.changed` | HOLD (docs) | nenhum (`mcp_routing` OFF) | nenhum | NÃO USADO | Experimental | Estado de MCP em tempo real | DEFER | Evento recebido com servidor MCP real |
| 24 | Permissões | `opencode run --auto`; eventos `permission.asked`, `permission.replied` | PASS (`--auto`); HOLD (eventos) | `plugins/orchestration-enforcement/v2.ts`; `plugins/orchestration-enforcement/shared/mandate.ts`; `scripts/runtime/spike-v2-permissions.ps1` | plugin (produção) | USADO | `--auto` aprova o que não é `deny`; o repositório não pode depender disso | Fluxo de permissão nativo | KEEP | `deny` vence sob `--auto` no 2.3.2 |
| 25 | Config reload | `opencode reload`; `POST /api/location/reload`; evento `config.updated` | PASS (CLI); HOLD (API) | nenhum (reconcile é outro fluxo) | nenhum | NÃO USADO | Não executado | Recarga sem reiniciar | DEFER | Mudança de config refletida sem reinício |
| 26 | Diagnóstico de caminhos e config | `opencode debug paths`; `debug config`; `debug agents` | PASS (`debug paths` executado; demais só `--help`) | `scripts/runtime/detect-opencode-runtime.ps1` | não verificado | NÃO VERIFICADO | `debug agents`/`config` não executados | Diagnóstico nativo | KEEP | Caminhos do `debug paths` iguais aos usados pelo repositório |
| 27 | Stats e uso | `opencode stats --days --models --tools --cost --json` | PASS | `scripts/v3/cache-metrics.ps1`; `scripts/v3/measure-efficiency-baseline.ps1` | nenhum de produção | NÃO USADO | Agregado local, sem custo por worker | Métrica de custo sem código próprio | REPLACE | Totais de tokens e custo por sessão batem com a medição própria |
| 28 | Cache | sem comando CLI; diretório `~/.cache/opencode` (de `debug paths`); cache do prompt GPT-6.2 (2.3.2) | HOLD | `scripts/v3/cache-metrics.ps1` | nenhum | NÃO USADO | Sem comando de cache no CLI | Medição de cache do provedor | DEFER | Hit de cache medido em sessão real |
| 29 | Logs | `opencode --log-level <nível>`; `--print-logs` | PASS | `scripts/v3/lib/OrchestrationEvolutionTelemetryProducer.ps1`; `scripts/v3/lib/CapabilityAdvisoryCollector.ps1` | lib (telemetria) | PARCIAL | Logs nativos são complemento, não substituem a telemetria própria | Diagnóstico de servidor | KEEP | Telemetria própria continua gravando sem perda |
| 30 | Heap dump | `opencode debug heap-dump --directory` | PASS (`--help`) | nenhum | nenhum | NÃO USADO | Não executado | Diagnóstico de memória | DEFER | Sem necessidade comprovada |
| 31 | Pareamento remoto | `opencode pair --url --remote --yes` | PASS | nenhum | nenhum | NÃO USADO | `--remote` expõe o servidor à internet | Nenhum atual | DEFER | Não aplicável |
| 32 | API HTTP | `opencode api <operação\|MÉTODO caminho>`; `/api/session`, `/api/session/{id}/prompt`, `/api/session/active`, `/api/session/{id}/interrupt`, `/api/config` | PASS (`--help`); HOLD (rotas) | nenhum | nenhum | NÃO USADO | Rotas só em docs; não executadas | Automação via API | DEFER | Não aplicável sem caso de uso |
| 33 | ACP | `opencode acp [--login]` | PASS | nenhum | nenhum | NÃO USADO | Não executado | Integração com clientes ACP | DEFER | Não aplicável |
| 34 | Interface mínima | `opencode mini` | PASS | nenhum | nenhum | NÃO USADO | Não executado | Nenhum atual | DEFER | Não aplicável |
| 35 | Plugins | `opencode plugin list/add/check/update/remove` | PASS | `install.ps1` (instala `plugins/dist/orchestration-enforcement.js` e sidecar `.sha256`) | `install.ps1` | USADO | Bundle não é pacote npm | Gestão de plugin nativa | KEEP | Plugin carregado pelo caminho de instalação atual |
| 36 | Modelos | `opencode models` | PASS | `scripts/v3/model-fallback.ps1`; `source/registry/model-routing-policy.json` | mandate do plugin (fallback) | PARCIAL | Lista não executada | Lista de modelos nativa | KEEP | Modelos da policy existem na lista do binário |
| 37 | Auth | `opencode auth list/login/logout/export/import/switch` | PASS (`--help`) | nenhum (credenciais são do usuário) | nenhum | NÃO USADO | `export` imprime segredos; não usar no repositório | Nenhum | KEEP | Não aplicável; nunca ler `auth.json` |
| 38 | Instalação e remoção | `opencode upgrade/update`; `opencode uninstall` | PASS | `install.ps1`; `uninstall.ps1` (próprios) | nosso instalador | USADO | Não executado | Nenhum | KEEP | Não aplicável |
| 39 | Id da sessão no ambiente | env `OPENCODE_SESSION_ID` (2.3.1) | HOLD (changelog) | `scripts/v3/planner-session-binding.ps1` | nenhum | NÃO USADO | Só em changelog | Remove leitura de sessão por CLI | ADOPT | Id igual ao da sessão ativa no shell |
| 40 | Compactação em background | `compaction.background` (padrão ativo, 2.3.1) | HOLD (changelog) | nenhum | nenhum | NÃO USADO | Só changelog | Compactação fora do caminho crítico | KEEP | Não aplicável (nativo, sem conflito) |
| 41 | TLS para gateway | `settings.tls` (`cert`, `key`, `passphrase`) | HOLD (changelog 2.3.0) | nenhum | nenhum | NÃO USADO | Só changelog | mTLS para gateway | DEFER | Não aplicável sem gateway |

Contagem por decisão: **KEEP 12** (#2, #12, #20, #22, #24, #26, #29, #35, #36, #37, #38, #40); **ADOPT 2** (#11, #39); **REPLACE 1** (#27); **DEFER 26** (#1, #3, #4, #5, #6, #7, #8, #9, #10, #13, #14, #15, #16, #17, #18, #19, #21, #23, #25, #28, #30, #31, #32, #33, #34, #41); **REMOVE 0**. Total 41.

### 4. Cinco maiores duplicações (com evidência)

1. **Worktree próprio x worktree nativo.** `scripts/v3/lib/OrchestrationWorktree.ps1` reimplementa criação e remoção de worktree git. O nativo está em `opencode run -w` e em `/api/worktree`. Único consumidor: `scripts/v3/github-post-merge.ps1:11` (dot-source), `:168` (`Get-OrchestrationWorktreePath`) e `:176` (`Remove-OrchestrationWorktree`). Esse script não tem caller de produção. `worktree_isolation` está ON em `source/registry/capability-flags.json`.
2. **Watchdog próprio x timeout nativo de shell.** `scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1` faz HARD_TIMEOUT e NO_PROGRESS. O nativo faz timeout para background (2.3.1) e `shell_timeout_background` (2.3.0). O watchdog só é carregado em `scripts/ci/watchdog-real-lane-v2.ps1:1541`. A flag `watchdog` está ON, mas o bundle `plugins/dist/orchestration-enforcement.js` não o contém. Divergência a tratar antes de qualquer decisão de remoção.
3. **Agendador próprio x `automations` nativo.** `scripts/v3/github-wake-controller.ps1:104` e `scripts/v3/github-wake-auto-dispatch.ps1:158` fazem wake periódico. A tarefa agendada em `evidence/v3/etapa6d-live/tick-scheduled-task.xml` roda o mesmo papel. O nativo substitui cron e intervalo a partir da 2.3.1 (`automations`). Hoje é prova, não produção.
4. **Provenance de sessão própria x parentID e listagem nativa.** `plugins/orchestration-enforcement/shared/identity.ts:59` identifica worker por `parentID`, o que é nativo e está em uso (bundle `plugins/dist/orchestration-enforcement.js:102-103,195-205,984`). Mas `scripts/runtime/SessionBootstrapContext.ps1:217` e `scripts/v3/planner-session-binding.ps1:33` reimplementam descoberta de sessão, sem caller de produção. O nativo tem `session list`, `session export` e `OPENCODE_SESSION_ID`.
5. **Skills: roteador próprio x ferramenta `skill` nativa.** `scripts/v3/skill-bridge.ps1:14` roteia skills com catálogo próprio (`source/registry/skills-catalog.json`). A ferramenta `skill` nativa carrega o diretório e o conteúdo (2.3.0). O roteamento próprio está desligado (`skill_routing` OFF), mas `install.ps1:1178` distribui o script.

### 5. Divergências e pendências

- **Pin desatualizado:** o repositório fixa 2.3.0; o binário é 2.3.2. Não alterado. Qualquer bump exige smoke de lifecycle no binário exato, como já prevê o registry.
- **Texto do mandate com nome de ferramenta errado:** `plugins/orchestration-enforcement/shared/mandate.ts:45` diz "the task tool is unavailable/denied". No V2 a ferramenta é `subagent` (`templates/opencode.v2.json.tmpl:8-27`). O nome `task` só existe no template V1 (`templates/opencode.v1.json.tmpl:10`). O texto precisa de variante por runtime.
- **Subagente em background (2.3.0):** o mandate e o kernel não tratam o relatório `<subagent>` nem a execução em background. Precisa de verificação no 2.3.2.
- **CLAUDE.md fallback (2.3.1):** se o `AGENTS.md` do projeto faltar, o nativo lê `~/.claude/CLAUDE.md`. Risco de instruções duplicadas. Verificar a precedência no binário.
- **Watchdog com flag ON e sem caller de produção:** `capability-flags.json` marca `watchdog` ativo, mas o caminho de produção não o chama.
- **Nenhum item V2 nativo tem prova exact-binary** para 2.3.0 ou 2.3.2 (`source/registry/v2-native-capabilities.json`). Não há base para ativar features nativas sem nova coleta.
- **Não verificado:** `debug agents`, `debug config`, `models`, `mcp list` (somente `--help`, por restrição). O que depende deles fica como HOLD.
