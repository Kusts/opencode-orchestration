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

## Instruções permanentes

As regras estáveis não são duplicadas neste arquivo. Elas vivem em:

- `~/.claude/CLAUDE.md`, seção **"Orquestração híbrida (Claude + Orca +
  OpenCode)"** — política de coordenação e limites de autonomia.
- `~/.claude/skills/hybrid-orchestration/SKILL.md` — técnica/fluxo da skill de
  orquestração híbrida.

Aqui apenas se aponta para esses arquivos; o conteúdo deles não é copiado nem
reinterpretado. Em caso de divergência, as instruções permanentes e o pedido
atual do usuário prevalecem sobre este resumo.

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

Após `worker-start`, confirmar que o worker realmente começou a executar antes
de prosseguir. Três casos:

- **Caso A — Enter único:** enviar `orca terminal send --terminal <H> --enter`
  uma única vez para disparar/Confirmar a execução no terminal do worker.
- **Caso B — reinício sem duplicar:** `worker-stop` ou `worker-abandon`, depois
  `worker-start --task <id> --retry-of <dispatch> --agent ... --worktree ...`
  **sem `--spec`**. O `--retry-of` vincula o novo worker ao despacho anterior.
- **Caso C — reconciliar sem duplicar:** antes de redespachar, consultar o
  estado no Orca (`run-current`, `worker-list`, inbox) e reconciliar com o
  despacho existente; nunca criar um segundo worker para o mesmo trabalho sem
  prova de que o primeiro não executou.

O princípio é não duplicar efeito: sessão presente, timeout ou resultado
desconhecido implicam retenção (`HOLD`), não reenvio cego.

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

## Limitações

- Dois dos três cenários da confirmação P0 (os cenários 2 e 3) foram simulados:
  validam o procedimento, não a taxa de falha em produção.
- Astra não foi executado em runtime; apenas coberto por testes do kernel.
- O cenário D depende de interrupção/retomada pelo operador; não homologado
  aqui.
- Não há medição conclusiva de eficiência (cenário E): nenhum ganho é alegado.
- A configuração viva não foi reconciliada; o `models.jsonc` local é fora do
  controle de versão e sua conformidade precisa ser verificada no ambiente.

## Rollback

Esta frente só produz documentação. Para reverter:

1. Remover `docs/HYBRID-ORCHESTRATION.md`.
2. Reverter as linhas adicionadas em `CHANGELOG.md` sob `[Unreleased]`.
3. Não há configuração viva alterada a restaurar. Não executar `reconcile`
   como forma de rollback.

Nenhum commit, push, install ou reconciliação foi realizado; alterações
preexistentes de outras frentes no worktree devem ser preservadas.
