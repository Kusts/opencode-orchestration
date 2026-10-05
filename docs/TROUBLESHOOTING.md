# Troubleshooting

## Programa Phases 21-42 (revisão 2026-10-01, reconciliada em 2026-10-05) (runtime reliability - P21-P25 consolidadas, P26-P42 code-complete kernel-side/plugin; flags de rollout ativas desde 2026-10-04; release gate pendente do operador)

Estado vivo em
`evidence/v3.1/runtime-reliability/program-status.json`; flags em
`source/registry/capability-flags.json`; pins em
`source/registry/runtime-versions.json`. O que já tem diagnóstico real
(P21–P22) e o que segue manual:

- **V2 trava no startup / timeout opaco do serviço (Windows)**: causa
  provável é colisão de porta — o serviço gerenciado V2 usa por padrão
  `127.0.0.1:49374`, **mesma porta do serviço de fundo do próprio V2 CLI**
  (`opencode.exe serve --service` do npm global, respawnado a cada
  sessão/restart). **Identidade corrigida em 2026-10-03: `49374` NÃO é
  AI Memory** — o AI Memory do operador roda remoto (PROD); o registro
  original de P21 (listener Docker + clientes `cloudflared`/opencode V1)
  permanece em `baseline.json` como histórico. O processo local nunca é
  mutado por aqui. Diagnóstico determinístico disponível (P22):
  `scripts/runtime/RuntimePortPreflight.ps1` — outcomes `PORT_FREE`,
  `PORT_OCCUPIED_*`, `PORT_WINDOWS_EXCLUDED`, etc.; exit **0** =
  `PORT_FREE` (start autorizado), **2** = fail-closed, **1** = erro de
  uso. Nunca mate um PID desconhecido automaticamente.
- **Wrapper V2 com startup condicionado (P22)**: o wrapper só inicia o
  serviço com `-ServicePort` explícito + configuração verificada
  (`get` + `service.json` iguais ao desejado) + preflight `PORT_FREE`;
  sem isso, bloqueia com exit 2 (`PORT_CONFIGURATION_UNVERIFIED`).
  `service set/stop/restart` brutos nunca são encaminhados (só via
  helper protegido com prova de empty-state). `REUSE` de porta segue
  em HOLD — porta ocupada, mesmo pelo serviço esperado, não autoriza
  reaproveitamento automático (nenhum claim OWNED é emitido).
- **Ranges de porta excluídos/reservados do Windows**: a preflight
  cobre o caso (`PORT_WINDOWS_EXCLUDED`); escolha outra porta livre
  fora do range (o fluxo provado usa `opencode service set port
  <porta>` + recheck, como no E2E nativo em perfil isolado).
- **Child/worker travado sem retorno (retry budget nunca consome)**:
  o kernel só escala após falha retornada, mas o caminho de interrupção
  real existe e está **ativo**: RuntimeWatchdog (P25) + enforcement do
  P26 (identidade exata `pid`+creation-ticks, prova de vida, kill pelo
  handle pinado, árvore CIM com caps fail-closed, seam
  `SETTLEMENT_REQUIRED`), flag `watchdog` ativada pelo operador em
  2026-10-04 e backstop de Job Object ligado ao enforcement em
  2026-10-05 (attach da raiz verificada antes do snapshot +
  `TerminateJobObject` depois do kill CIM) — evidência real 7/7
  `pass-real` em `evidence/v3.1/runtime-reliability/v2-lane-2026-10-04/`,
  local e **no runner** (run `37376248759`, 2026-10-05).
  HOLDs honestos que restam: janela gate→`TerminateJobObject` nativo,
  preempção entre checagem e chamada, descendentes pré-attach cobertos
  só pelo kill CIM, e
  `WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED` para registro **sem binding de
  processo provado** (identidade/ownership não prováveis ⇒ recusa, nunca
  kill de PID desconhecido). Se o kernel recusar o settlement, interrompa
  manualmente e re-despache com escopo reduzido/estratégia nova;
  preserve evidência parcial à mão.
- **Orçamentos**: os budgets canônicos (5 perfis) estão registrados e
  validados (P23, record-only) e a flag `bounded_execution` foi ativada
  em 2026-10-04 — mas o `ExecutionBudget` **continua devolvendo
  `enforce=false`**: não alegue enforcement de budget. Os limites
  efetivos hoje vêm do watchdog/kernel (deadline compartilhado,
  interrupt); estouro de budget ainda exige tratamento manual.
- **MCP indisponível prende a orquestração em retries**: resolvido no
  kernel (P28-S1: envelope bounded + circuit breaker por
  `(server, capability, turn)`, 2 falhas abrem o circuito, cooldown
  contado da conclusão, half-open com probe único; `optional` ⇒
  `MCP_UNAVAILABLE` + `fallback_continue`, `required` ⇒
  `MCP_REQUIRED_BLOCKED` fail-closed). O transporte do plugin segue em
  **shadow default** (observa, não altera admissão sem opt-in explícito)
  e `mcp_routing` permanece OFF. Indisponibilidade de MCP consultivo
  nunca equivale a aprovação.
