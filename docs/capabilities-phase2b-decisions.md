# Decisões e residuais — Fase 2B (2026-10-07)

## 1. Permission model residual: force-push / docker prune (proposta, NÃO implementada)

Estado: `source/agents/coder.md` tem `git push * → ask`, mas NÃO tem
`git push --force* → deny` (nem `docker system prune*` → deny). O estado atual
é fail-ask: seguro no modo interativo, mas SEM garantia em modo auto (`ask`
pode ser autoaprovado) e SEM contenção real por glob (globs `bash:` são
matching de string — contenção real é via contrato + ownership, ver
`docs/PERMISSIONS.md`). Ou seja: um `--force` hoje cai no `ask` genérico, e
`ask` não equivale a confirmação humana.

Opções estudadas:

1. **deny-before-ask** (recomendada): avaliador testa regras `deny` antes de
   `ask`; adicionar `git push --force* → deny`, `git push * --force* → deny`,
   `docker system prune* → deny`, `docker * --force* → deny`.
2. **most-specific-first**: a regra com maior especificidade (mais literais /
   mais longa) vence, independente da ordem; exige matcher com escore.
3. **structured command matcher**: parser que separa subcomando + flags
   (ex. `push` + `--force`) em vez de glob de string; correto, mas é mudança
   de autoridade (classe AUTHORITY_CHANGE) e exige suíte própria.

Recomendação: opção 1 (2–4 linhas de `deny` + testes de precedência), com
security review obrigatório, em rodada própria (2C). NÃO implementado na 2B
para não misturar mudança de autoridade com curadoria. Comportamento até lá:
fail-ask no modo interativo; em modo auto, a contenção real continua sendo
contrato do Planner + ownership (nenhum worker amplia ambiente/escopo por
inferência; diante do não coberto, interrompe e devolve).

## 2. Pins: 2.0.23 vs 2.0.24 (recomendação, sem bump)

- Pin em vigor: V2 `@opencode/cli@2.0.23` (fonte única
  `source/registry/runtime-versions.json`).
- Runtime observado: `opencode v2.0.24` nesta máquina (drift conhecido).
- Recomendação: MANTER 2.0.23 até rodada própria de smoke no binário exato +
  decisão humana (política de flags conservadoras). Bump misturado à 2B foi
  explicitamente evitado.

## 3. Config-format FAILs (2, preexistentes, NÃO tocados)

Suite `config-format`: 51 PASS / 2 FAIL, ambos fora do escopo 2B:

- `a: 17 blocos agent (chaves geridas)` — merge V1 (`agent.*`) no install.
- `b: coder.model gerenciado aplicado` — merge V1 (`agent.coder.model`).

Relacionam-se ao dialeto V1 vs Auto→V2 (ver issue #21, aberta) e não a
skills/MCPs. Nenhuma alteração da 2B os afeta; seguem como residuais com dono
(issue #21).

## 4. Issue #25 — regeneração de `ai-memory.ts` (evidência nova, sem fix)

Evidência coletada na 2B (sem alterar a máquina):

- `plugin-healthcheck` (2026-10-07): telemetria com `LoadError` para o plugin
  depreciado `ai-memory.ts` no run `a0fbc078` (5 erros) + cópia inativa
  `ai-memory-opencode2.ts.bak-1791360135` na raiz de plugins.
- Estado atual do disco: hook ativo é `ai-memory-opencode2.ts` (presente);
  `ai-memory.ts` legado NÃO existe no disco (só na telemetria histórica).
- Leitura: algo (hook legível pelo runtime ou rotina externa) referencia o
  path legado; o runtime tenta carregar e falha fechado (fail-closed OK —
  nenhum bypass). A cópia `.bak` na raiz ativa é ruído que o discovery pode
  tentar ler.

Status: documentado aqui + comentário com evidência postado na issue #25;
issue permanece ABERTA (fora do foco principal da 2B, conforme escopo).
Correção sugerida (baixo risco, rodada própria): remover o `.bak` da raiz
de plugins + registrar o path legado como known-deprecated no healthcheck
do plugin.

## 5. Autoresearch (veredito 2B: KEEP_LOCAL)

Skill v2.2.2 em `~/.config/opencode/skills` (opencode-only). Valor real em
loops de iteração com métrica; overlap parcial com researcher/Jev; custo
bounded por default com invariants (sem push/publish/deploy sem aprovação).
Diretório `commands/` com 14 commands NÃO verificado no path (só existem
`references/` + `scripts/`). Classificação PERSONAL P2; fora do ownership
do orchestration; sem promoção ao catálogo gerenciado.
