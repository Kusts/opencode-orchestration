# M1 — Prova runtime do encadeamento do Planner (issue #208)

**Data:** 2026-11-10
**HEAD:** `54a9d3c` + alterações locais desta rodada
**Runtime:** OpenCode `2.2.6` (live `/api/info`), Windows, PowerShell 5.1
**Task:** `evo-m1-proof-20261110` (Task Kernel, `cache/runtime/tasks`)
**Root session:** `ses_e38f4d363ffeqWs1ctgwoAdD94`
**Run:** `run-m1-proof`

## Objetivo

Provar que o Planner executa o encadeamento completo a partir de uma única
instrução humana, sem comandos intermediários: `model-select → dispatch →
attempt → proof → decisão`.

## Sequência observada

| Etapa | Resultado |
|---|---|
| `create` | `ok=true`, revision 1, state `DISCOVERING` |
| `bind-session` (root) | revision 2, run `run-m1-proof` attached |
| `model-select -AttemptRole reviewer` | `tier=T3`, `model=claude-agent/sonnet`, `native_model_override_proven=true`, `policy_hash=35bd10bd…535db6` |
| dispatch nativo (`subagent` + `model=claude-agent/sonnet`) | child `ses_e38e24116ffe2wuhQ4hWiLwwrj`, agent `reviewer`, model `claude-agent/sonnet`, outcome `succeeded` |
| `detach-session` (root) | revision 3, owner liberado |
| `bind-session` (worker) | revision 4, child em `worker_sessions`, parent/root corretos |
| `record-result` | revision 5, `candidate_pass`, refs `session:` + `message:` |
| `model-attempt` | revision 6, `attempt_n=1`, `tier=T3`, `model=claude-agent/sonnet`, `provider=claude-agent`, `message_id=msg_1c71dec64001Yh1sTI30GpDfwP`, mesmo `policy_hash` |
| `model-proof -RequiredTier T3` | `ok=false`, `PROOF_VERIFICATION_MISSING` |
| `model-proof -RequiredTier T4` | `ok=false`, `PROOF_VERIFICATION_MISSING` |

## O que ficou provado

1. O Planner selecionou o modelo pelo Kernel e despachou o worker nativo com o
   override exato, sem intervenção humana entre as etapas.
2. O Kernel registrou a tentativa com modelo, provider, tier, sessão filha,
   mensagem, run e hash de política — correlação real, não declaração.
3. Sucesso T3 **não** autoriza T3/T4: sem prova de falha funcional, os dois
   `model-proof` falham fechados.
4. Ausência de prova não gera replay nem dispatch adicional.

## Achados do reviewer e correção

O reviewer T3 retornou `CHANGES_REQUIRED` com 3 achados válidos sobre a guarda
da cadeia:

1. `fable HOLD` não era verificado na política/adapter.
2. As âncoras do adapter eram frágeis (o bloco decisório podia ser apagado).
3. O drift `T3 → Sol` só era detectado na forma com parênteses.

Correções aplicadas e provadas:

- checagem de `claude_fable` presente, `gated=true` e fora de
  primary/exceptional/alternatives (`fable-in-chain`, `fable-gate-missing`);
- marcador estável `<!-- model-chain:canonical -->` + frase decisória
  obrigatória (`adapter-missing-canonical-block`);
- detecção de `T3 → Sol` nas formas com parênteses, sem parênteses e
  `Sonnet → Sol`;
- testes ampliados de 15 para 32 asserts (policy, adapter, fable, blocos e
  drifts), todos PASS.

## Limites (não alegados)

- O encadeamento foi executado pelo Planner por chamadas discretas ao CLI do
  Kernel; **não** existe um único comando que faça tudo. A integração é
  comportamental (Planner + primitivas), não um controlador novo.
- Não houve dispatch T4 nem Astra; a cadeia T4 permanece dependente de prova
  de falha funcional da mesma Task.
- O `CHANGES_REQUIRED` do reviewer foi resolvido por correção + testes; uma
  re-revisão não foi reemitida na mesma sessão para não alterar a mensagem
  pinada na tentativa registrada.
- Fechamento da #208 continua pendente de revisão do maintainer.

## Conclusão

O critério central do M1 — Task real percorrendo o fluxo completo sem comando
humano entre etapas, com sucesso T3 não escalando e falta de prova bloqueando
execução adicional — está demonstrado no runtime real. O status do binding
permanece **PARTIAL**: primitivas + encadeamento comportamental provados;
automação em um único comando não implementada (e não necessária antes de
decisão explícita).
