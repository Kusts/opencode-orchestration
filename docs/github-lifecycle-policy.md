# GitHub Lifecycle Policy (Fase 2E)

Source of truth do ciclo de vida Git/GitHub deste repositório. Em
divergência com prática informal anterior, este documento vence.

## 1. Princípio: nenhum commit direto em `master`

**NO DIRECT MASTER COMMITS.** Todo commit em `master` chega exclusivamente
via merge de Pull Request. Sem exceção para docs, closures, small fixes,
typos ou "só um ajuste rápido". Se está em `master`, veio de um PR com CI
verde (seção 5) e review registrado (seção 6).

## 2. Branch/worktree obrigatório para trabalho não-trivial

Todo trabalho não-trivial nasce em branch (`feat/*`, `fix/*`, `docs/*`,
`chore/*`) a partir de `master` limpo, ou em worktree isolado quando houver
paralelismo ou risco de contaminação do checkout. Mudança trivial e
claramente localizada pode seguir o fluxo direto do orquestrador, mas ainda
assim **entra em `master` somente via PR** — a trivialidade dispensa
cerimônia, nunca dispensa o PR.

## 3. Pull Request obrigatório

Sem merge sem PR. O PR é a unidade de revisão, de CI e de evidência: descreve
o escopo, referencia a fase/spec/issue e acumula reviews, threads resolvidas
e resultado do CI antes do merge.

## 4. CI obrigatório (jobs, checks requeridos e política documental)

Três camadas distintas, que não se confundem:

1. **Jobs do workflow `CI`** (`.github/workflows/ci.yml`) — tudo que o
   workflow executa. Snapshot em 2026-10-11: **6 jobs**
   (`ci-linux-capability-collector`, `ci-ps51`, `ci-ps7`,
   `ci-smoke-opencode`, `ci-v2-lane`, `ci-smoke-opencode-v2`).
2. **Checks requeridos pela branch protection de `master`** — o subconjunto
   que o GitHub exige verde no HEAD do PR (`strict: true`,
   `required_approving_review_count: 0`). Snapshot em 2026-10-11: **5**.
3. **Política documental** — este documento (§4 + §11),
   `source/registry/delivery-policy.json` e a política de review da §5.

O número de checks requeridos **não é invariante nem permanente**: é um
snapshot datado. O conjunto requerido hoje (nomes exatos, tal como exibidos
no GitHub — não inventar sinônimos) é:

1. `CI (ps51)`
2. `CI (ps7)`
3. `CI (smoke opencode real)`
4. `CI (v2 lane, perfil V2 provisionado)`
5. `CI (smoke opencode v2 real)`

Esses 5 nomes são a lista vigente da branch protection; o workflow pode ter
mais jobs sem que a lista mude, e a lista só muda por decisão explícita
(abaixo).

**Job novo ou complementar** (ex.: `CI (linux capability collector)`, job de
2026-10) **roda, mas não vira gate por acréscimo**: entra no workflow como
evidência adicional enquanto a promoção a check requerido não for decidida.
Promover um check a exigência de merge exige, cumulativamente:

1. decisão explícita do operador registrada no PR — nunca inferida do
   merge, de um job verde ou de conveniência ("já passa sempre");
2. atualização desta seção com o nome exato do job e o novo snapshot
   datado;
3. atualização de `source/registry/delivery-policy.json`
   (`required_checks`) e da §11 na mesma mudança;
4. re-aplicação da branch protection com o nome real do check — job cujo
   nome não esteja na protection não é gate e não pode ser tratado como tal.

Job novo **não pode enfraquecer o que já existe**: nenhum passo, `skip` ou
condicional pode reduzir a cobertura dos jobs já requeridos, e nenhuma
mudança pode baixar `required_approving_review_count` ou dispensar review
para facilitar o merge. Falha de job não requerido **não** libera o PR:
continua sendo falha, registrada no PR ou no closure.

Re-execução (`rerun`) de job flaky documentado é permitida sem novo commit,
desde que no mesmo SHA e com a causa registrada no PR ou no closure. Resultado
de SHA anterior nunca é reutilizado como prova do SHA atual.

## 5. Política de review

Quatro camadas distintas, sem confusão entre elas:

- **GitHub required review**: aprovação humana (ou regra de ruleset) no PR.
  É o gate de autoridade externa; subagente nenhum o substitui.
- **Internal subagent review**: `reviewer` e, quando a policy disparar
  (auth, dados sensíveis, permissões, infra, segurança), `security-reviewer`
  — independentes, read-only, com veredito `APPROVED` ou `CHANGES_REQUIRED`.
- **Codex bot** (`chatgpt-codex-connector`): sinal consultivo. Findings P1/P2
  são endereçados em commit corretivo separado, sem reescrita de histórico;
  threads são respondidas com evidência e marcadas resolved.
