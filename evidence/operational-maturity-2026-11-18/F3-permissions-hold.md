# F3 — certificação de permissões: HOLD

**Data:** 2026-11-18  
**Plano:** `docs/plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md`  
**Resultado:** HOLD. A prova não certifica permissões no runtime.

## Entrega e prova read-only

Implementados `scripts/v3/certify-permissions-runtime.ps1` (CLI `Plan|Run`),
`scripts/v3/lib/PermissionRuntimeCertification.ps1` e
`scripts/v3/certify-permissions-runtime.tests.ps1`.

`Plan` prepara fixture V2 em TEMP, regras exatas e tokens únicos, usa o pin
2.3.0 e apresenta três comandos de prova. Não inicia servidor e não inclui
segredos no JSON. Testes focados: **8/8 PASS**, cobrindo isolamento, serviço
ativo, senha antes do warmup, Verify/exit, diretório de sessão e ask sem
evento. `git diff --check` limpo.

## Execução controlada e resultado

A revisão de segurança final foi **APPROVED** para execução controlada com
opt-in, mantendo como residual o estado de serviço global (H1 parcial) e a
exigência de verificar o serviço real antes. O serviço em `127.0.0.1:4096`
estava ativo e foi preservado.

Com `F3_PERMISSION_RUN_OPT_IN=1`, `Run` abortou em `F3_VERSION_MISMATCH`:
pin 2.3.0 versus binário instalado 2.3.2. A falha ocorreu antes de
`service set port`/start. JSON: `<TEMP>/f3-run-controlled.json`;
`ACTIVE_PATHS_UNCHANGED`; exit 1; `cases=[]`, `endpoints=[]`. Nenhuma sessão
foi criada e nenhum comando de permissão foi executado.

## Justificativa do HOLD e limites

O runtime exato do pin não estava disponível e o repositório não consumiu
nenhum endpoint de evento de permissão; resposta HTTP 204 não é evidência de
evento. Portanto, F3 permanece **HOLD**, sem alterar o pin de runtime (isso
exige decisão formal).

Limitações: `/shell` não equivale a permissão interativa de ferramenta;
precedência/composição de regras não certificadas; divergência entre pin 2.3.0
e runtime 2.3.2; serviço real preservado e não alterado.

## Evidências relacionadas

- F1: `evidence/operational-maturity-2026-11-18/F1-guardrail.md`
- F2: `evidence/operational-maturity-2026-11-18/F2-installer-certification.md`
- F4: `evidence/operational-maturity-2026-11-18/F4-post-merge.md`
- Plano: `docs/plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md`

## Atualização: execução real no runtime 2.3.0

O runtime 2.3.0 foi provisionado em HOME/perfil temporário, sem tocar no
2.3.2 do operador; wrapper `.cmd` fez o harness enxergar a versão correta.
Correções: gate aceita `stopped` com exit 0 antes e depois; `$result=$plan`
deixou de compartilhar hashtable; autenticação lê `service.json` do XDG
isolado com senha redigida; HTTP 204 é sucesso; endpoints de
permissão/evento são consultados após `/shell`.

Testes focados: **34/34**; `-Mode Plan` PASS; `git diff --check` limpo.
Na execução real, `/openapi.json` retornou HTTP 200, 3 sessões foram criadas
e `/shell` retornou HTTP 204. Endpoints descobertos:
`/api/permission/request`, `/api/permission/saved`,
`/api/session/{sessionID}/permission`,
`/api/session/{sessionID}/permission/{requestID}`, `.../reply` e
`/api/event`. `permission_events=[]` nos três casos; allow/ask/deny
classificados HOLD por ausência de evento de decisão. Senha redigida; serviço
owned iniciado/parado em porta efêmera; `ACTIVE_PATHS_UNCHANGED`; exit 0.
JSON resumido em
`<TEMP>/f3-run-230g.json` (não versionado).

**Conclusão atual:** F3 permanece HOLD com evidência definitiva: a API
`/shell` não emite evento de decisão de permissão observável neste runtime.
HTTP 204 não prova decisão. Compatibilidade com 2.3.2 segue não certificada;
nenhum pin foi alterado.
