# Orquestração híbrida (Claude + Orca + OpenCode)

Documentação mínima da integração híbrida (M4) e da migração T3/T4 para
Terra/Sol. Não substitui as instruções permanentes nem os relatórios de
homologação; apenas descreve o contrato operacional e aponta para as fontes.

## Arquitetura

Três papéis distintos, sem sobreposição de autoridade:

- **Claude coordena:** é o único control plane. Interpreta o objetivo, decide
  estratégia, decompõe tarefas, delega, acompanha evidência, replaneja e encerra.
- **Orca supervisiona:** fornece o terminal de coordenação, o despacho de
  workers, o inbox de mensagens e o ciclo de vida das sessões. O coordenador
  alcança o terminal de trabalho por `_orca orchestration_` (canal que o worker
  não vê diretamente).
- **OpenCode executa:** roda os workers (subagentes) que implementam, validam e
  revisam, sob as permissões e o kernel existentes.

Não há daemon, polling, fila externa, segundo kernel nem plugin novo. A
coordenação é orientada a eventos do próprio Orca; a retomada usa `run-current`,
`run-list`, `worker-list` e o inbox — nunca um segundo controlador nem laço de
espera ativo. A hierarquia de subagentes permanece rasa (`subagent_depth: 1`):
workers não criam subagentes próprios.

## Instruções permanentes e instalação

O repositório é a fonte canônica; nada é copiado à mão para `~/.claude`:

- `source/claude/CLAUDE.hybrid.md` — seção "Orquestração híbrida (Claude +
  Orca + OpenCode)", instalada como bloco marcado em `~/.claude/CLAUDE.md`.
- `source/claude/skills/hybrid-orchestration/` — `SKILL.md` + `references/`
  (`dispatch-confirmation.md`, `opencode-contract.md`, `resume.md`).

Instalação opt-in, preservando o que já existe (backup em
`<ClaudeHome>/backups/opencode-orchestration-claude/<ts>/`, manifest com SHA256).

### Fluxo real e guardrail de destino

`install.ps1 -ClaudeHybrid` dot-source `scripts/runtime/lib/OrchestrationTargetGuard.ps1`
e aplica o guardrail **somente a `-TargetHome`** (destino OpenCode). O `-ClaudeHome`
é apenas repassado ao instalador Claude e **não** passa por esse guardrail.
Comportamento observado na certificação P1-04 (2026-11-20):

- `install.ps1 -ClaudeHybrid` com `-TargetHome` omitido (padrão = `USERPROFILE`)
  falha antes de qualquer escrita com `MUTATING_TARGET_REQUIRES_EXPLICIT_PATH`.
  Para o perfil real são exigidos `-AllowUserProfileTarget` **e autorização explícita**.
- `uninstall.ps1 -ClaudeHybrid` retorna antes do guardrail (linhas 38-45 do script)
  e usa `~/.claude` como destino padrão, sem opt-in: é uma remoção não guardada.
  Sempre informe `-ClaudeHome` explicitamente; apontar ao perfil real requer
  autorização explícita.

Os comandos abaixo foram **executados contra HOME temporário** na certificação
P1-04 (evidência em `evidence/v3.1/claude-hybrid/certification-2026-11-20.json`).
Substitua `<repo>` pela raiz do checkout e `<tmp>` por uma pasta nova em `%TEMP%`:

```powershell
# Caminho Claude-only (instala/atualiza/desinstala apenas a integração Claude)
pwsh -NoProfile -File scripts\claude\install-claude-hybrid.ps1 -RepoRoot <repo> -ClaudeHome <tmp>\claude -WhatIf
pwsh -NoProfile -File scripts\claude\install-claude-hybrid.ps1 -RepoRoot <repo> -ClaudeHome <tmp>\claude
pwsh -NoProfile -File scripts\claude\install-claude-hybrid.ps1 -RepoRoot <repo> -ClaudeHome <tmp>\claude -Uninstall

# Integração completa (OpenCode + Claude) — exige TargetHome temporário
pwsh -NoProfile -File .\install.ps1 -ClaudeHybrid -TargetHome <tmp>\oc-home -ClaudeHome <tmp>\claude -WhatIf
pwsh -NoProfile -File .\install.ps1 -ClaudeHybrid -TargetHome <tmp>\oc-home -ClaudeHome <tmp>\claude

# Rollback Claude-only documentado
pwsh -NoProfile -File .\uninstall.ps1 -ClaudeHybrid -ClaudeHome <tmp>\claude
```