- **AI Memory remoto indisponível**: o `OrchestrationAiMemoryRemote`
  (P30) trata a dependência como remota — `AIMEMORY_UNCONFIGURED`
  (optional continua, required bloqueia tipado) e **nunca** fallback
  silencioso para o `127.0.0.1:49374` local. O AI Memory PROD do
  operador **já roda em servidor remoto próprio** (deploy executado
  antes de 2026-10-01; config user-owned **confirmada** em 2026-10-04 e
  round-trip remoto autenticado com serviço
  saudável, 97 ms em
  `aimem-health-repreflight-2026-10-04.json`); o que resta nomeado é
  apenas o probe HTTPS dedicado contra o endpoint, separado do
  round-trip MCP; o endpoint é
  **user-owned** e cada operador configura o seu em policy local fora do
  repo. Falha de memória não deve travar trabalho não relacionado —
  siga sem ela quando seguro e registre o blocker.
- **Jev indisponível**: entregue (P29-S1 advisory + P29-S2 transporte
  HTTP real kernel-side), flag `jev_advisory` **ativa** desde 2026-10-04
  e wiring do chamador no Planner loop entregue em 2026-10-05 (P38-S2):
  `JEV_UNAVAILABLE` ⇒ fallback determinístico, sem retry infinito, e o
  resultado é `recommendation_only` (`authoritative=false`). Credencial
  só por nome de env (`JEV_BASE_URL`/`JEV_MODEL`/`JEV_API_KEY`);
  `JEV_BASE_URL` ausente ⇒ `JEV_TRANSPORT_NOT_CONFIGURED` e nenhuma
  chamada de rede. Jev é consultivo e nunca substitui
  verifier/Reviewer/Security Reviewer/DONE do kernel.

## Plugin não carrega

Sintoma: nenhum mandato `[orchestration-enforcement:v1]` na sessão.

1. Dependência ausente é a causa mais comum: confira
   `.config/opencode/node_modules/@opencode-ai/plugin` (V1) ou
   `.config/opencode/node_modules/@opencode/plugin` (V2). Se faltar,
   instale a do seu runtime e reinicie o OpenCode:
   ```powershell
   cd ~/.config/opencode
    # Use o spec do registry canônico de pins (source/registry/runtime-versions.json
    # => plugins.v1.spec / plugins.v2.spec), não um número digitado à mão:
    bun add <plugins.v1.spec>   # runtime V1
    # ou: bun add <plugins.v2.spec> # runtime V2
    # ou: npm install <spec> --prefix ~/.config/opencode
   ```
2. Confira que `.config/opencode/plugins/orchestration-enforcement.js`
   existe (bundle autocontido; é o que o `install.ps1` instala hoje — um
   `.ts` legado é adotado para backup e removido).
3. Reinicie o OpenCode após instalar dependência ou plugin — carrega no boot.

## Provider rejeita o system prompt (prompt muito longo)

O que o plugin faz: injeta **um** mandato curto (Planner, worker ou neutro)
fundido à primeira entrada do system (`system[0]`), com idempotência por
marker (se o marker já está lá, não injeta de novo) e fail-safe silencioso
(input malformado → sem injeção, sem crash). Ele não duplica nem cresce a
cada turno.

Se mesmo assim o provider reclamar de tamanho:

1. Rode com `-NoCoreSkills` na próxima instalação para reduzir skills.
2. Para remover **só o plugin** (mantendo agents e `AGENTS.md`): apague
   `.config/opencode/plugins/orchestration-enforcement.js` e reinicie.
   Sem o plugin, o sistema continua valendo por `AGENTS.md` + preflight —
   você só perde o mandato automático e a telemetria.

## Registry ausente ("registry missing")

Comportamento esperado: **fallback determinístico**. A registry derivada
(`cache/v3/capability-registry.json`) é opt-in; sem ela, o preflight e o
roteamento seguem a política determinística normalmente.

Para gerar (opt-in):

```powershell
powershell -NoProfile -File scripts\v3\build-capability-registry.ps1
```

Flags em `source/registry/capability-flags.json`: **política** = nascem
OFF/shadow e a ativação é decisão humana com evidência (nunca inferência).
Estado atual: **ativas** `runtime_support.v1/v2/dual_profile`,
`task_kernel`, `bounded_execution`, `watchdog`, `jev_advisory`,
`worktree_isolation` (lote do operador em 2026-10-04, evidência em
`evidence/v3.1/runtime-reliability/flag-activation-batch-2026-10-04.json`);
**OFF** `capability_router.shadow/active`, `skill_routing`, `mcp_routing`,
`adaptive_ranking`, `routing_telemetry`, `capability_reconciler` e
`runtime_grant_enforcement{v1,v2}` (Phase 5 — nenhum hard-deny antes da
validação comportamental no runtime V2 real). Roteamento assistido e
MCP genérico seguem desligados.

