# ADR + Processo — Piloto actions-lock (issue #149)

**Issue:** #149 — piloto de lockfiles (`gh actions-lock`), sem enforcement global.
**Escopo deste documento:** registrar inventário, baseline, validação do lockfile e
processo de review/update/rollback para dev solo. **Sem** silent update, sem
policy global, sem deploy/merge, sem secrets.
**Status:** HOLD — `ci.yml` INALTERADO (SHA preservado nas 6 linhas);
lockfile como artefato observacional; sem enforcement, sem step verify no CI.
Estado entregue difere do plano inicial (que previa conversão para tag):
ver seções 1.1, 5 e 7.1.

## 1. Inventário — actions, refs, permissões, riscos (AC1)

### 1.1 Actions de terceiros

- Único third-party em todo o workflow: `actions/checkout`, 6 ocorrências em
  `.github/workflows/ci.yml` — linhas 106, 120, 187, 254, 294, 341
  (`uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`).
- Estado entregue: `ci.yml` INALTERADO — o pin por SHA com comentário de
  versão foi preservado nas 6 linhas (`git diff` de `ci.yml` = vazio). O
  `gh actions-lock` (ref narrowing default) reescreveria essas linhas para a
  tag `v4.2.2`; essa reescrita foi REVERTIDA. O lockfile
  (`.github/workflows/actions.lock`) foi gerado contra o workflow com pin
  de SHA e é artefato observacional: registra o par ref/commit esperado
  sem alterar o que o runner busca. Comportamento de runtime idêntico ao
  pré-piloto, por construção — ver trade-off na seção 7.
- Demais steps são `run:` locais (scripts do repo, `npm install` de pacotes
  pinados via registry). Política de pinning de pacotes documentada no
  cabeçalho do workflow (`.github/workflows/ci.yml:23-29`): pins vivem em
  `source/registry/runtime-versions.json`, bump = edição do registry +
  revalidação no runtime exato.
- Cabeçalho do workflow declara o invariante
  (`.github/workflows/ci.yml:22`): "Sem segredos. Nenhuma acao de terceiros
  alem de actions/checkout." — confirmado pelo inventário acima.

### 1.2 Refs (estado entregue: SHA preservado + lock observacional)

| Workflow | Ref no `uses:` | Lockfile (`actions.lock`) |
|---|---|---|
| `.github/workflows/ci.yml` (6 jobs) | `actions/checkout@11bd719… # v4.2.2` (SHA, linhas 106, 120, 187, 254, 294, 341 — INALTERADO) | `workflows['.github/workflows/ci.yml'] = ['actions/checkout@v4.2.2']` (`.github/workflows/actions.lock:5-7`) |
| Dependência resolvida | — | `ref: 'v4.2.2'`, `commit: 'sha1-11bd71901bbe5b1630ceea73d27597364c9af683'`, `owner_id: 44036562`, `repo_id: 197814629` (`.github/workflows/actions.lock:9-13`) |
| Formato | — | `version: 'v0.0.3'` (`.github/workflows/actions.lock:4`), gerado por `gh actions-lock` (extensão `github/gh-actions-lock`, cli v0.2.0) |

O runner resolve o SHA imutável do `uses:`; o lockfile apenas registra o
par ref/commit esperado (visibilidade procedural, sem efeito no runtime).
`Do not edit by hand` (`.github/workflows/actions.lock:1-3`): lockfile é
artefato gerado; atualização = rodar `gh actions-lock` (seção 4).

### 1.3 Permissões e trust

- `ci.yml` **não declara** bloco `permissions:` nem `concurrency:` (verificado
  no corpo `jobs:` a partir de `.github/workflows/ci.yml:96` — nenhum dos
  6 jobs define `permissions:`; trust = `GITHUB_TOKEN` default).
- Gates externos: branch protection de `master` exige os 5 checks da
  `docs/github-lifecycle-policy.md:44-50` (`CI (ps51)`, `CI (ps7)`,
  `CI (smoke opencode real)`, `CI (v2 lane, perfil V2 provisionado)`,
  `CI (smoke opencode v2 real)`); o workflow tem 6 jobs
  (`docs/github-lifecycle-policy.md:32-35`), o sexto
  (`CI (linux capability collector)`) é complementar, não gate
  (`docs/github-lifecycle-policy.md:56-58`).
