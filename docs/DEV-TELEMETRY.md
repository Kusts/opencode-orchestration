# DEV-TELEMETRY

Telemetria local de desenvolvimento, agregada e explicita. Nada sai da maquina:
nao ha rede, OTEL, SQLite nem envio automatico. A publicacao em
`evidence/dev-telemetry` e manual (`-Publish`) para nao sujar a arvore em CI.

## O que NAO e armazenado

Nunca persista nestes eventos:

- prompts, transcricoes, conteudo de arquivo, saida de modelo;
- caminhos de arquivo, linhas de log, URLs, comandos;
- segredos (tokens, chaves, senhas, `sk-*`, `ghp_*`, `AKIA*`, Bearer, JWT).

O schema v1 so aceita tokens curtos por allowlist (`^[A-Za-z0-9][...]$`,
sem espaco, sem barra, sem conteudo livre). Campos fora do formato sao
descartados; valores com cara de segredo sao recusados; a escrita ainda
rejeita a linha se o JSON final contiver padrao de segredo.

## Camadas

1. Raw local (automatico, 30 dias):
   `cache/v3/telemetry/dev/dev-YYYYMMDD.jsonl` -- 1 linha JSON compacta por
   evento, append com lock sem espera (contencao => retorno imediato
   `$false`, sem retry/sleep), confinado ao diretorio permitido, recusa
   reparse point. Retencao automatica no maximo 1x/dia via marcador
   `cache/v3/telemetry/dev/.retention-YYYYMMDD` (data UTC): o primeiro
   `Write-DevTelemetryEvent` do dia roda `Invoke-DevTelemetryRetention`
   (30d) e cria o marcador vazio so apos sucesso confirmado (retorno nao-nulo e campo Error vazio); se Error nao vazio ou contrato inesperado, nao marca e tenta de novo no proximo write (retorna $false); fail-open, nunca lanca.
   O export tambem roda a retencao via `Invoke-DevTelemetryRetentionIfDue` (1x/dia), nunca direto. `cache/` e gitignored: nunca e
   commitado.
2. Publicada (explicita, versionada):
   `evidence/dev-telemetry/latest.json` + `latest.md` e
   `evidence/dev-telemetry/history/YYYY-Www.json` (semana ISO) -- somente
   quando alguem roda com `-Publish`. Cada destino e validado antes da
   escrita (ancestrais ate o repo sem reparse, destino existente nao e
   reparse nem container, caminho canonico dentro do diretorio
   permitido), escrito em arquivo temporario no mesmo diretorio
    (`.<nome>.<guid>.tmp`) e efetivado com `[IO.File]::Replace(tmp, dest, backup)` quando o destino existe (backup `.<nome>.<guid>.bak` no mesmo diretorio, removido apos o sucesso) ou `[IO.File]::Move(tmp, dest)` quando nao existe -- nunca `WriteAllText` direto nem `Move-Item -Force`.
    Temp (`.<nome>.<guid>.tmp`) e backup (`.<nome>.<guid>.bak`) seguem o mesmo confinamento e checagem de reparse.
   O que tambem mitiga hardlink (substitui a entrada em vez de escrever atraves dela). Recusa/falha (inclusive destino travado) => remove temp/backup e retorna `$false` sem tocar no destino (conteudo antigo intacto).
   Corrida delete-entre-checagem-e-replace: se `Replace` lancar `FileNotFoundException` e o destino sumiu, tenta `Move` UMA vez; nunca cai para `Move-Item -Force`.
   Allowlist do
   `.gitignore` cobre `evidence/dev-telemetry/` para que o resto de
   `evidence/*` continue ignorado.

## Como rodar

```powershell
powershell -NoProfile -File scripts/dev-telemetry-report.ps1
powershell -NoProfile -File scripts/dev-telemetry-report.ps1 -Publish
pwsh -NoProfile -File scripts/dev-telemetry-report.ps1 -Publish
```

Saida: exatamente uma linha
`dev-telemetry: events=N suites=R pass=P fail=F publish=on|off`, exit 0
(exit 2 so para argumento invalido).

## Registrar review outcome

O sinal de review nao e automatico: o Planner registra ao encerrar.

```powershell
powershell -NoProfile -File scripts/dev-telemetry-record.ps1 -Verdict APPROVED
powershell -NoProfile -File scripts/dev-telemetry-record.ps1 -Verdict CHANGES_REQUIRED -Detail reviewer-findings
powershell -NoProfile -File scripts/dev-telemetry-record.ps1 -Verdict CHANGES_REQUIRED -Severity HIGH -Source security-reviewer
```

`Severity` e opcional: `NONE|LOW|MEDIUM|HIGH|CRITICAL` (trim + uppercase).
Valor invalido => exit 2, uma linha de saida, nenhum evento. No sucesso, a
linha inclui ` severity=<VALOR>` quando informado. O agregado expoe
`review.total/approved/changes_required`, `by_source` e `by_severity` (contagens
ordenadas deterministicamente), alem de `high_or_critical`. Eventos antigos ou
sem severity contam como `UNSPECIFIED`.

## Ganchos automaticos

Todos os ganchos sao try/catch silenciosos: se a lib nao carregar, o script
original segue normalmente, sem mudar stdout nem exit code.

- `scripts/v3/run-v3-tests.ps1`: 1 evento `suite_result` por suite
  (`-Source run-v3-tests`, `-Engine ps51`).
- `tests/distribution/run-distribution-tests.ps1`: 1 evento `suite_result`
  por suite (`-Source distribution`, engine do filho: powershell=>ps51,
  pwsh=>ps7).
