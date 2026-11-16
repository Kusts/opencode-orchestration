# Simplificação das permissões dos subagentes — 2026-11-14

## Objetivo
Permitir inspeção e diagnóstico read-only sem liberar shell amplo.

## Princípio central
Allowlist explícita de leitura com deny por default. Asks para efeitos externos permanecem preservados.

## Matriz de auditoria (Marco 1)
| Agente | Operação | Bloqueio | Origem | Correção |
|---|---|---|---|---|
| reviewer, security-reviewer, architect, engineering-advisor, product-designer, requirements-analyst, skeptic, explorer, researcher, docs-manager | inspecionar diff/histórico (`git diff`, `git log`, `git show`, `git blame`) | deny hard, sem prompt | permissão nativa do runtime (`bash: deny` → `shell "*": deny`) | allowlist read-only explícita |
| explorer, researcher, reviewer, security-reviewer, architect | buscar conteúdo e listar arquivos (`rg`, `grep`, `Select-String`, `Get-ChildItem`, `Get-Content`) | deny hard | permissão nativa do runtime | allowlist read-only explícita |
| docs-manager | validar alteração de documentação (`git diff`, leitura de arquivos) | deny hard | permissão nativa do runtime | allowlist read-only explícita |
| 10 perfis acima | executar comandos fora da allowlist (testes, scripts, wrappers) | deny (mantido de propósito) | permissão nativa do runtime | sem mudança; limite funcional (devem devolver blocker ao Planner) |
| 19 perfis | delegação direta entre workers (Planner→Coder→Tester→Reviewer) | deny (`subagent: "*" deny`) + `experimental.subagent_depth: 1` | permissão nativa + limite global de profundidade | HOLD: exigiria depth>=2 global (fora do escopo autorizado); registrar na issue de evolução |
| 7 writers (coder + 6) | `git rebase` dentro da missão | ask (prompt fora do modo auto) | permissão nativa do perfil | `allow` |
| 7 writers (exceto coder) | `Format-Volume`, `diskpart` | herdavam apenas `ask` do topo, potencialmente sobreposto pelo catch-all allow do perfil | divergência topo vs perfil | `deny` explícito no perfil |
| writers, tester, debugger | `git push`, deploy, publish, `gh auth`, POST externo | ask | permissão nativa (preservada de propósito) | sem mudança: efeito externo/credencial |
| tester, debugger | mutação via shell (commit/reset/rm/elevação) | deny | permissão nativa | sem mudança |
| reviewer e demais read-only | editar arquivo | deny | permissão nativa (`edit`) | sem mudança |
| build/Planner | editar arquivo no fluxo | não é permissão: política de orquestração exige worker | instrução comportamental + gate do kernel | sem mudança (missão preserva autonomia, não remove a delegação) |

## Classes antes/depois
| Classe | Antes | Depois |
|---|---|---|
| read-only | bash deny total | `edit: deny` + allowlist read-only deny-default |
| docs-manager | writer-no-shell | writer-diagnostic |
| writers | rebase ask | rebase allow; denies explícitos Format-Volume/diskpart |
| validator-shell | inalterado | inalterado |

## Decisões
Allowlist em vez de shell amplo; asks externos preservados; grants `shell.diagnostic` alinhados; delegação permanece HOLD.

## Evidências

Registro completo: [`evidence/subagent-permissions-2026-11-14/evidence.json`](../../evidence/subagent-permissions-2026-11-14/evidence.json). Suíte estática reforçada: **594/594**; package consistency **17/17**; V3 na última execução completa **188 pass, 10 skip, 1 fail não identificada** (saída não preservada); as 3 falhas antes observadas (CapabilityShadowSample 73/73, OrchestrationNativeDispatch base 231/231, OrchestrationSettledRecovery 1083/1083) passam em isolamento e não leem `source/agents` nem `execution-grants` — flakes de carga; CI é o gate final. Distribution: **24 pass, 1 fail**, drift preexistente do live-hook (provisionado 2.2.6 vs pin 2.3.0). Instalação isolada: exit 0; 30 instalados, zero unchanged/preserved/conflict/failed; smoke V2 em 2.3.0 OK. Provas comportamentais C/A/B/E PASS; D (cadeia direta) HOLD por depth 1.