- Segredos: nenhum secret em CI. Declarado em `SECURITY.md:35-37`
  ("CI sem segredos… testes usam canários sintéticos") e no cabeçalho do
  workflow (`.github/workflows/ci.yml:22`).

### 1.4 Riscos (superfície real deste repo)

1. **Sem enforcement, lock é observacional:** o runtime resolve o SHA
   imutável do `uses:`; o lockfile registra o SHA esperado mas nada no
   servidor bloqueia nada — e nada precisa bloquear, porque o SHA já é a
   garantia. O lockfile agrega visibilidade procedural (seção 3), não
   garantia adicional de runtime.
2. **Superfície pequena, impacto total:** só 1 action, mas ela faz checkout em
   todos os 6 jobs — comprometimento do checkout contamina build/test/smoke.
3. **Supply chain fora do lock:** `npm install -g bun/...`, specs do registry
   (`V1_SPEC`, `V2_SPEC`, plugin specs) e o próprio `gh actions-lock` (cli
   v0.2.0 instalado via `gh extension install`) estão fora do lockfile.
   O piloto cobre apenas `actions/*`.
4. **Deriva silenciosa:** sem step de verify no CI, `ci.yml` e `actions.lock`
   podem divergir sem sinal (seção 4 mitiga com verify warn-only primeiro).

## 2. Baseline CI — mesmo SHA antes/depois, auditável (AC2)

Snapshot do workflow: 6 jobs (`.github/workflows/ci.yml:89-106`), 5 checks
requeridos (`docs/github-lifecycle-policy.md:44-50`). Método: comparar runs de
`push`/`pull_request` no **mesmo HEAD** antes e depois da mudança piloto.

