# Plano: ownership do instalador e reinstalação limpa

**Data:** 2026-11-12  
**Repositórios:** `Kusts/opencode-orchestration` e `kust-projetos/agent-config`  
**Prioridade:** Alta  
**Runtime alvo:** OpenCode V2

## 1. Objetivo e problema comprovado

Transferir o ownership dos perfis/runtime de execução para a Orquestração e permitir uma reinstalação limpa, transacional, segura e idempotente. O estado anterior deixava perfis live stale: `~/.config/opencode/agents/*.md` vinham do Agent Config e os 19 perfis divergiam da fonte canônica da Orquestração; com `agent-config:global` presente, o instalador anterior não aplicava os perfis (`install.ps1:1750-1752` no comportamento histórico). O manifest anterior atribuía `global_text`, `worker_profiles`, `build_permissions` e `top_level_permissions` ao Agent Config (`install.ps1:2356-2366`).

As regras de detecção, merge, plano por recurso e preservação são visíveis em `install.ps1:1400-1428`, `install.ps1:1595-1625`, `install.ps1:1733-1758` e `uninstall.ps1:262-302`. O changelog registrava a condição de reconciliação do config ativo como pendente (CHANGELOG.md, à época); a migração real foi executada e convergida em 2026-11-12 (ver §10). A suíte de ownership cobre T1-T28 (`scripts/v3/install-ownership.tests.ps1`).

## 2. Contrato normativo de ownership v2

| Recurso | Writer único | Limite do outro owner |
|---|---|---|
| `AGENTS.md` texto global (`agent-config:global`) | Agent Config | Orquestração nunca escreve; apenas retira seu próprio bloco/banner legado. |
| `~/.config/opencode/agents/*.md` (19 perfis) | Orquestração | Agent Config nunca aplica; namespace delegado. |
| `opencode.json` objeto `agents` (build, title, 19 subagentes: mode/model/permissions) | Orquestração | Agent Config não escreve esse objeto. |
| `opencode.json` `permissions` top-level, `mcp`, `skills`, chave `plugin` | Agent Config / usuário, conforme registry | Orquestração preserva. |
| `plugins/orchestration-enforcement.js` e as 8 skills-core | Orquestração | Agent Config preserva. |
| Skills centrais, MCP, Claude/Codex/Pi/Antigravity, launchers | Agent Config | Orquestração não aplica. |
| Modelos/delegação (`agents.*.model`), Planner/Router/Task Kernel/estado de tarefa | Orquestração | Agent Config publica capacidades; não escolhe execução por tarefa. |
| Credenciais e `models.jsonc` do usuário | Usuário | Ambos preservam. |
| Manifest `.opencode-orchestration/manifest.json` | Orquestração | Agent Config não escreve. |

Esta matriz é o contrato alvo da missão e foi alinhada em 2026-11-12 com o repo Agent Config: o ADR-INTEROP-001 recebeu a Revisão 2 (ATIVO parcial; os 19 perfis e o bloco `agents` atribuídos à Orquestração) e a SPEC de interop teve P1, Estado e §4.1 revisados. Bundle `agent-profile-bundle/v1`, quality gate e migração dos sete módulos permanecem proposta.

## 3. Marcos de execução M1-M7