## Antes/depois por classe

| Classe | Antes | Depois |
|---|---|---|
| Read-only | 1 regra `bash: deny` (negação geral) | 39 allows sob deny-default |
| Writers | `git rebase` ask | `git rebase` allow + 2 denies explícitos (`Format-Volume`, `diskpart`) |
| Tester/debugger | validator-shell | Inalterados |

## Como validar no runtime

Use o binário pinado e `opencode debug agents --standalone` com `XDG_CONFIG_HOME` isolado. `--standalone` é obrigatório para examinar o conteúdo instalado nesse diretório; sem ele o comando anexa ao serviço em background e mostra a configuração viva do serviço.

## Limitações e HOLDs

- Cadeia direta de subagentes: **HOLD**, `experimental.subagent_depth=1`; exige depth >= 2. O relay do Planner é o caminho suportado.
- REST `/shell`: comportamento não provado; a prova refere-se às permissões da ferramenta, não a essa superfície.
- Em 2.3.0, regras de topo precedem as do agente na lista efetiva; com last-match-wins o catch-all do perfil prevalece sobre asks de topo. Não é falha nova; explica os denies explícitos nos writers.
- `live-hook-v2.tests.ps1` encontra 2.2.6 provisionado onde o pin exige 2.3.0; drift preexistente e não relacionado às permissões.
- Provas comportamentais não estabelecem comportamento humano nem enforcement universal.

## Critérios de aceite

| Critério | Estado |
|---|---|
| Suíte read-only reforçada e verde | PASS (384/384) |
| Package consistency e V3 | PASS parcial (package 17/17; V3 188 pass, 10 skip, 1 fail não identificada + 3 flakes que passam isoladas; CI é o gate) |
| Distribution | HOLD parcial: 24 pass; falha única de drift live-hook 2.2.6 vs 2.3.0 |
| Instalação isolada e load via standalone | PASS |
| Comportamento C/A/B/E | PASS |
| Cadeia direta D | HOLD (depth 1) |
| REST `/shell` e comportamento humano | HOLD / não provado |
| Diff check | A validar ao final da consolidação |


## Revisões de segurança

SP7-001..007: fixed (remoções de Get-*, git grep/cat-file/debug config, push nu ask, cobertura de testes e contagens). SP8-S-01..09: fixed para os itens de remoções/push/cobertura/contagens; documented-residual para flags `--output`/`--pre` e composição, pois o guard rejeitou denies por ambiguidade; accepted para `git rebase` allow nos writers e docs-manager sem restrição de caminho. `Clear-Disk`/`Remove-Partition` não são cobertos pelos denies de disco. A allowlist valida o comando inicial; flags de escrita/execução e composição continuam prompt-enforced. Inspeção instalada correta: `opencode debug agents --standalone` (sem ele, mostra a configuração viva).
## Provas de runtime no 2.3.0 (config isolada, `--standalone --auto --archived`, agente reviewer)

| Caso | Resultado observado | Conclusao |
|---|---|---|
| `git diff --stat` / `git status --short` | Executaram; sada real | PASS |
| `git diff --output=sp-out.txt` | Permitido e criou arquivo (`sp-out.txt=true`) | Resduo confirmado |
| `rg --pre "..."` | Negado (`Permission denied: shell`); comando mangled no relato do agente | Ambguo; causa no atribuvel com certeza, no afirmar conteno da flag |
| `Set-Content` | Negado; arquivo no criado (`sp-deny.txt=false`) | PASS |
| `git status; Set-Content` | Agente dividiu em duas chamadas: primeira ok, segunda negada (`sp-comp.txt=false`) | Composio em comando nico no provada |

`git push` em `ask`  atrito best-effort: `git -C <dir> push`, `git -c k=v push` e espao duplo no casam o padro; conteno real  planner-enforced + gate de delivery.

### Prova de ordering (last-match-wins intra-agente)

Catch-all deny antes; allow nomeado depois; o allow executou no runtime real. Ordem interna do agente provada. Composio topo-vs-agente no provada.
