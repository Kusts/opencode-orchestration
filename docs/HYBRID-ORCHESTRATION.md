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

Ambos os fluxos dot-source `scripts/runtime/lib/OrchestrationTargetGuard.ps1`
e chamam `Assert-OrchestrationMutatingTargetAllowed` **antes de qualquer escrita**.
`install.ps1` aplica o guardrail a `-TargetHome` (destino OpenCode; `-ClaudeHome`
continua apenas repassado ao instalador Claude), enquanto `uninstall.ps1` aplica
o **mesmo** guardrail ao destino Claude do caminho `-ClaudeHybrid`. Com
`-ClaudeHome` omitido, o destino Claude padrão é `~/.claude` (dentro do perfil) e
a operação falha com `MUTATING_TARGET_REQUIRES_EXPLICIT_PATH`; um `-ClaudeHome`
explícito fora do perfil (por exemplo, temporário) continua funcionando sem a flag.
Comportamento observado na certificação P1-04 (2026-11-20) e na frente do guardrail
de desinstalação (2026-11-21):

- `install.ps1 -ClaudeHybrid` com `-TargetHome` omitido (padrão = `USERPROFILE`)
  falha antes de qualquer escrita com `MUTATING_TARGET_REQUIRES_EXPLICIT_PATH`.
  Para o perfil real são exigidos `-AllowUserProfileTarget` **e autorização explícita**.
- `uninstall.ps1 -ClaudeHybrid` com `-ClaudeHome` omitido falha da mesma forma,
  antes de delegar ao desinstalador Claude (nenhum arquivo escrito ou removido).
  Para o perfil real são exigidos `-AllowUserProfileTarget` **e autorização explícita**;
  `-ClaudeHome` temporário explícito não exige a flag. A remoção do pacote inteiro
  (sem `-ClaudeHybrid`) e o fluxo `install.ps1 -ClaudeHybrid` não foram alterados.

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
pwsh -NoProfile -File .\uninstall.ps1 -ClaudeHybrid -AllowUserProfileTarget # guardrail do destino Claude; ~/.claude com opt-in explícito
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

## Integração Orca, contrato observável e encerramento

O guia instalado (`orca skills get orchestration --full`) e `worker-start --help` são a fonte de verdade dos comandos; a instrução operacional do coordenador vive em `source/claude/` (`CLAUDE.hybrid.md` + skill `hybrid-orchestration`). Resumo:

- O Orca inicia o primário `build` do OpenCode; o `build` escolhe especialistas e delega toda escrita, sem `--model`.
- Placement explícito em cada Dispatch: `current` só leitura/escritor único em checkout exclusivo; `new-child` para concorrência ou checkout compartilhado; `new-top-level` para trabalho independente. Retry não herda placement; verifique repo/caminho/branch/base reais (parentesco na UI do Orca não é ancestralidade Git).
- Contrato do spec e placement: `source/claude/skills/hybrid-orchestration/references/opencode-contract.md`. Confirmação P0 e os 5 casos: `references/dispatch-confirmation.md`. Retomada: `references/resume.md`.
- O worker não vê o terminal do coordenador; comunicação passa por `orca orchestration ask/send/worker_done` com `--from` do próprio terminal. Nunca conduza worker pelo terminal; use `send` (exceção delimitada em `dispatch-confirmation.md`).

Contrato observável: Dispatch criado → prompt recebido → turno iniciado → progresso → `worker_done` → verificado → integrado → worker liberado → worktree e branch limpos. `worker_done` não é prova; `worker-release --dispatch` só fecha o terminal (não remove worktree); CI verde não é merge.

O coordenador, ao longo e ao fim da missão: segue `next` do `worker-list`; libera workers concluídos (`worker-release --dispatch <id>` + confirmação), sem liberar não-concluídos; faz PR/checks/merge confirmado e `git pull --ff-only` na base; remove só worktrees/branches da missão, limpos e mesclados, sem `--force`, preservando stashes e trabalho pré-existente/de terceiros. Squash merge não aparece como ancestral: prova pelo estado da PR e pela ausência de commits locais inéditos. Detalhes normativos em `source/claude/`.

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

A policy é a fonte única dos primários T1–T4; `models.jsonc` local é override
**opcional** (ausente ou com chaves vazias não é erro — PR #292), não fonte
independente de modelos. O arquivo é *gitignored*.

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
  config viva pendente de autorização. A integração foi mesclada via PR #289
  (684290e).
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
- `uninstall.ps1 -ClaudeHybrid` agora passa pelo guardrail de destino: sem
  `-ClaudeHome` (padrão `~/.claude`) falha antes de qualquer escrita, e o perfil
  real exige `-AllowUserProfileTarget` **e autorização explícita**. Os testes usam
  somente USERPROFILE/HOME sandboxados; nenhuma escrita em perfis reais.
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

A certificação P1-04/P1-05 foi registrada e mesclada via PR #295 (69e3309);
nenhum install em perfil real ou reconciliação foi realizado. Alterações
preexistentes de outras frentes no worktree devem ser preservadas.