| Marco | Status | Objetivo | Arquivos/áreas | Critério de aceite | Dependências |
|---|---|---|---|---|---|
| M1 | DONE | Agent Config delega perfis à Orquestração e consome sua fonte canônica: guard em `reconcile-agents`, manifesto de ownership e importador com lock/commit; não inventar perfis se a Orquestração não existir. Atualizar ADR/SPEC. | Repo Agent Config: reconciliador, manifesto/importador, docs ADR/SPEC. | Writer único demonstrado; ausência da fonte da Orquestração resulta em skip/degradação explícita, não em perfis fabricados; atualização protegida por lock/commit. | Aprovação/alinhamento dos owners; definição do formato de consumo. |
| M2 | DONE | Orquestração escreve perfis e bloco `agents` mesmo com `agent-config:global` presente, sem tocar o texto global. | Repo Orquestração: `install.ps1`, manifest, testes relevantes. | Fixture com marcador global intacto recebe 19 perfis e `agents` conforme contrato; uninstall/ownership não reivindica texto global. | M1 ou contrato de handoff acordado. |
| M3 | DONE | Adicionar `-Clean` transacional e seguro. | `install.ps1`, testes de instalação/manifest. | Backup, hash de manifest, remoção somente do obsoleto provado, reinstalação, validação, manifest por último, rollback; `-WhatIf` sem escrita; preservar MCP, ai-memory, plugins e skills externos. | M2; limites de ownership aprovados. |
| M4 | DONE | Relatório de resultado e validação pós-instalação; validação funcional separada (não opt-in embutido no instalador). | `install.ps1` e testes/documentação de contrato. | Estados definidos na seção 6; valida plugin, Planner, 19 perfis, modelos/delegação, skills essenciais e config V2. `functional_delegation=NOT_RUN`; prova real separada via `scripts\v3\prove-native-subagents.ps1` (não alegar PASS sem provider). | M2/M3; probes locais definidos. |
| M5 | DONE | Testes de integração em TEMP para os 10 cenários abaixo e suite de distribution. | Harnesses de teste de instalação/distribution. | Todos os cenários aplicáveis passam, com fixtures isoladas e sem tocar ambiente real. | M1-M4 implementados. |
| M6 | DONE | Reinstalar o ambiente real e re-sincronizar Agent Config sem reversão de ownership. | Estado ativo OpenCode V2 e Agent Config. | Verificação pré/pós, backup/rollback disponível, perfis e configuração convergentes, sem dano a recursos de terceiros (critério satisfeito em 2026-11-12; evidência em `evidence/install-ownership-2026-11-12/`). | M1-M5 aprovados; autorização operacional para ambiente nomeado. |
| M7 | DONE | Documentar resultado e evidência. | Docs/specs, changelog/evidence conforme convenção dos repos. | Evidência distingue fixture, validação estática e execução real; conclusão e limitações registradas. | M1-M6 concluídos. |

## 4. `-Clean`: contrato detalhado

**Entradas:** parâmetros normais de instalação (incluindo `-TargetHome`/runtime) mais switch `-Clean`; `-WhatIf` continua suportado. Clean não amplia o destino indicado pelo instalador.

**Pré-condições:** precheck completo, runtime V2 confirmado, manifest legível/validável quando existir, inventário de destinos e hashes antes de escrita, diretórios-alvo sem traversal/reparse não autorizado, backup concluído e staging validado. Conflito de CAS aborta antes de aplicar.

**O que remove:** somente artefatos que o manifest anterior atribua à Orquestração e cujo hash atual corresponda ao hash registrado; também pode remover artefato legado explicitamente conhecido e comprovado pelo manifest/regra de migração. Qualquer arquivo ausente do manifest, hash divergente, path inválido ou ownership externo é preservado e reportado como conflito/preservado. Não inferir posse por nome ou localização.

**O que preserva:** bloco `agent-config:global`, `mcp`, `ai-memory`, plugins de terceiros, skills externas, credenciais, `models.jsonc` e conteúdo/arquivos editados pelo usuário; preserva tudo fora do manifest e campos/chaves de outros owners. Skills compartilhadas por junction do Agent Config são preservadas (`ownership.shared_skills`) e validadas, nunca escritas. Tratamento de junction/reparse deve falhar fechado ou preservar sem atravessar o destino redirecionado.

**Ordem transacional:** (1) ler manifest e inventariar; (2) validar paths/owners/hashes e precheck; (3) gerar plano; (4) em `-WhatIf`, imprimir plano e sair sem criar backup/stage/arquivo; (5) fazer backup; (6) stage e validar estado desejado; (7) CAS imediatamente antes de cada mutação; (8) remover obsoletos comprovados e aplicar estado desejado; (9) executar validações; (10) gravar manifest como última mutação; (11) em qualquer falha durante apply/validação/manifest, restaurar bytes anteriores e manter evidência do rollback. Segunda execução sem drift deve reportar `UNCHANGED` e não modificar artefatos.