## models.jsonc inválido

O `install.ps1` aborta no precheck com **exit 3** e mensagem do motivo,
sem escrever nada. Causas comuns:

- Arquivo ausente (copie de `models.example.jsonc` — o instalador não
  cria sozinho de propósito).
- JSONC que não parseia (vírgula, chave ou comentário malformado).
- Chave `planner`, `cheap` ou `strong` ausente ou vazia.

Corrija, rode `.\install.ps1 -WhatIf` e depois `.\install.ps1`.

## OpenCode atualizou — e agora?

Política de suporte: as linhas **OpenCode V1.x** (pacote npm
`opencode-ai`) e **OpenCode V2** (pacote `@opencode/cli`) são suportadas
(programa V3.1). Os pins exatos que o CI instala e as suítes exigem estão
no **registry canônico** `source/registry/runtime-versions.json` (leia
`runtimes.v1.spec` / `runtimes.v2.spec`; loader fail-closed
`scripts/runtime/lib/RuntimeVersions.ps1`) — não fixe números neste doc:
o bump de pin é edição de um arquivo + revalidação no runtime exato.
(Números antigos citados em notas datadas — `1.18.32`/`2.0.18` — são
histórico da evidência em que apareceram.)
O `install.ps1 -Runtime Auto` detecta a geração pelo probe; explícito
(`-Runtime V1`/`-Runtime V2`) sempre vence. Uma versão **mais nova e ainda
não testada** de qualquer linha pode ser "esperadamente compatível", mas
só vira "validada" depois de smoke/suítes verdes — nesse meio tempo,
reinstale e revalide.

Colisão de gerações no `PATH` (ambas respondem a `opencode`): confira qual
responde —

```powershell
opencode --version   # 1.x => geração V1; 2.x => geração V2
```

Para as duas lado a lado, **não** compartilhe config: use perfis isolados
(`.\install.ps1 -Runtime Both` ou
`scripts\runtime\new-opencode-profile.ps1`) — cada perfil tem seu próprio
config root e wrapper (`opencode-v1.ps1`/`opencode-v2.ps1`).

Após atualizar o runtime **dentro da linha**, revalide com as suítes:

```powershell
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
```

Tudo verde → compatível. Falha em suite → abra o log da suite indicada
pelo runner antes de reinstalar ou mudar config.

### Falha conhecida: invariante "opencode.json vivo inalterado"

Sintoma: 4 suítes V3 (`CapabilityDeferred`, `CapabilityObservability`,
`CapabilitySkillUtility`, `shadow-route`) falham com
`opencode.json vivo inalterado (prefixo DE22307F)` e um hash obtido
diferente.

Causa: essas suítes protegem um invariante de origem — o `opencode.json`
vivo do control plane deve ser byte-idêntico ao baseline canônico. Se o
config vivo da máquina foi editado fora do `render`/`reconcile` (ou por
outro runtime/instalação), o invariante dispara. **Não é regressão do
pacote** — registre que o mesmo desvio já existia no baseline congelado
(`evidence/v3.1/kernel-hardening/baseline.json`).

Tratamento: reconcilie o config vivo com o canônico
(`scripts\render-opencode-config.ps1` +
`scripts\reconcile-opencode-config.ps1 -Apply`) ou rode as suítes num
checkout/home isolado. As suítes novas do V3.1 (runtime adapters, tradução
de agents, plugin dual, perfis) não dependem desse invariante.

## Rollback necessário

- Instalações guardam backup em `.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/`.
- Falha no apply/manifest faz rollback automático: `ROLLBACK_COMPLETED`
  (tudo restaurado) ou `ROLLBACK_REQUIRED` + lista do que **não** restaurou
  (restaure manualmente a partir do backup).
- `CAS_CONFLICT` (exit 4) significa que o destino mudou entre preview e
  apply — **nada foi aplicado**; inspecione, descarte a mudança externa ou
  rode de novo.
- Uninstalls guardam backup em
  `.config/opencode/backups/oo-uninstall-<yyyyMMdd-HHmmss>/`.

## Conflito com config custom

O merge é ownership-aware: o pacote só escreve caminhos do sistema
(`$schema`, `model`, `default_agent`, `subagent_depth`, `agent.*.mode/
model/permission.task`). Nunca tocados: `mcp.*`, `autoupdate`,
`skills.paths`, `plugin`, agents custom, chaves de topo desconhecidas e
tudo fora dos markers do `AGENTS.md`.

Nota sobre jsonc: se o install avisou que normalizou comentários do seu
`opencode.jsonc`, o original byte-exato está no backup em
`.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/` — restaure manualmente
se preferir manter os comentários (o conteúdo funcional é idêntico).

- No install, o `-WhatIf` mostra `PRESERVE` para cada item seu intocado.
- No uninstall, item alterado por você após o install recebe `KEEP` +
  aviso e **não** é removido. Sem manifest, a heurística é conservadora:
  só sai o reconhecido como do pacote.