**Requer autorização para perfil real — NÃO executado nesta frente:**

```powershell
pwsh -NoProfile -File .\install.ps1 -ClaudeHybrid -AllowUserProfileTarget  # guardrail do TargetHome; ClaudeHome continua sem guardrail
pwsh -NoProfile -File .\uninstall.ps1 -ClaudeHybrid                        # SEM guardrail: destino padrão ~/.claude; use -ClaudeHome explícito
```

`uninstall.ps1 -ClaudeHybrid` é Claude-only: delega em
`scripts\claude\install-claude-hybrid.ps1 -Uninstall` e **não** toca a instalação
OpenCode (agentes, plugins, skills, `AGENTS.md`, `opencode.json`/`opencode.jsonc`
ou manifest). Para remover o pacote inteiro, use fluxos distintos e explícitos:
`.\uninstall.ps1` (desinstalação OpenCode padrão) e, separadamente,
`.\uninstall.ps1 -ClaudeHybrid` (integração Claude). Esses fluxos padrão
(remoção completa do pacote) não foram executados nesta frente de certificação.

Seção legada sem marcadores é adotada (sem duplicar). O bloco marcado e os arquivos
de skill editados pelo usuário viram `CONFLICT` e são preservados tanto na
atualização quanto na desinstalação; a desinstalação parcial mantém o manifest
para não perder o registro desses conflitos. Não toca `settings.json`, hooks nem
outras skills. Em divergência, o pedido atual do usuário prevalece.

## Integração Orca

Verbos usados pelo worker (os hooks nativos do OpenCode são preservados — nada
é desligado ou substituído):

- `worker-start` — inicia um worker com `--spec`, `--agent` e `--worktree`.
- `worker-show` / `worker-read` — inspecionam estado e saída de um worker.
- `worker-stop` / `worker-abandon` — encerram ou abandonam um worker.
- `check --run <id>` — lê mensagens do coordenador para a execução corrente.
- `worker_done` — sinaliza conclusão ao coordenador (`--outcome succeeded` ou
  `--outcome failed`), com `task-id` e `dispatch-id`.

O worker não vê o terminal do coordenador; toda comunicação (pergunta,
bloqueio, conclusão) passa por `orca orchestration ask/send` com `--from` apontando
ao seu próprio terminal.

## Confirmação de execução P0 após `worker-start`

`ready`/`input_accepted`/`activity=working` não provam que o turno da task
correta começou. A skill exige uma rodada de verificação (`worker-show`,
`worker-read`, `terminal read` só se faltar evidência) e trata 5 casos:
executou; texto no draft sem submeter (um único `terminal send --enter`); prompt
ausente (`worker-stop`/`abandon` + `worker-start --task --retry-of` sem `--spec`);
Dispatch sem execução observável; estado ambíguo após falha de comunicação
(`request-show`/`--retry-request`, reconciliar). Detalhe normativo em
`source/claude/skills/hybrid-orchestration/references/dispatch-confirmation.md`.
Princípio: comprovadamente não iniciado ⇒ recupera; desconhecido ⇒ `HOLD`.

## Encerramento da missão

O coordenador (Claude) é responsável pelo fecho ao longo e ao fim da missão:

1. **Fechar os workers que criou:** após aceitar a evidência de cada worker, rode
   `orca orchestration worker-release --dispatch <id>` e confirme com `worker-list`
   (`terminalState=released`, `liveness=exited`). Apenas workers iniciados com
   `--worktree current` fecham sozinhos; os de `--worktree new-child`/`new-top-level`
   ficam abertos por padrão (`worker-keep-open` só se o usuário for usar o chat). Não
   liberar worker não-concluído; falha/estado ambíguo ⇒ `worker-stop`/reconciliação
   conforme `source/claude/skills/hybrid-orchestration/references/resume.md`, sem
   duplicar.
