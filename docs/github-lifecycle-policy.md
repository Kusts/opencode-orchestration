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

## 4. CI obrigatório (5 checks)

Merge exige os 5 checks do workflow `CI` (`.github/workflows/ci.yml`) verdes
**no HEAD do PR**, pelos nomes reais exibidos no GitHub:

1. `CI (ps51)`
2. `CI (ps7)`
3. `CI (smoke opencode real)`
4. `CI (v2 lane, perfil V2 provisionado)`
5. `CI (smoke opencode v2 real)`

Re-execução (`rerun`) de job flaky documentado é permitida sem novo commit,
desde que no mesmo SHA e com a causa registrada no PR ou no closure. Resultado
de SHA anterior nunca é reutilizado como prova do SHA atual. Nomes acima são
os `name:` reais dos jobs — não inventar sinônimos.

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

- `direct_push`: deny (via `required_pull_request_reviews` + `strict` checks)
- `force_push`: deny (`allow_force_pushes: false`)
- `deletion`: deny (`allow_deletions: false`)
- `require_pull_request`: true (`dismiss_stale_reviews: true`,
  `require_code_owner_reviews: false` — sem CODEOWNERS no repo,
  `required_approving_review_count: 0` — mantenedor solo; CI + threads
  continuam obrigatórios)
- `required_checks`: `strict: true` + os 5 CIs reais da seção 4
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
  checks_required: true    (seção 4, 5 checks)
  review_required: true    (seção 5)
```

Enforcement é processual (este documento + ruleset do §11 quando aplicado),
não do Capability Resolver — o resolver continua offline/advisory e esta
capability não altera trust/risk/permission de nenhuma outra.
