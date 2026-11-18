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

## Prova autenticada controlada (2026-11-18)

O operador autorizou a prova autenticada; o orientador respondeu `EXECUTAR` com o método HTTP Basic V2.

- `AUTH_VERIFIED`: **SIM**. `GET /api/info` em servidor descartável retornou 401 sem credencial e 200 com `Authorization: Basic`; foi usado o usuário fixo `opencode` e senha efêmera somente em variável de ambiente. Versão efetiva: 2.3.0.
- O caminho de execução sem provider foi `POST /api/session` e `POST /api/session/{id}/shell`, descoberto via `/openapi.json`.
- `POLICY_VERIFIED`: **NÃO COMPROVADO**. Com config sintética (`allow echo ALLOW_TEST*`, `ask echo ASK_TEST*`, `deny git reset --hard*`), `echo ALLOW_TEST` e `echo ASK_TEST` retornaram 204/completed, sem gate de aprovação observado para o segundo. `git -C <repo-temp> reset --hard HEAD` também retornou 204/completed e teve efeito real no repositório temporário, mas não casou com `git reset --hard*` por causa do prefixo `git -C`; portanto `deny` não foi exercitado e `ask` não foi distinguido de `allow`.
- `ACTIVE_RUNTIME_VERIFIED`: permanece `BLOCKED_RUNTIME_PROOF`; provar na configuração efetiva exigiria modificá-la.

**Incidente de isolamento:** apesar de `HOME`/`XDG`/`APPDATA`/`USERPROFILE` descartáveis, `%USERPROFILE%\.config\opencode\opencode.json` foi sobrescrito (33278 → 390 bytes, config sintética). A hipótese de resolução de caminho canônico no Windows não se sustenta: a escrita no arquivo real (`mtime` `2026-11-18T01:39:18.9165Z`) ocorreu 2 ms depois da escrita da config sintética no temp (`2026-11-18T01:39:18.9140Z`); conteúdo igual (390 B, hash `61504E2C…4351E`), mas `mtimes` distintos, sem hardlink/junção. O primeiro `opencode serve` só aparece nos logs às `01:42:30Z`, cerca de 3 minutos depois, e não há `config.update`/`PATCH /config` nem acesso a `~\.config` no log. Logo, a gravação foi provavelmente feita pelo script de preparação do ensaio, não pelo CLI. **A causa não foi comprovada definitivamente**, pois o script de preparação não foi preservado. O arquivo foi restaurado de backup e verificado independentemente com hash idêntico ao baseline pré-teste `6EAFD1DF3FF5F231F8886A31D400309F689A314BD3B56C3E565FE53597776D97` (33278 bytes). Nenhum outro arquivo foi alterado; o arquivo corrompido foi preservado apenas como evidência temporária. Nenhuma credencial real foi usada e nenhuma sessão foi criada no servidor ativo.

### Isolamento de config no Windows — diagnóstico e estratégia

O código usa `os.homedir()` como base; `XDG_CONFIG_HOME || join(home, ".config")`; `config = join(xdg, "opencode")`; e `tmp = join(os.tmpdir(), "opencode")`. `HOME` não entra nesse cálculo. `OPENCODE_TEST_HOME` controla `Path.home`; `OPENCODE_CONFIG_DIR`/`OPENCODE_CONFIG_CONTENT` são overrides de carregamento, enquanto `Global.Path.config` (XDG) continua presente em `directories()`. `debug paths` imprime `Global.Path` e pode divergir do config efetivo do serviço. Diretórios XDG são criados no carregamento do módulo.

**Veredito: `ISOLATION_DESIGN_READY`** — proposta fundamentada, **não validada por execução**.

Receita mínima proposta (não executada):
- Gatear por hash o perfil real antes e depois do ensaio.
- Definir todas as variáveis no processo filho: `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `OPENCODE_TEST_HOME`, `TEMP`/`TMP` e `OPENCODE_CONFIG_CONTENT` ou `OPENCODE_CONFIG`/`OPENCODE_CONFIG_DIR` dentro da base efêmera.
- Fazer o script de preparação nunca usar `$env:USERPROFILE`/`$HOME` para construir destinos e validar que os destinos ficam sob a base temporária.
- Considerar WSL/distro dedicada para isolamento forte.

Risco residual: os XDG são lidos no carregamento do módulo; overrides parciais não bastam; a autoria exata da sobrescrita não foi comprovada.

**Lição/gate para futuros ensaios:** exigir confirmação por hash de que nada fora do diretório temporário foi escrito antes de aceitar `POLICY_VERIFIED`; usar sandbox/contêiner ou override de configuração confirmado; empregar comandos que casem exatamente os padrões; observar eventos `/api/session/{id}/permission*` para distinguir `ask` de `allow`/`deny`, sem inferir o resultado a partir de HTTP 204.

Issue #141 foi atualizada com estes resultados. O HOLD da retomada foi preservado e está fora desta prova.

## Encerramento e pendências

`AUTH_VERIFIED` atingido; `POLICY_VERIFIED` não comprovado; `ACTIVE_RUNTIME_VERIFIED`/ambiente ativo permanece `BLOCKED_RUNTIME_PROOF`; configuração ativa restaurada e verificada. HOLD para retomada automática aceito como parte do objetivo. Nenhuma nova prova de permissões foi executada nesta investigação. Nenhuma correção de código aplicada: não houve defeito reproduzível.

Issue #141 atualizada com estes resultados; issue #193 referenciada para as condições de reavaliação da retomada. Sem novas issues.

Pendências: comprovar allow/ask/deny em ensaio isolado, com comandos que casem exatamente os padrões, observação dos eventos de permissão e verificação por hash de que nada fora do temporário foi escrito. A atualização do plugin 2.0.28 para 2.3.0 e a regra SSH continuam decisões do operador.