2. **Merge:** mesclar as PRs/branches criadas pela missão somente com CI verde completo
   e critérios de aceite comprovados — nunca com CI pendente/vermelho. `gh pr checks` é
   pontual, sem laço de espera/polling.
3. **Higiene:** após o merge, remover worktrees filhos (Orca ou `git worktree remove`
   sem `--force`, só se limpos e totalmente mesclados) e branches locais/remotas
   mescladas que a missão criou. Nunca apagar trabalho não mesclado, stashes ou
   branches/worktrees pré-existentes ou de terceiros; relatar removidos e preservados
   (com motivo) no relatório final. Ações irreversíveis fora do que a missão criou
   exigem confirmação.

## Homologação A–G

Ver `evidence/v3.1/claude-hybrid/homologation-2026-11-19.json` (ambiente
descartável; cenários simulados identificados como tal).

## Certificação P1-04 / P1-05 (2026-11-20)

Evidência: `evidence/v3.1/claude-hybrid/certification-2026-11-20.json`.

- **P1-04 — `candidate_pass`; `TESTED_IN_ISOLATION=PASS`;
  `ACTIVE_PROFILE_VERIFIED=NOT_VERIFIED`.** Instalar → atualizar (fonte alterada
  em cópia scratch) → desinstalar foi executado contra ClaudeHome temporário; a
  preservação de personalizações já é coberta por P0-01 e não foi reimplementada.
  Todos os comandos documentados acima foram executados contra HOME temporário,
  exceto os dois marcados como "requer autorização para perfil real". O skill
  `hybrid-orchestration` tem frontmatter válido (`name`/`description`) e é
  descoberto/carregado pelo Claude Code quando `CLAUDE_CONFIG_DIR` aponta ao
  diretório temporário (debug do runtime: `Loaded 1 unique skills … user: 1`).
  O turno headless real (`claude -p`) fica em `HOLD_NOT_VERIFIED`: sem credencial
  no ambiente isolado o CLI responde `Not logged in · Please run /login`; as
  credenciais do perfil real não foram usadas nem copiadas. Nenhum perfil real
  foi tocado.
- **P1-05 — `blocked` / `HOLD`.** Não há coordenador Claude headless iniciável
  de forma controlada sem credencial no ambiente isolado, e usar credencial real
  violaria o isolamento e poderia gerar efeito externo. Sem sessão para
  interromper, o cenário não foi forçado: nenhum worker OpenCode, worktree,
  branch ou infraestrutura foi criado para P1-05.

## Configuração T3/T4 (policy 1.6.1)

Mapeamento da policy 1.6.1 (fonte canônica:
`source/registry/model-routing-policy.json`):

- **T3:** `openai/gpt-6.1-terra` — seleção real do router para tarefas de alto
  risco (ex.: `reviewer`).
- **T4:** `openai/gpt-6.1-sol` — escalonamento de T3, condicionado a
  `kernel proof-gated` (prova `RequiredTier T3` válida do Task Kernel).
- **Astra:** excepcional e `proof-gated` — somente após prova T4 válida; sem
  execução em runtime até o momento.
- **T1/T2 e Planner `build`:** inalterados por esta migração.

Precedência efetiva de configuração: `models.jsonc` local **>** variáveis de
ambiente **>** policy. O `models.jsonc` local é *gitignored* e precisa refletir
Terra/Sol para que a seleção local não diverge da policy.

A configuração viva em `~/.config/opencode` **não** foi alterada. Qualquer
aplicação deve passar somente por
`scripts\reconcile-opencode-config.ps1`, com backup e rollback — **não executado**
nesta frente.

## Recuperação

Reconstruir o estado a partir do Orca, sem presumir o que aconteceu:

1. `orca orchestration ... run-current` / `run-list` — identificar a execução.
2. `worker-list` / `worker-show` — estado dos workers e seus despachos.
3. `check --run <id>` / inbox — mensagens pendentes do coordenador.

Nunca reiniciar um Dispatch sem prova observável de que ele não chegou a
executar. Na dúvida, `HOLD` e reconciliar; não duplicar turno, dispatch ou
efeito.

## Resultados da homologação

- **P0 (confirmação de execução):** homologado em 3 cenários em repositório
  descartável; cenários 2 e 3 foram **SIMULADOS** — provam o procedimento, não a
  frequência da falha.
- **T3/T4 — seleção real do router:** `reviewer` de risco alto →
  `openai/gpt-6.1-terra`; escalonamento T4 → `openai/gpt-6.1-sol`
  (`kernel proof-gated`). Astra só provado por testes do kernel, não em runtime.
- **B (runtime):** `opencode run -m openai/gpt-6.1-terra` e
  `-m openai/gpt-6.1-sol` em repo descartável; `opencode session export`
  registra `model.id` `gpt-6.1-terra` / `gpt-6.1-sol`, `providerID` `openai`.
- **Testes:** suítes de modelo 16/16 verdes em PS7 e PS5.1; `run-v3-tests` em
  PS5.1 todas verdes (timeouts do runner completo eram carga de memória;
  reexecutadas isoladas/em lotes com exit 0); `package-consistency` 17/17;
  `distribution` 24 pass / 0 fail / 1 skip; `git diff --check` limpo. Um assert
  de `OrchestrationPlannerModelConfig` que fixava o `models.jsonc` local em
  `sonnet`/`opus` foi atualizado para `terra`/`sol`.
- **NÃO FEITO / com o operador:** **D** (interromper a sessão do Claude com
  worker rodando e retomar) depende do operador; **E** (eficiência híbrido vs
  OpenCode direto) sem medição conclusiva — não alegar ganho; `reconcile` da
  config viva pendente de autorização; commit não feito.
- **P1-04/P1-05 (2026-11-20):** ver secção "Certificação P1-04 / P1-05"; suíte
  `claude-hybrid.tests.ps1` 46/46 em PS7 e PS5.1, `test-package-consistency`
  17/17, `git diff --check` limpo.

## Limitações

- Dois dos três cenários da confirmação P0 (os cenários 2 e 3) foram simulados:
  validam o procedimento, não a taxa de falha em produção.
- Astra não foi executado em runtime; apenas coberto por testes do kernel.
- O cenário D depende de interrupção/retomada pelo operador; não homologado
  aqui. P1-05 tentou formalizá-lo e registrou `HOLD` por falta de coordenador
  headless autenticável em isolamento.
- A invocação do skill por um turno real do modelo (`claude -p`) não foi provada
  no isolamento (`HOLD_NOT_VERIFIED`); apenas descoberta/carga pelo runtime e
  frontmatter válido foram comprovados.
- `uninstall.ps1 -ClaudeHybrid` não passa pelo guardrail de destino e mira
  `~/.claude` por padrão; exige `-ClaudeHome` explícito e autorização para perfil
  real (comportamento do chamador, fora do escopo de código desta frente).
- Não há medição conclusiva de eficiência (cenário E): nenhum ganho é alegado.
- A configuração viva não foi reconciliada; o `models.jsonc` local é fora do
  controle de versão e sua conformidade precisa ser verificada no ambiente.

## Rollback

Esta frente produz documentação, um JSON de evidência e 9 asserts de teste;
nenhuma configuração viva foi alterada. Para reverter:

1. Reverter `docs/HYBRID-ORCHESTRATION.md`.
2. Remover `evidence/v3.1/claude-hybrid/certification-2026-11-20.json`.
3. Reverter a seção 9 em `tests/distribution/claude-hybrid.tests.ps1`.
4. Não há configuração viva alterada a restaurar. Não executar `reconcile`
   como forma de rollback.

Nenhum commit, push, install em perfil real ou reconciliação foi realizado;
alterações preexistentes de outras frentes no worktree devem ser preservadas.