| # | Run (live `gh run list`) | Evento | Status observado | Papel no baseline |
|---|---|---|---|---|
| 1 | `39622810311` | `push` em `master` (merge PR #144) | `in_progress` no momento da coleta | contexto: HEAD em movimento, não baseline |
| 2 | `39614144135` | `pull_request` | `success` | pré-piloto: verde de PR no HEAD próximo |
| 3 | `39602317228` | `push` | `failure` | pré-piloto: falha registrada, não reutilizar como prova |
| 4 | `38627699859` (closure doc) | `push` em `master` (merge PR #89 `abf7f5d`, HEAD `48c9161`) | `success` | base histórica documentada |
| 5 | `38565525111` (closure doc) | base | `success` | base histórica documentada |
| 6 | **after-piloto (PR final)** | `pull_request` do PR que carregar `ci.yml` + `actions.lock` | **PENDENTE — validar no PR final, sem inventar run** | prova exigida: mesmo SHA, 5/5 required verdes |

Regras de leitura (policy vigente):

- Resultado de SHA anterior nunca prova SHA atual
  (`docs/github-lifecycle-policy.md:76-78`).
- Falha de job não requerido continua sendo falha registrada, não liberação
  (`docs/github-lifecycle-policy.md:70-74`).
- `rerun` de flaky documentado só no mesmo SHA com causa registrada
  (`docs/github-lifecycle-policy.md:76-78`).

**Critério de aceite do piloto no PR final:** run `pull_request` do HEAD do PR
com `ci.yml` (SHA `11bd719… # v4.2.2`, inalterado) verde nos 5/5 checks
requeridos, sem `rerun` fora da regra acima. O `actions.lock` **não** é
commitado neste PR: validado localmente (`valid: true`, §3), mas sua presença
no repo causa `startup_failure` no CI (runs `39638927354` e `39640014101`,
0s, sem jobs; após remoção, run `39640221801` iniciou normalmente) —
evidência de que o servidor ainda não aceita a combinação SHA+lock sem
enforcement. Re-commit do lock **somente** com enforcement opt-in futuro
(seção 7.1). Até lá, o status after-piloto é formalmente **pendente**.

## 3. Lockfile validado + stale test (AC3)

Artefato (validado localmente, **não** commitado — ver §3.1): conteúdo de
`.github/workflows/actions.lock` (13 linhas, `version: 'v0.0.3'`),
workflows → `actions/checkout@v4.2.2`, dependência com `ref`/`commit`/
`owner_id`/`repo_id` (`ref: 'v4.2.2'`, `commit: 'sha1-11bd719…'`,
`owner_id: 44036562`, `repo_id: 197814629`).

### 3.1 Por que o lock não é commitado neste PR

`gh actions-lock --verify-local/--verify` = `valid: true` localmente, mas o
CI do GitHub retorna `startup_failure` (0s, zero jobs, sem check-runs) nos
runs `39638927354` e `39640014101` com o lock commitado; removido o lock, o
run `39640221801` iniciou normalmente. Diagnóstico: o servidor ainda não
aceita a combinação workflow-em-SHA + lock-em-tag sem enforcement opt-in.
Decisão (coerente com o HIGH do review: preservar SHA): manter o lock como
artefato local documentado aqui, sem commit, até enforcement opt-in + forma
(tag) aceita pelo servidor. Re-commit **somente** nesse cenário futuro.

Comandos executados pelo host (piloto local) e saídas resumidas:

1. `gh extension install github/gh-actions-lock` (cli v0.2.0) — instalação
   da extensão; fora do lockfile (risco §1.4 item 3).
2. `gh actions-lock` — gerou `actions.lock` (13 linhas) contra o workflow
   com pin de SHA preservado. O default (ref narrowing) teria reescrito as
   6 linhas de `ci.yml` de SHA `11bd719… # v4.2.2` para tag `v4.2.2`; essa
   reescrita foi REVERTIDA — `git diff` de `ci.yml` = vazio. Conversão
   para tag + lock **somente** com enforcement opt-in futuro (seção 7.1).
3. `gh actions-lock --verify-local --json` → `valid: true` (apenas warning
   `sha-as-ref`) — lockfile consistente com o conteúdo local de `ci.yml`.
4. `gh actions-lock --verify --json` → `valid: true` (apenas warning
   `sha-as-ref`) — lockfile consistente com o upstream resolvido
   (ref `v4.2.2` = commit `11bd719…`).
5. **Stale test (negativo):** trocar temporariamente `ci.yml` para
   `actions/checkout@v4.2.1` → `--verify` reporta `ref-changed` + `stale` e
   `valid: false` — detecção funciona (o lock acusa divergência em vez de
   acompanhar silenciosamente).
6. Restaurado para o SHA `11bd719… # v4.2.2` → `--verify` volta a
   `valid: true`.

Conclusão AC3: geração, verificação local/remota e detecção de stale provadas
localmente, com `ci.yml` em SHA. Sem step verify no CI neste HOLD
(seção 4.5): a prova em CI fica para quando houver enforcement opt-in.

## 4. Processo review/update/rollback — dev solo (AC4)

Princípios: todo commit em `master` via PR
(`docs/github-lifecycle-policy.md:6-11`); método de merge padrão = merge commit
(`docs/github-lifecycle-policy.md:102-109`); sem force-push
(`docs/github-lifecycle-policy.md:111-115`).

### 4.1 Bot / sinal de update (proposta, sem auto-merge)

1. Periodicamente (manual, ex. mensal) ou ao receber aviso de release do
   upstream: rodar localmente `gh actions-lock --verify` na branch de trabalho.
2. Se `stale`/`ref-changed`: abrir PR `chore/*` com **apenas** `ci.yml` +
   `actions.lock` (write scope mínimo; sem INDEX, sem registry, sem outros
   arquivos).
3. Sem silent update: nenhuma automação commita, faz push ou merge sozinha
   neste piloto.

### 4.2 Review (release + commit + diff)

1. Conferir o release upstream (notas, breaking changes) e o diff da tag
   (`v4.2.1…v4.2.2` ou equivalente) — na promoção futura a tag é o que o
   runner passará a buscar; neste HOLD o runner busca o SHA imutável.
2. Conferir o diff `ci.yml` (só a linha `uses:` deve mudar) e o diff
   `actions.lock` (`ref`/`commit`; `owner_id`/`repo_id` devem permanecer
   `44036562`/`197814629` salvo transferência real do repo upstream).
3. Rodar `gh actions-lock --verify-local` e `--verify`; anexar saídas ao PR.
4. Aguardar os 5 required checks verdes no SHA do PR (seção 2); falha de job
   não requerido é registrada, não ignorada.

### 4.3 Update (sequência — SOMENTE no caminho futuro com enforcement, §7.1)

> HOLD: não executar neste estado. `gh actions-lock` com ref narrowing
> reescreveria `ci.yml` para tag; sem enforcement isso seria regressão
> (seção 5).

```powershell
git checkout -b chore/actions-lock-<versao>
gh actions-lock
gh actions-lock --verify-local   # esperado: valid true
gh actions-lock --verify         # esperado: valid true
git diff --check
git add .github/workflows/ci.yml .github/workflows/actions.lock
git commit -m "chore: bump actions/checkout <antiga> -> <nova> (lock)"
# PR -> 5/5 required verdes -> merge commit (policy §6)
```

### 4.4 Rollback (merge-aware; integração por merge commit)

O método de merge padrão é merge commit (policy §6), logo o revert de um
bump precisa do flag `-m 1` (o merge tem dois parents; sem `-m` o revert
não se aplica). Procedimento:

```powershell
git checkout -b revert/actions-lock-<versao>
git log --merges --oneline -5 -- .github/workflows/ci.yml .github/workflows/actions.lock
# confirmar que o primeiro parent do merge-commit é a base destino (master)
git rev-list --parents -n 1 <merge-commit-do-bump>
git revert -m 1 <merge-commit-do-bump>   # reverte ci.yml + actions.lock juntos
git diff --check
# PR de revert -> 5/5 required verdes -> merge commit
```

Fallback, se `-m 1` não aplicar (ex. bump veio por PR squash/fast-forward
em vez de merge commit): reverter o PR/branch do bump commit a commit,
restaurando **ambos** os arquivos (`ci.yml` + `actions.lock`) ao mesmo estado
anterior — o caminho padrão nunca separa os dois. Validação deste caminho:
`gh actions-lock --verify-local` deve reportar `valid:true` antes do PR.

Caminho separado de abandono do lock (somente se decisão explícita de
abandonar o lock, nunca como fallback silencioso): remover o `actions.lock`
e restaurar as 6 linhas de `ci.yml` para o SHA `11bd719… # v4.2.2`,
validando manualmente os 6 pins via `grep uses:` (versão + SHA idênticos
ao estado pré-bump). Validação deste caminho: conferência manual dos 6
pins — **sem** exigir `verify-local` de lock ausente (não aplicável a
workflow sem lockfile).

Por que funciona para dev solo: o bump é exatamente 2 arquivos acoplados
(`ci.yml` + `actions.lock`); o revert restaura ambos ao estado anterior
validado, e o CI do PR de revert reprova se o revert quebrar algo. Sem
reescrita de histórico, sem force-push, sem tocar protection.

### 4.5 Step verify warn-only (DIFERIDO — só com enforcement futuro)

Neste HOLD, **nenhum** step verify é adicionado ao `ci.yml` (que permanece
inalterado). Quando — e somente quando — houver enforcement opt-in
server-side disponível (seção 7.1), retomar como PR separado: job/step que
rode `--verify-local` com `continue-on-error: true` (sinal visível sem
bloquear merge), promovendo a gate (sem `continue-on-error`) pelo rito de
promoção de check (`docs/github-lifecycle-policy.md:56-68`).

## 5. Lock != seguro — declaração explícita (AC5)

**Lockfile não é segurança; é visibilidade procedural.**

- O SHA direto preservado (`checkout@11bd719…`, 6 linhas) é imutável sem
  lockfile: o runner busca exatamente aquele commit, independente de tags.
  Essa garantia está mantida — `ci.yml` inalterado.
- Tag + lockfile **sem enforcement server-side** seria uma regressão: o
  runner passaria a buscar `v4.2.2` como a tag apontar naquele momento, e o
  lockfile registraria o SHA esperado sem nada impedir a execução
  divergente. Por isso a conversão para tag foi revertida e a promoção a
  tag + lock fica condicionada a enforcement opt-in futuro (seção 7.1).
- O ganho real do piloto neste HOLD é procedural, sem custo de segurança:
  (a) lockfile observacional registra o par ref/commit esperado;
  (b) detecção de stale via `--verify` provada localmente (seção 3, item 5);
  (c) base pronta para enforcement opt-in futuro (seção 4.5).
- Nenhum claim de "supply chain seguro", "imutável" ou "verificado em CI"
  pode ser feito até: lockfile commitado + step verify no CI + enforcement
  server-side habilitado (onde o plano suportar) + baseline verde pós-piloto
  (seção 2). Neste HOLD, apenas o primeiro item está entregue.

## 6. Fora de escopo — garantias deste trabalho (AC6)

Neste trabalho (piloto + este ADR), **não** foi feito e **não** será feito
neste PR:

- [ ] Nenhum silent update ou automação com escrita (bot só propõe via PR).
- [ ] Nenhuma policy global ou mudança de branch protection / ruleset.
- [ ] Nenhum deploy, nenhum merge executado por este trabalho.
- [ ] Nenhum secret criado, lido ou alterado (CI segue sem segredos, §1.3).
- [ ] Nenhuma atualização de dependência além de `actions/checkout`
  (registry de runtimes, bun, plugins: intocados).
- [ ] Nenhuma plataforma central, nenhum bloqueio rígido sem benefício.
- [ ] Arquivos tocados: este ADR novo
  (`docs/plans/ACTIONS-LOCK-PILOT-149-ADR.md`). O lockfile
  (`.github/workflows/actions.lock`, 13 linhas) foi gerado e validado
  localmente, mas **não** commitado: causa `startup_failure` no CI (§3.1).
  `ci.yml`, INDEX e registry **não** foram editados
  (`git diff` de `ci.yml` = vazio; SHA preservado nas 6 linhas).

## 7. Recomendação por repo — ADOPT / HOLD / REJECT (AC7)

### 7.1 Este repo (`opencode-orchestration`): HOLD

**Recomendação: HOLD** — `ci.yml` INALTERADO (SHA `11bd719… # v4.2.2` nas
6 linhas), lockfile validado localmente mas **não commitado** (§3.1:
`startup_failure` no CI com o lock presente), sem enforcement e
sem step verify no CI.

Justificativa: tag + lock sem enforcement seria regressão — troca a
imutabilidade real do SHA por promessa procedural (o runner buscaria a tag
mutável e o lock não bloquearia desvio). SHA + lock mantém a garantia do
SHA e ganha visibilidade procedural (par ref/commit registrado, stale
detectável via `--verify` local) a custo zero de runtime. Promoção a
tag + lock SOMENTE com enforcement opt-in futuro (server-side disponível
+ step verify warn-only promovido a gate pelo rito da policy); até lá, o
SHA direto continua sendo a postura mais segura, e ela está preservada.

Em nenhum caso REJECT definitivo: o mecanismo (`actions.lock` + `--verify`)
foi provado funcional (seção 3); o que falta é o enforcement, não o tooling.
Quando o plano suportar enforcement, reavaliar: PR final do piloto com
`ci.yml` (tag) + `actions.lock` e baseline verde (seção 2), step
`--verify-local` warn-only (§4.5), e habilitação do enforcement opt-in.

### 7.2 Outros repos (`meu-ted`, `iptv`, `synkroo`): HOLD

**Recomendação: HOLD** — não aplicar automaticamente. Cada um dos 3 repos
replica o piloto localmente (inventário §1 → lockfile §3 → baseline §2) e só
adota após prova própria, porque refs, permissions, branch protection e plano
(determinam enforcement disponível) diferem por repo. Nenhum bump cruzado,
nenhuma policy compartilhada neste trabalho.
