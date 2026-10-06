# Decisões machine-only e itens fora do repo — Fase 2A

Nota de escopo: este documento **registra decisões** sobre itens
machine-side/machine-only e itens ausentes no repositório. Ele não altera
nenhum template, agent, pin, flag ou registry. Em divergência, `source/`
vence (ver `ARCHITECTURE.md`). Contratos vivos em
`docs/capability-planning-v2.md`; validação em
`scripts/test-package-consistency.ps1` e nas suites
`tests/distribution/capability-planning.tests.ps1` (fatia 1, planning) e
`tests/distribution/capability-registry-v2.tests.ps1` (fatia 2, registry).

Status de cada item: `NOT-APPLICABLE` (ausente no repo, sem ação),
`REMOVED/DEPRECATED` (padrão antigo sem execução, sem ação além do registro),
`KEEP` (mantido como está) ou decisão explícita do operador.

## 1. `service.json`: machine-only

O arquivo `service.json` (configuração de serviço local da máquina) é
**machine-only**: vive fora do repositório versionado e jamais é commitado
aqui. Decisões registradas:

- **Segredos migram para variáveis de ambiente + rotação.** Nenhum valor de
  segredo entra em Git, instruções geradas, logs, relatórios ou telemetria.
  A criação, revogação ou rotação de credenciais exige confirmação separada
  do operador; nenhuma automação amplia escopo de credencial por inferência.
- **Healthcheck relata apenas `configured: true/false`, nunca o valor.**
  A presença/ausência de uma variável sensível pode ser observada como
  booleano (ex. `scripts/v3/capability-healthcheck.ps1 -Json`); o conteúdo
  jamais aparece no output (assert anti-vazamento na suite da fatia 2 cobre
  `AI_MEMORY_AUTH_TOKEN`, `JEV_API_KEY`/`JEV_BASE_URL` por nome, sem
  imprimir valores). Nota de contrato duplo (2026-10-06): o transporte MCP
  machine-side usa `AI_MEMORY_AUTH_TOKEN` (verificado em
  `opencode.json:mcp.ai-memory`), enquanto a policy kernel-side
  (`ai-memory-remote-policy.json` + `OrchestrationAiMemoryRemote.ps1`)
  nomeia `AIMEMORY_REMOTE_TOKEN` — contratos distintos, sem unificação
  nesta fase; o probe do registry V2 cobre o transporte MCP.

## 2. `tui.json`: ausente no repo = NOT-APPLICABLE

Não existe `tui.json` versionado neste repositório. Qualquer configuração de
TUI é **machine-side** (perfil local do operador). Status:
**NOT-APPLICABLE** — nenhuma ação no repo, nenhuma suite cobre esse arquivo.
Decisões sobre TUI, quando existirem, são do lado da máquina.

## 3. Orca: machine-only, sem integração no repo

Orca (runtime/ferramentas machine-side) não tem integração versionada neste
repositório: nenhum template, agent, plugin ou script depende dele. Status:
**sem ação no repo**. Manter ou desabilitar componentes Orca na máquina é
**decisão explícita do operador** (`KEEP`/`DISABLE` machine-side); este
pacote não escreve, remove nem configura nada do Orca.

## 4. Herdr: só pattern regex, sem execução = REMOVED/DEPRECATED

O repositório contém apenas um **padrão de reconhecimento** (regex/nome)
para `herdr`, sem nenhum caminho de execução, dispatch ou permissão que o
ative. Status: **REMOVED/DEPRECATED no repo** — o padrão existe só para
classificação/observação, não concede capacidade. Nenhuma suite atesta
execução via herdr; qualquer ativação real seria mudança de autoridade
futura, fora da Fase 2A.

## 5. R1–R7: ausentes no repo = NOT-APPLICABLE

Os itens R1–R7 (referências externas de um plano machine-side) **não têm
correspondente versionado** neste repositório: nenhum arquivo, flag ou
registry os implementa aqui. Status: **NOT-APPLICABLE** — nada a arquivar,
migrar ou testar no repo. Se um dia um item R* for proposto para o pacote,
entra pelo fluxo normal (registry + evidência + decisão humana), nunca por
inferência deste registro.

## 6. Pins mantidos: 2.0.23 / 1.18.34

Fonte única: `source/registry/runtime-versions.json` (loader fail-closed,
sem fallback para literal).

- **Pins em vigor (KEEP):** V2 `@opencode/cli@2.0.23` (+ plugin
  `@opencode/plugin@2.0.23`) e V1 `opencode-ai@1.18.34`
  (+ `@opencode-ai/plugin@1.18.34`); `bun@1.3.14`.
- **Drift documentado:** a existência de `2.0.24` no mundo externo é drift
  conhecido e **não** implica bump automático. Bump de pin = editar somente
  `source/registry/runtime-versions.json` **após** smoke/validação no
  runtime exato + decisão humana com evidência (política de flags
  conservadoras: flags nascem OFF/shadow). Até lá, os pins acima permanecem.

## 7. `OPENCODE_CONFIG_CONTENT`: detecção documentada

Status neste pacote: **unsupported e unproven** (detalhe em
`docs/capability-planning-v2.md`, seção 4). Regra de package policy
registrada aqui como decisão:

- Antes de qualquer verificação que ateste "config gerenciado íntegro",
  checar `$env:OPENCODE_CONFIG_CONTENT`.
- Se **não-vazio**: resultado máximo honesto `unproven/blocked` —
  registrar `config_source=env-override`, não atestar integridade, devolver
  ao operador. Qual entrada prevalece é decisão do runtime real, fora do
  escopo verificado aqui.
- Se **ausente/vazio**: vale o caminho normal em disco (manifest + CAS +
  checks de consistência).
