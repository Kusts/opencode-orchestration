# M4/M5 — Virtualização, cache, review ancorado e reparo local

**Data:** 2026-11-10
**HEAD:** `54a9d3c` + alterações locais desta rodada
**Runtime de teste:** Windows PowerShell 5.1, sem rede e sem modelo.

## M4 #12 — Observation Virtualization

`scripts/v3/lib/OrchestrationObservationVirtualization.ps1`:

- store content-addressed por SHA-256 (`<store>/<kind>/<sha>.txt`);
- escrita atômica (temp + move) e idempotente (mesmo hash não recria);
- `ArtifactRef` com `artifact_id`, `sha256`, `bytes`, `kind`, `task_id`, `path`;
- preview limitado (`PreviewChars`) com `truncated` explícito;
- recall verifica o hash antes de devolver; recusa arquivo ausente, adulterado,
  acima do limite, kind inválido e path fora do store.

Testes: `OrchestrationObservationVirtualization.tests.ps1` — 18/18 PASS
(round-trip UTF-8, truncamento, idempotência, tamper, path escape, size cap).

Limite: a lib ainda não foi ligada ao `EvidenceStore` do Kernel; é uma camada
de virtualização reutilizável, não uma segunda autoridade de estado.

## M4 #11 — Cache-aware metrics

`scripts/v3/lib/OrchestrationCacheMetrics.ps1`:

- lê `tokens.input/output/reasoning/cache.read/cache.write` e `cost` de uma
  observação de sessão (objeto ou JSON, com/sem wrapper `data`);
- `prompt_tokens = input`, `cache_read_ratio = read/(input+read)` com
  denominador zero → `UNKNOWN`;
- custo ausente ou zero → `UNKNOWN` (`cost_source=unknown`), nunca zero
  inventado;
- falha fechada para JSON inválido, tokens ausentes e input ausente.

Testes: `OrchestrationCacheMetrics.tests.ps1` — 18/18 PASS.

Limite: mede a observação; a preservação de prefixo estável e a comparação
antes/depois de uma mudança de prompt ainda não foram exercitadas.

## M5 #200 — Review ancorado

`scripts/v3/lib/OrchestrationReviewAnchor.ps1`:

- `New-OrchestrationReviewFinding` valida path relativo, commit e severidade,
  calcula `anchor = sha256(file|line|commit)` e (opcional) `file_sha256`;
- `Test-OrchestrationReviewAnchorCurrent` devolve `CURRENT`, `DRIFT_COMMIT`,
  `DRIFT_FILE_MISSING` ou `DRIFT_CONTENT`;
- `Resolve-OrchestrationReviewOwner` mapeia path para frontend/backend/db/
  infra/docs com fallback `coder` (hint de roteamento, não autoridade).

Testes: `OrchestrationReviewAnchor.tests.ps1` — 18/18 PASS.

Limite: o reviewer ainda não emite esse schema por padrão; o wiring no
`record-result`/dispatch é o próximo passo.

## M5 #103 — Reparo localizado

`scripts/v3/lib/OrchestrationLocalizedRepair.ps1`:

- `LOCAL_REPAIR` somente para finding localizado, mesma Task, escopo
  sobreposto, evidência atual, severidade não crítica e <2 tentativas;
- efeito externo ambíguo, evidência obsoleta, falha estrutural/desconhecida,
  escopo amplo ou orçamento esgotado → `REPLAN`/`ESCALATE`;
- nunca repete efeito externo ambíguo nem inicia terceira tentativa cega.

Testes: `OrchestrationLocalizedRepair.tests.ps1` — 13/13 PASS.

Limite: é uma decisão consultiva; o Kernel/Planner ainda não a consulta no
caminho de retry real.

## Resultado

As quatro fatias são código local, determinístico e testado. Nenhuma delas
altera flags, permissões, credenciais, produção ou o estado de issues. O
próximo passo é o wiring no Kernel/Planner, que exige decisão de integração —
não criar um segundo controlador.
