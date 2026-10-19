# Jev: as duas vias de credencial (P1-02 slice 3)

Uma pagina, so nomes de variaveis — nenhum valor, nenhuma URL, nenhum
segredo. Sem mudanca de policy, flags ou codigo.

## Via A — host-side (MCP nativo, consultivo)

- Onde: config viva do operador + `source/registry/mcp-profiles.json`
  (entrada `jev`), consumida pelo healthcheck
  (`scripts/v3/capability-healthcheck.ps1`).
- Nome da variavel: `OPENCODE_ZEN_API_KEY`.
- Ausencia: o healthcheck marca `jev` como nao-configurado (MISS) na
  maquina; nenhuma consulta Jev e feita por essa via. Nao bloqueia a
  tarefa; o Planner segue deterministico.
- Escopo: ferramenta auxiliar de pesquisa/contexto para
  researcher/architect/engineering-advisor; nunca autoridade, nunca
  altera grants, flags ou policy.

## Via B — kernel-side (advisory envelope, fail-closed)

- Onde: `scripts/v3/lib/OrchestrationJevAdvisory.ps1` + policy
  `source/registry/jev-advisory-policy.json` (nomes apenas) e flag
  `jev_advisory` (born OFF, shadow registra would-consult sem chamar).
- Nomes das variaveis: `JEV_API_KEY` (credencial), `JEV_BASE_URL`
  (transporte, https; http so em loopback), `JEV_MODEL` (opcional,
  default `jev-latest`).
- Ausencias e erros (tokens deterministicos, nunca excecao na fronteira):
  - `JEV_API_KEY` ausente/vazia => `JEV_UNAVAILABLE`
    (fallback deterministico, `fallback_continue=true`, nao bloqueia).
  - `JEV_API_KEY` com caractere de controle => `JEV_AUTH_INVALID`.
  - `JEV_BASE_URL` ausente/vazia => `JEV_TRANSPORT_NOT_CONFIGURED`
    (`error_kind=base-url-absent`).
  - `JEV_BASE_URL` invalida/nao-absoluta/nao-http(s) => mesmo status com
    `error_kind=base-url-invalid`; http remoto (nao-loopback) =>
    `error_kind=http-remote-rejected`.
  - `JEV_MODEL` com caractere de controle => `error_kind=model-invalid`.
  - Policy ausente/divergente => `JEV_POLICY_INVALID` (fail-closed, sem
    defaults silenciosos).
- Em todos os casos de indisponibilidade, o kernel aplica fallback
  deterministico e a tarefa continua sem Jev.

## Regra pratica

Sem `OPENCODE_ZEN_API_KEY`, sem Jev via MCP host-side. Sem
`JEV_API_KEY`/`JEV_BASE_URL`, sem Jev via kernel-side (sempre
`JEV_UNAVAILABLE`/`JEV_TRANSPORT_NOT_CONFIGURED`). As duas vias sao
independentes; nenhuma e requisito do `engineering-advisor`
(ver `docs/jev-advisory-trigger-matrix.md`, lacuna L2).