- **Deterministic fallback**: quando o bot estiver indisponível (ex.: 422 não
  é collaborator, sem auto re-review) ou subagents atingirem limite de uso, o
  Planner aplica inspeção integral do diff + provas por finding + verificação
  de ausência de scope creep + tester independente, tudo registrado no PR ou
  no closure.

**Regra anti-fabricação**: nunca inventar `PASS`/`APPROVED`. Resultado sem
evidência observável classifica-se `REVIEW_FALLBACK` (procedimento aplicado e
registrado, autoridade limitada), nunca `REVIEW_APPROVED`. Mensagem de
sucesso de worker nunca é prova.

## 6. Método de merge padrão: merge commit

Padrão = **merge commit**, sem squash e sem reescrita de histórico. Prática
observada: PR #28 mergeado como `c6c15d7` (merge commit, sem auto-merge),
com o fix de review em commit separado `4a1acbe` sobre o HEAD revisado
`c354a6e`. Squash, rebase com rewrite ou qualquer reescrita só por decisão
explícita registrada no PR — nunca por conveniência.

## 7. Force-push e deleção proibidos

`git push --force` / `-f` / refspec `+` proibidos em qualquer branch
compartilhada; deleção de branch protegida ou de tag/release proibida.
Correção = novo commit. Exceção somente via break-glass (seção 9).

## 8. Workflow de closure

O closure (ou sua atualização pós-review) entra **dentro do próprio PR,
antes do merge**, como commit normal da branch. Fatos ocorridos após o merge
(fechamento de review, resultado final de CI, hash do merge commit) entram
exclusivamente via **follow-up docs PR** — nunca via commit direto em
`master`.

## 9. Break-glass (emergência real)

Incident, outage ou emergência de segurança podem furar as seções 1–7
somente com, cumulativamente: motivo explícito registrado, evidência do
incidente, PR ou issue post-hoc que regularize a mudança, e trilha de
auditoria (quem, quando, por quê). Break-glass não é atalho de conveniência:
"pequeno", "só docs" ou "fora do horário" não qualificam.

## 10. Evidência motivadora: incidente `226248e`

Em 2026-10-07, após o merge `c6c15d7` do PR #28, o commit `226248e`
(`docs: record PR #28 review findings closure`) foi aplicado **direto em
`master`** (commit com parent único = merge commit, fora de qualquer PR).
Conteúdo correto, procedimento errado: é exatamente o caso que as seções 1 e
8 agora proíbem — o registro pós-merge deveria ter seguido via follow-up
docs PR. Este incidente é a evidência motivadora desta policy, registrado
aqui sem reescrever o histórico.

## 11. Branch protection de `master` (aplicado)

Conjunto recomendado para `master` — **APLICADO em 2026-10-07** via API
clássica de branch protection, com autorização explícita do operador:

- `direct_push`: deny para non-admins (via `required_pull_request_reviews`
  + `strict` checks). Não vincula administradores (`enforce_admins: false`):
  bypass técnico de admin existe e só é legítimo como break-glass (§9) com
  trilha de auditoria post-hoc.
- `force_push`: deny (`allow_force_pushes: false`)
- `deletion`: deny (`allow_deletions: false`)
- `require_pull_request`: true (`dismiss_stale_reviews: true`,
  `require_code_owner_reviews: false` — sem CODEOWNERS no repo,
  `required_approving_review_count: 0` — mantenedor solo; CI + threads
  continuam obrigatórios para non-admins (admin bypass = break-glass §9))
- `required_checks`: `strict: true` + os 5 checks requeridos da seção 4
  (snapshot 2026-10-11; a lista é a vigente, não um número fixo — promoção
  de job novo a check requerido segue o procedimento da §4)
- `require_conversation_resolution`: true (`enabled: true`)
- `required_linear_history`: false (merge commit é o método padrão, §6)
- `enforce_admins`: false — bypass de admin preservado como caminho
  break-glass (§9), com trilha de auditoria post-hoc; nunca atalho de
  conveniência.

## 12. Capability `github-lifecycle` (por referência)

Mapeamento documental, sem entry nova no registry (verificado: nenhuma
capability `github-lifecycle` existe em
`source/registry/capability-policy.json`, e nenhuma foi criada — sem
redundância, sem toque no registry):

```text
capability github-lifecycle:
  branch_required: true   (seção 2)
  pr_required: true        (seção 3)
  checks_required: true    (seção 4 — subconjunto requerido do workflow `CI`,
                           6 jobs no total; snapshot 2026-10-11: 5 requeridos)
  review_required: true    (seção 5)
```

Enforcement é processual (este documento + ruleset do §11 quando aplicado),
não do Capability Resolver — o resolver continua offline/advisory e esta
capability não altera trust/risk/permission de nenhuma outra.