- `scripts/test-package-consistency.ps1`: 1 evento `gate_result`
  (`-Source package-consistency`, verdict PASS/FAIL, counts
  pass/fail/total=16).
- `scripts/v3/orchestration-preflight.ps1`: 1 evento `preflight_decision`
  por decisao (decision/task_class/risk/agents/fallback_reason,
  verdict UNKNOWN; no catch, DETERMINISTIC_FALLBACK +
  preflight_internal_error).
- `scripts/ci/plugin-healthcheck.ps1`: 1 evento `plugin_health`
  (metrics load_errors/expected_load_errors/telemetry_present/
  plugins_present).

## Schema v1 (resumo)

Campos: `schema=1`, `timestamp` (UTC ISO `o`), `kind`, `source`, `suite`,
`verdict`, `severity` (opcional: `NONE|LOW|MEDIUM|HIGH|CRITICAL`), `exit_code`, `duration_ms`, `counts`, `metrics`, `decision`,
`task_class`, `risk`, `agents` (max 8), `fallback_reason`, `engine`,
`detail`. So campos presentes/validos sao emitidos.

- kinds: `suite_result`, `gate_result`, `preflight_decision`,
  `plugin_health`, `review_outcome`.
- verdicts: `PASS|FAIL|SKIP|ERROR|APPROVED|CHANGES_REQUIRED|UNKNOWN`.
- suite: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`.
- source/decision/task_class/risk/fallback_reason/detail:
  `^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`.
- agents: `^[a-z0-9][a-z0-9._-]{0,63}$` (max 8).
- engine: `ps51|ps7|unknown`.
- counts: ate 8 chaves `^[a-z][a-z0-9_]{0,31}$`, int 0..1000000 (clamp).
- metrics: ate 8 chaves idem, int (clamp) ou bool.
- kind/source invalidos => evento nulo (nada e escrito).

Leitura (`Read-DevTelemetryEvents`) normaliza tudo: exige `schema -eq 1`
(linhas `schema:0` ou sem schema sao ignoradas) e reconstrui cada evento
via `New-DevTelemetryEvent` mapeando os campos snake_case
(`kind,source,suite,verdict,exit_code,duration_ms,counts,metrics,decision,
task_class,risk,agents,fallback_reason,engine,detail,timestamp`); so o
objeto normalizado entra nos agregados. Timestamp invalido, ausente ou vazio => linha descartada ANTES da normalizacao (validado com `[DateTimeOffset]::TryParse` no valor cru; o valor validado e reutilizado no cutoff -- nunca cai no fallback `UtcNow` da normalizacao). Qualquer campo invalido (suite com
caminho, detail com segredo, kind/source fora da allowlist) e descartado
na leitura -- o JSONL cru nunca vaza para `latest.json`/`latest.md`.

Agregacao (`New-DevTelemetrySnapshot`, funcao pura): raw (events/files/
first_ts/last_ts), totals (suite_runs/pass/fail/skip/error/pass_rate),
suites[] (runs/pass/fail/skip/error/pass_rate/p50_ms/p95_ms por
nearest-rank/flaky_transitions), flaky[] (transicao FAIL/ERROR->PASS em
ordem temporal), slowest[] (top 5 por p95_ms), preflight
(total/by_decision/fallback_rate/by_task_class/by_risk/agents), plugin
(reports/latest_*), review (total/approved/changes_required/by_source/by_severity/high_or_critical), gates
(reports/pass/fail/checks_total/checks_fail). `pass_rate` (totals e por
suite) = `pass / (pass + fail + error)`: SKIP nao entra no denominador e e
reportado separadamente em `skip`; denominador 0 => 0.0.

## Limites

- Sem OTEL/rede/SQLite; sem execucao ao carregar (dot-sourceable);
  nenhuma funcao escreve em stdout nem altera exit code.
- Leitura limitada: no maximo 31 arquivos `dev-*.jsonl`, sempre via
  `FileStream` com buffer maximo de 4 MB por arquivo (loop de `Read` ate
  EOF ou o limite, sem branch `ReadAllText`), linhas invalidas ou alem do
  cap ignoradas sem excecao. Se o buffer atingiu o cap sem alcancar o EOF (`$total -ge $cap` e `$fs.Position -lt $fs.Length`), a cauda parcial e cortada no ultimo byte LF (10) antes do decode UTF-8; se nao houver LF no buffer, o buffer inteiro e descartado. Linha final sem newline com EOF real continua aceita quando completa.
- Publicacao e explicita (`-Publish`) justamente para nao sujar a arvore
  em CI: o agregado versionado so aparece em `evidence/` quando alguem
  decide publicar.
- Determinismo: `Read-DevTelemetryEvents` aceita `-Now` (default `UtcNow`) para o cutoff; `Export-DevTelemetrySnapshot` resolve o instante uma vez (`$gen`) e passa o mesmo valor para a leitura e para o nome do historico -- dois exports com o mesmo `-Now` e os mesmos eventos geram JSON byte-a-byte identico (`generated_at` fixo).
- Residuais honestos: JSON+MD nao sao transacao conjunta (cada destino e atomico, mas o conjunto pode ficar parcial se o processo morrer no meio); hardlink/TOCTOU de ancestrais entre a checagem de reparse e a escrita; crash do processo entre o temp e o `Replace` pode deixar `.<nome>.*.tmp`/`.bak` orfaos (detectaveis pelo padrao; em falha sem crash o temp/backup sao limpos e o destino antigo permanece intacto).