**Exit codes:** preservar códigos atuais 0 sucesso, 3 precheck, 4 conflito CAS e 5 falha de apply/rollback tentado; reservar novo código 7 para `VALIDATION_FAILED` pós-apply, com rollback concluído quando possível. Códigos não devem confundir ausência de provider funcional com falha de validação estática.

**Idempotência:** repetir `-Clean` sobre estado já convergido não altera hashes nem manifest funcionalmente; nenhum arquivo de terceiro é removido e o resultado predominante é `UNCHANGED`.

## 5. Matriz de testes de integração (10 cenários)

| # | Cenário | Critério | Prova |
|---|---|---|---|
| 1 | Instalar Orquestração antes do Agent Config | Agent Config consome perfis canônicos sem sobrescrever áreas da Orquestração. | Harness TEMP com fixture de duas ordens. |
| 2 | Instalar Agent Config antes da Orquestração | Resultado converge para ownership v2 e global permanece intacto. | Harness TEMP com fixture de duas ordens. |
| 3 | Atualizar Agent Config após Orquestração | Perfis delegados não sofrem overwrite; fonte ausente não gera perfis substitutos. | Harness TEMP: guard/importador e comparação de hashes. |
| 4 | Atualizar Orquestração após Agent Config | 19 perfis e `agents` são atualizados; texto global e campos do Config preservados. | Harness TEMP e fixture `agent-config:global`. |
| 5 | `-Clean` com resíduos intactos do manifest | Remove só hashes correspondentes, faz backup e reaplica estado desejado. | Harness TEMP com manifest/hash conhecido. |
| 6 | `-Clean` com arquivo editado/ausente do manifest | Preserva e reporta conflito; não apaga arquivo desconhecido. | Harness TEMP com canários e hashes divergentes. |
| 7 | Falha em fase de apply/validação/manifest | Rollback restaura bytes e manifest anteriores; exit code correto. | Harness TEMP com injeção de falha por etapa. |
| 8 | `-WhatIf` e segunda execução | WhatIf não escreve; execução repetida é idempotente (`UNCHANGED`). | Harness TEMP com snapshot/hash antes e depois. |
| 9 | Preservação de terceiros e reparse | MCP/ai-memory/plugins/skills externas e alvo de junction permanecem intactos. | Harness TEMP com canários e fixture junction (quando suportada). |
| 10 | Validação pós-install + functional check | Estática verifica plugin, Planner, 19 perfis, models/delegação, skills e config; ausência de provider não vira PASS funcional. | Harness TEMP com provider ausente/simulado; execução funcional opt-in separada. |

## 6. Vocabulario de resultado

- **`INSTALLED`** — recurso ausente ou divergente foi criado/atualizado com sucesso sob ownership deste instalador.
- **`UNCHANGED`** — recurso já corresponde ao estado desejado; nenhuma escrita necessária.
- **`PRESERVED`** — recurso não pertence a este owner, foi editado/sem prova de hash, ou foi deliberadamente preservado; nenhuma sobrescrita/remoção executada.
- **`CONFLICT`** — ownership, CAS, hash ou path não permite mutação segura; operação afetada é bloqueada e requer reconciliação explícita.
- **`FAILED`** — erro operacional em precheck/apply/rollback; relatório informa fase e se rollback foi concluído ou ficou incompleto.
- **Exit code `8` — `VALIDATION_FAILED`** — aplicação ocorreu, mas a validação pós-instalação obrigatória falhou; executar rollback conforme contrato e não declarar instalação válida.

## 7. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Ordem diferente de instalação dos dois projetos recria disputa. | Testar ambas as ordens e ambas as atualizações; contrato por namespace e guard no reconciliador; locks/CAS. |
| Perfis stale persistem ou um owner os reverte. | Hash/fonte canônica explícita, relatório de drift e teste de convergência dos 19 perfis. |
| Junction/reparse redireciona escrita/remoção para fora do destino. | Validar cada componente do path; não atravessar reparse não autorizado; fixture de junction com canário externo. |
| EOL LF/CRLF causa falso drift e escrita desnecessária. | Comparação normalizada para conteúdo textual; preservar bytes em rollback; teste para ambos EOL. |
| Edição manual do usuário é sobrescrita ou removida. | Backup, hash/CAS, `PRESERVED`/`CONFLICT`; não reivindicar sem evidência no manifest. |
| Provider ausente torna teste funcional inconclusivo. | Functional check opt-in, estado explícito `BLOCKED`/não executado; sem alegar PASS; validação estática continua separada. |

