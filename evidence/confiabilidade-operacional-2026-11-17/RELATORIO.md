# Confiabilidade operacional do Planner — Marco 3

**Baseline:** `master@5e4f848` · **Data:** 2026-11-17 · **Orientador:** `EXECUTAR` para o Marco 2.

## Marco 1 — diagnóstico

### Frente A — permissões e runtime

Versão efetiva observada: `opencode v2.3.0` (`/api/info`, PID 21180).

| Agente | Declaração no `opencode.json` ativo |
|---|---|
| `build` | Regras `ask` específicas (`git push *`, `rm *`, `del *`, `Remove-Item *`, `git reset --hard*`, `git clean *`, `git branch -D *`) são os últimos matches; não há `shell * allow` final que as sobrescreva. |
| `coder`, `tester` | `shell * allow` aparece no meio da lista; regras específicas tardias `ask`/`deny` tratam recursos sensíveis. |
| `security-reviewer` | `shell * deny` vem após `git push * ask` e antes da allowlist de leitura; possível prevalência do deny. |

Distinção de evidência: o texto acima descreve a **declaração** no config ativo; `opencode debug agents --standalone` permitiu inspecionar a **resolução efetiva**. **Execução comportamental de allow/ask/deny não foi comprovada** — não inferir enforcement da configuração ou da resolução.

Estado real: `runtime_grant_enforcement.v1/v2=false`; `bounded_execution=true`, porém `ExecutionBudget.enforce=false`; plugin fail-open (mandato por prompt, não barreira); `external_directory` ausente; plugin instalado 2.0.28, atrás do pin 2.3.0. Achado **HIGH**: regra ampla `allow` para SSH de deploy no config ativo. É risco de configuração do operador e não foi alterada nesta missão.

Sondas: `opencode debug config/agents` e `/api/info` funcionaram; `opencode serve` descartável retornou 401 em `/api/info`; CLI 2.3.0 não tem comando nativo `debug permission/policy`. `opencode run` exige mensagem/sessão e criaria efeito ambíguo, portanto não foi usado. Config ativo permaneceu byte-a-byte idêntico (`COUNT=34989`, hash inalterado).

**Veredito de permissionamento: `BLOCKED_RUNTIME_PROOF`** — resolução inspecionada, enforcement comportamental não verificável no ambiente permitido. Não declarar `VERIFIED`.

### Frente B — autonomia e retry

Resultados: `p0-autonomy-proof` 14/14; `retry-decision-e2e` 6/6; `OrchestrationCorrectiveE2E` 119 assertions. Goal T1→T2 falha→T2→T3→COMPLETED; cobertura de `LOCAL_REPAIR`/`REPLAN`/`ESCALATE`, anti-duplicação e terminais honestos. Nenhuma interrupção nova foi reproduzida; seis classes de causa já estão mapeadas. Nenhuma correção de código foi apontada.

### Frente C — retomada automática

**HOLD fundamentado** para retomada automática do Planner após encerramento de processo/sessão, timeout/indisponibilidade ou troca de modelo com contexto. Reavaliar somente quando houver: (1) primitiva nativa provada no binário exato; (2) prova correlacionada de não-início; (3) correlação ponta a ponta com CAS/fencing; e (4) wiring `PREPARE→SUBAGENT→SETTLE→VERIFY→ADVANCE` em runtime real. Nenhum daemon, supervisor ou segundo Planner foi criado.

## Marco 2 — revalidação fresca nesta missão

`p0-autonomy-proof`: 14/14; `retry-decision-e2e`: 6/6; `OrchestrationCorrectiveE2E`: 119 assertions; `test-package-consistency`: 17/17; `git diff --check`: limpo. Todos executados novamente, sem divergência.

## Encerramento e pendências

Critérios atendidos, exceto prova comportamental de permissões, registrada como `BLOCKED_RUNTIME_PROOF`. HOLD para retomada automática aceito como parte do objetivo. Nenhuma correção de código aplicada: não houve defeito reproduzível.

Issue #141 atualizada com o gap e o achado HIGH redigido; issue #193 referenciada para as condições de reavaliação da retomada. Sem novas issues.

Pendências: prova de execução allow/ask/deny depende de primitiva nativa ou fixture autenticada fora deste escopo; atualização do plugin 2.0.28 para 2.3.0 e regra SSH são decisões do operador.