## 8. Ordem de execução P0-P5 e conclusão

Ordem proposta: **P0** fechar contrato/owners e critérios; **P1** M1 (delegação no Agent Config); **P2** M2 (ownership ativo na Orquestração); **P3** M3-M4 (`-Clean`, relatório e validação); **P4** M5 (fixtures e distribution); **P5** M6-M7 (reinstalação real autorizada, re-sync e evidência/documentação).

Critérios de conclusão:

- [ ] Os dois instaladores convergem para a matriz normativa v2 nas duas ordens de instalação e atualização.
- [x] O texto global `agent-config:global` permanece intacto e a Orquestração retira apenas seu próprio legado.
- [x] Os 19 perfis ativos e o objeto `agents` correspondem à fonte canônica da Orquestração.
- [x] Agent Config não aplica nem inventa perfis quando a Orquestração/fonte canônica não está disponível.
- [ ] `-Clean` remove somente artefatos provados por manifest/hash e faz backup antes da mutação.
- [ ] `-WhatIf`, CAS, rollback, reparse/junction e idempotência são comprovados em fixtures.
- [x] MCP, ai-memory, plugins/skills externos, credenciais, `models.jsonc` e edições do usuário são preservados.
- [x] Validação pós-install separa prova estática de functional check/provider e usa resultados/exit codes definidos.
- [x] Reinstalação real V2 e re-sync foram verificados com evidência, sem reversão de ownership.

Itens 1, 5 e 6 permanecem sem marcação nesta reconciliação porque dependem do mapeamento cenário-a-cenário da suíte de fixtures (§10), não reexecutada nesta rodada.

## 9. Fontes e conflito documental

- `install.ps1:1400-1428`, `install.ps1:1595-1625`, `install.ps1:1733-1758`, `install.ps1:2347-2379`.
- `uninstall.ps1:262-302` e `uninstall.ps1:304-359`.
- `docs/INSTALLATION.md:41` e seção **Ownership Agent Config (OpenCode V2)**.
- `scripts/v3/install-ownership.tests.ps1` (T1-T13).
- Agent Config: `docs/governance/ADR-INTEROP-001-SINGLE-OWNER-CONFIG-EXECUTION.md` e `docs/agent/AGENT-CONFIG-ORCHESTRATION-INTEROP-SPEC.md`, §4 e §4.1.
- `CHANGELOG.md:7-24`.

A divergência foi resolvida em 2026-11-12: o ADR-INTEROP-001 recebeu a Revisão 2 (ATIVO parcial; 19 perfis e `agents.*` atribuídos à Orquestração) e a SPEC de interop foi alinhada (P1, Estado e §4.1). Bundle `agent-profile-bundle/v1`, quality gate e migração dos sete módulos permanecem proposta. A matriz desta missão é o alvo documentado.

## 10. Evidencia

Comandos e N/N medidos na implementação/revisão (evidência fornecida à tarefa; suítes não reexecutadas nesta rodada de documentação):

- `scripts/v3/install-ownership.tests.ps1`: **45/45** em PowerShell 7 e Windows PowerShell 5.1.
- `scripts/test-package-consistency.ps1`: **17/17**.
- Suíte distribution (pwsh e PS5.1): **22 PASS / 1 FAIL** (`skills-catalog`, preexistente) / **1 SKIP** (`live-hook-v2`) / **1 ERROR** (`eol-checkout`, timeout preexistente).
- Runner V3 (rodada anterior): **27 PASS / 0 FAIL / 2 SKIP**.
- Agent Config (suíte do repositório Agent Config): **39/44** com **5 falhas preexistentes** (não atribuídas a esta entrega).
- `planning-roles`: **107/108**, com 1 falha preexistente de token; mirror/lock exercitados.

Revisão reviewer/security retornou `CHANGES_REQUIRED`; correções aplicadas: guard `-TestRoot`/junction, ESM `.mjs`, V1 managed ids, uninstall de `agents.*` por snapshot, `-Clean -NoCoreSkills`/exit 2, importer `-Check`/conflito sem lock e exit 8 exclusivo.

**Execução real M6 (2026-11-12, evidência `evidence/install-ownership-2026-11-12/migration-report.md`, registro ORCH-MIGRATION-02, e `post-validation.json`):** `-Clean` já aplicado; Agent Config Instructions OpenCode Apply com `-Force` exit 0, `[SAME]`, `Actionable instruction targets: 0` (apply posterior de reconfirmação); 19/19 hashes de `agents/*.md` idênticos antes/depois; `AGENTS.md` com exatamente 1 par `agent-config:global` e 0 pares `opencode-orchestration`. Guard `scripts/v3/reconcile-agents.ps1 -Preview` no repo Agent Config: exit 2, `DELEGATED_TO_ORCHESTRATION owner=opencode-orchestration`, nenhuma escrita. Delegação funcional provada separadamente: `opencode run --agent build` delegou ao subagente `coder`, resposta `OK-DELEGADO`, sessão `ses_e2fd346a8ffeEO1RHYcsdvRtkh`, estado `completed`.

**Verificação de convergência pós-M6 (2026-11-12, read-only):** `install.ps1 -Runtime V2 -Clean -WhatIf` exit 0: `RESULT: INSTALLED=0 UNCHANGED=24 PRESERVED=12 CONFLICT=0 FAILED=0`, 36 recursos, nenhuma escrita, 0 REMOVE. 19/19 perfis `agents/*.md` e `plugins/orchestration-enforcement.js` conferem por SHA-256 com o manifest; hash do plugin `E7FD1959644572372C64393A4399F1F0C19B3C952C1FC942E3C225E4D70168C3`, igual ao bundle de `plugins/dist` do HEAD. `AGENTS.md`: 1 par `agent-config:global`, 0 `opencode-orchestration`; `opencode.json`: 19 subagentes + build + title, `agents.build.model=opencode-go/deepseek-v4.1-flash`, `permissions`/`mcp` presentes, `plugin` top-level ausente (coberto por auto-discovery, ver comentário em `install.ps1:698`); 109 junctions em `skills/`; 65/65 `managed_config_paths` batem com `config_snapshot` do manifest (normalizado) — a edição manual de `opencode.json` às 17:04 não alterou nenhum campo de ownership da Orquestração.

**Limitações (preservadas):** `functional_delegation=NOT_RUN` no manifest (prova funcional externa/separada via `opencode run`); `plugin` top-level ausente do config ativo por auto-discovery; `evidence/` é gitignored. Prova funcional não embutida/alegada como PASS pelo instalador.

## 11. Handoff (5 campos)

- **Objetivo:** documentar entrega implementada e convergida de ownership flip, `-Clean`, validação pós-install e migração real V2.
- **Estado:** M1-M7 **DONE** (migração real V2 + re-sync executados em 2026-11-12 e convergência pós-M6 verificada). Limitações: `functional_delegation=NOT_RUN` no manifest (prova funcional externa/separada), `plugin` top-level ausente por auto-discovery, `evidence/` gitignored.
- **Alterações:** `docs/INSTALLATION.md`, `README.md`, `CHANGELOG.md`, `docs/specs/INSTALL-OWNERSHIP-CLEAN-2026-11-12-PLAN.md` (e correções pontuais de ownership contraditório em docs, se aplicável).
- **Validação:** `git diff --check`; greps de contradição em docs/README; convergência pós-M6 read-only (`-Clean -WhatIf` `INSTALLED=0 UNCHANGED=24 PRESERVED=12 CONFLICT=0 FAILED=0`); sem reexecução de suites nesta rodada (resultados medidos acima).
- **Próximo passo:** revisão do PR/CI; sem novo ciclo de instalação. Prova funcional separada com provider apenas se necessário (já demonstrada separadamente em 2026-11-12).
