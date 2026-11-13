# AUTHORITY AND CAPABILITY AUDIT — 2026-11-12

**Status:** PARCIAL (auditoria documental concluída; correções de runtime/perfis e provas de runtime pendem de decisão de operador)  
**Escopo:** issues #50 (capability-first/pins) e #141 (autoridade por superfície)  
**Baseline:** estado do checkout em 2026-11-12 (read-only)

## 1. Escopo e método

- Auditoria **read-only** de código-fonte, registries, scripts, documentação e evidências versionadas; **sem execução de runtime**, sem exercício de APIs, sem exploit e sem alterações em código, perfis, permissões, flags ou config viva.
- **Provado:** fatos observáveis em arquivos versionados citados por caminho/linha quando aplicável (pins, loaders, smokes, translators, registries, tabelas de permissão e matrizes vivas).
- **Assumido/não provado:** comportamento exato do binário OpenCode no ambiente do usuário para pontos que dependem de execução real (p. ex. precedência efetiva de `permissions` de topo vs agente, ou alcance prático da superfície REST `/api/session/{id}/shell` além da evidência registrada de 2.0.23). Essas lacunas são tratadas como itens de prova de runtime, não como conclusões.
- **Não alegado:** nenhum exploit identificado; nenhum enforcement novo; nada aqui ativa flag. Em modo auto do runtime, `ask` pode ser auto-aprovado (confirmação, não bloqueio incondicional).

## 2. #50 — pins e capabilities

### 2.1 Inventário resumido classificado

| Recurso | Fonte / mecanismo | Classificação | Observação |
|---|---|---|---|
| Pins de runtime/tools | `source/registry/runtime-versions.json` (V1 `1.18.34`, V2 `2.2.6`, plugins `1.18.34`/`2.2.6`, bun `1.3.14`), loader fail-closed `scripts/runtime/lib/RuntimeVersions.ps1` (sem fallback literal) | `CI_REPRODUCIBILITY` / `SECURITY_GATE` | Fonte única viva para pins; loader falha fechado sem literal de fallback. |
| Registro histórico de runtime | `source/registry/runtimes.json` (`validated_version` / `plugin_dependency_spec` históricos, superseded) | Histórico (não pin vivo) | Não é fonte de pin; manter separado da fonte viva. |
| Spec exata de plugin em install/CI/typecheck | loader + fluxos de instalação/CI/typecheck que consomem a spec exata | `CI_REPRODUCIBILITY` / `SECURITY_GATE` | Reprodutibilidade e contenção de supply chain por versão fixada. |
| Gating `exact-binary-live` das 8 features V2-native | `source/registry/v2-native-capabilities.json`, `OrchestrationV2NativeGating.ps1` (todas `hold-unproven`) | `SECURITY_GATE` / prova por binário exato | Promoção/claim de autoridade exige evidência no runtime exato; sem promoção automática. |
| Smoke V1 | `scripts/ci/smoke-opencode.ps1` (família major, tolerante) | `CI_REPRODUCIBILITY` | Valida contrato por família, não patch exato. |
| Smokes V2 (igualdade exata de patch) | `scripts/ci/smoke-opencode-v2.ps1:159-168,254-258`; `scripts/ci/smoke-opencode-v2-lifecycle.ps1:437-441,582-586`; `scripts/runtime/lib/SpikeProcess.ps1:147-153` | `CI_REPRODUCIBILITY` (com efeito colateral de compatibilidade) | Exigem igualdade exata de patch; ver achado em 2.2. |
| Descoberta de capability (read-only) | `scripts/runtime/detect-opencode-capabilities.ps1` (emite `SUPPORTED`/`DEGRADED`/`UNSUPPORTED`/`UNKNOWN` com `verification_type`; apenas `cli_core` operacional) | Capability discovery (parcial) | Base read-only existente; cobertura operacional limitada. |
| Doctor sintético | `OrchestrationCapabilityDoctor` (synthetic-only) | Diagnóstico sintético | Não substitui prova operacional no binário. |
| Gating V2-native fail-closed | `OrchestrationV2NativeGating.ps1` + registry V2-native | `SECURITY_GATE` | Falha fechada sem evidência `exact-binary-live`. |

### 2.2 Achado — igualdade exata de patch nos smokes V2

- **Fato:** os smokes V2 exigem igualdade exata de patch (`smoke-opencode-v2.ps1:159-168,254-258`; `smoke-opencode-v2-lifecycle.ps1:437-441,582-586`; `SpikeProcess.ps1:147-153`). O smoke V1 usa família major (`smoke-opencode.ps1:199-215`) e é tolerante.
- **Efeito:** um bump patch/minor compatível do binário V2 pode bloquear a validação (falso negativo de compatibilidade), embora o objetivo de reprodutibilidade por pin seja legítimo.
- **Decisão (auditoria):** tratar como lacuna de estratégia de validação, não como defeito de segurança do pin. Manter lane pinada para reprodutibilidade e separar explicitamente a trilha de compatibilidade (família/contrato/capabilities observáveis) da trilha de prova por binário exato.

### 2.3 Estado da descoberta de capability

- Existe descoberta read-only (`detect-opencode-capabilities.ps1`) com estados `SUPPORTED`/`DEGRADED`/`UNSUPPORTED`/`UNKNOWN` e `verification_type`; apenas `cli_core` é operacional hoje.
- Doctor sintético (`OrchestrationCapabilityDoctor`, synthetic-only) e gating V2-native fail-closed (`OrchestrationV2NativeGating.ps1`, 8 features `hold-unproven`) já impõem contenção.
- **Gaps:** poucas verificações operacionais; promoção ainda exige evidência manual por pin; não há trilha automática de compatibilidade por família/contrato acoplada à lane pinada.

### 2.4 Matriz recurso → decisão → risco → recomendação

| Recurso | Decisão atual | Risco | Recomendação |
|---|---|---|---|
| `runtime-versions.json` + loader fail-closed | Pin exato vivo, sem fallback literal | Drift se houver segunda fonte tratada como pin | Manter como fonte única; tratar `runtimes.json` como histórico. |
| Smokes V2 com patch exato | Igualdade exata exigida para passar | Falso negativo em bump compatível; validação acoplada ao pin | Manter lane pinada; adicionar trilha de compatibilidade por família/contrato/capabilities observáveis (sem promover automaticamente). |
| Smokes V1 por família major | Tolerância de patch/minor | Cobertura de regressão específica de patch menor que V2 pinado | Aceitável como contrato de família; não regredir para pin cego sem necessidade. |
| Descoberta read-only (`detect-opencode-capabilities.ps1`) | Emissão de estados/capabilities, `cli_core` operacional | Sinal incompleto para promoção | Evoluir probes read-only e verificações operacionais incrementais. |
| Gating V2-native `exact-binary-live` | 8 features `hold-unproven`, fail-closed | Claim prematuro de autoridade | Manter `exact-binary-live` para features de autoridade; nunca promover sem evidência no binário exato. |
| Doctor sintético | Diagnóstico sem prova operacional | Falsa confiança se lido como enforcement | Manter rotulado synthetic-only; complementar, não substituir, prova real. |

### 2.5 O que permanece pin/assunção

- Permanece **pin** (decisão legítima): versões exatas em `runtime-versions.json`, specs exatas de plugin e gate `exact-binary-live` para as 8 features V2-native enquanto `hold-unproven`.
- Permanece **assunção** até prova: que um bump patch/minor V2 compatível preserva contratos observáveis relevantes (hoje não exercitado por trilha dedicada); que capabilities além de `cli_core` estão operacionais sem probe correspondente.
- Promoção automática por detecção de capability **não** é recomendada; evolução deve ser por probes read-only e evidência manual/registrada.

## 3. #141 — autoridade por superfície

### 3.1 Mapa de ownership por decisão (superfície → decisão → writer → enforcement real)

| Superfície | Decisão | Writer / origem declarativa | Enforcement real observado |
|---|---|---|---|
| OpenCode V2 (runtime) | Perfis de agente e permissões por agente (V2 nativo) | `source/agents/*.md` + bloco `agents` / `permissions` traduzidos (`AgentTranslator.ps1`); template `templates/opencode.v2.json.tmpl` | Permissões nativas renderizadas/instaladas e validadas por shape/ordem/paridade (checks). Claim de enforcement comportamental aguarda prova no runtime exato; `experimental.policies` inexistente/HOLD. |
| Agent Config | Instruções globais, `permissions` de topo, skills/MCP, ownership de instruções | `AGENTS.md` global gerado/aplicado, `opencode.json` vivo (topo), projeções de skills/MCP | Merge/preservação conforme ownership; enforcement de permissão depende do runtime que consome o config (precedência não provada — ver HIGH-2). |
| Orquestração | Mandato/plugin, template, grants/leases/DONE/estado | Templates, `execution-grants.json`, Task/Goal Kernel, `verification-policy.json`, mandato injetado | **Kernel-enforced** para CAS/gate/DONE/grants/leases/worktrees (quando flags/evidência aplicáveis); grants de runtime permanecem registro/decisão sem enforcement de runtime enquanto `runtime_grant_enforcement` OFF. Mandato/hooks são orientação/controle de fluxo, não barreira de sistema operacional. |
| Usuário / operador | Confirmações `ask`, credenciais, autorização operacional, ativação de flags | Interação humana, ambiente, decisões explícitas | `ask` é confirmação (auto-aprovável em modo auto); credenciais/autorizações são pré-condição operacional, não inferidas pelo worker. |

**Limite declarativo:** `execution-grants.json` exclui `git.push`, `git.commit`, `secrets.read`, `destructive.fs` de baselines; writers têm shell amplo (`bash "*": allow`) com apenas alguns `ask` pontuais nos perfis. `runtime_grant_enforcement` v1/v2 = `false`. Na prática atual, grants são registro/decisão, não enforcement de runtime (ver HIGH-1).

### 3.2 Findings (severidade, evidência e correção mínima)

| ID | Sev. | Finding | Evidência (auditada) | Correção mínima |
|---|---|---|---|---|
| HIGH-1 | HIGH | Grants do Kernel não têm correspondente no runtime; writers mantêm shell amplo e apenas `ask` pontuais; `runtime_grant_enforcement` v1/v2 OFF. | `execution-grants.json` (exclui `git.push`, `git.commit`, `secrets.read`, `destructive.fs` de baselines), perfis writer-shell com `bash "*": allow`, flags OFF. | Documentar a lacuna (feito nesta rodada); correção efetiva exige decisão de operador para tornar grants deny/restrição correspondente nos perfis e só então avaliar enforcement (prova de runtime). |
| HIGH-2 | HIGH | `permissions` de topo no `opencode.json` vivo são amplas (`gh *`, `docker *`, `npm *`, `npx *`, `curl *` allow) e os perfis dos workers são mais restritivos; precedência topo vs agente (last-match-wins) não provada no binário exato. | Config vivo/topo vs perfis em `source/agents/*.md` (mais restritivos); regra de last-match-wins documentada para V2 nativo, mas não provada no binário exato para esta composição. | Documentar incerteza de precedência (feito); prova de runtime no binário exato e, se confirmado risco, decisão de operador para alinhar topo/perfis. |
| HIGH-3 | HIGH | Superfície REST `/api/session/{id}/shell` não passa por `tool.execute.before` (evidência registrada em 2.0.23); `PERMISSIONS.md` rotulava classes como "runtime-enforced" sem essa ressalva. | Evidência de 2.0.23 registrada; rotulagem anterior em `docs/PERMISSIONS.md`. | Ressalva documental explícita (aplicada em PERMISSIONS/SECURITY) distinguindo rota de tool vs superfície REST; prova de runtime para estado atual. |
| MEDIUM-1 | MEDIUM | Plugin falha aberto (mandato é prompt; hooks engolem exceção). | Comportamento descrito do plugin/mandato e hooks. | Tratar plugin como controle de fluxo/prompt, não barreira; endurecer apenas com decisão/escopo separado. |
| MEDIUM-2 | MEDIUM | `git push` em `ask` no topo e nos perfis + confirmação do Planner (dupla semântica). | Config/perfis com `ask` para `git push` e contrato de confirmação do Planner. | Reduzir ambiguidade documental/operacional (quem confirma o quê); mudança efetiva depende de operador. |
| MEDIUM-3 | MEDIUM | Globs `bash:` são matching de string (bypass por `pwsh -Command`, `bash -c`, `Set-Content`). | Limitação já parcialmente declarada; superfície de bypass por wrapper/redirecionamento. | Manter contenção por contrato/ownership e não por glob; reforçar ressalva (já coberta em limitações). |
| MEDIUM-4 | MEDIUM | Template V2 e perfis vivos divergem (edit/shell vivem nos `.md`, sem check de consistência dedicado). | Template vs perfis/`agents/*.md`; ausência de check dedicado citado. | Adicionar check de consistência template↔perfis (mudança de validação/código, fora desta rodada documental). |
| LOW-1 | LOW | `title.model` hardcoded no template. | Template V2. | Parametrizar/fixar por decisão explícita (baixo risco funcional imediato). |
| LOW-2 | LOW | `npx -y @kaneo/mcp` é risco de supply chain (sem versão fixada). | Uso de `npx -y` sem pin. | Fixar versão/registrar (decisão de operador + alteração controlada). |

### 3.3 Matriz de autoridade proposta com lacunas

| Decisão | Dono pretendido (autoridade) | Estado atual | Lacuna | Ação mínima |
|---|---|---|---|---|
| Permissões de tool por agente (V2 nativo) | OpenCode V2 runtime, a partir de perfis/`agents` | Renderizado/validado; enforcement comportamental não totalmente provado | Prova no binário exato (incl. precedência) | Prova de runtime; alinhar topo/perfis se necessário (operador). |
| Grants sensíveis (`destructive.fs`, `deploy.production`, `secrets.read`, `git.push`) | Task/Goal Kernel (decisão) + runtime (enforcement desejado) | Kernel registra/decide; runtime não enforceia (`runtime_grant_enforcement` OFF) | Correspondência deny/enforcement no runtime ausente | Decisão de operador: refletir grants como deny/restrição nos perfis; prova antes de claim. |
| Rota REST `/api/session/{id}/shell` | Runtime (mesma política de shell) | Não passa por tool permission (evidência 2.0.23) | Possível bypass da política de tool | Prova de runtime no binário atual; tratar como não-deny assumido até prova. |
| `permissions` de topo vs agente | Agent Config (config) consumido pelo runtime | Precedência last-match-wins não provada na composição viva | Ambiguidade operacional | Prova de runtime; reduzir sobreposição ampla no topo (operador). |
| Confirmação de ações sensíveis (`ask`, `git push`) | Usuário/Planner + runtime | Dupla semântica (topo/perfis/Planner) | Ambiguidade de responsabilidade | Documentar fluxo; simplificar com decisão explícita (operador). |
| Acesso a diretórios externos (`external_directory`) | Dono da config ativa | Não definido no template V2; 2.2.6 permite por padrão sem regra | Sem confirmação/bloqueio implícito | Configurar regra no dono da config ativa (operador), quando desejado. |

## 4. Recomendações priorizadas

### 4.1 Documentação (pode ser corrigida agora — aplicada nesta rodada)

- Registrar ressalvas factuais: (i) "runtime-enforced" refere-se à rota de tool; a superfície REST `/api/session/{id}/shell` não passa por tool permission (observado em 2.0.23) e não deve ser assumida como deny; (ii) grants do Kernel são registro/decisão, não enforcement de runtime enquanto `runtime_grant_enforcement` estiver OFF; (iii) precedência topo vs agente (last-match-wins) não provada no binário exato. (**Aplicado** em `docs/PERMISSIONS.md` e `SECURITY.md`, com ponteiro a este documento.)
- Promover #50/#141 a **PARCIAL** com resumo e ponteiros (SPEC/PLAN) e registrar a auditoria no `CHANGELOG.md` `[Unreleased]`.

### 4.2 Prova de runtime (pendente)

- Provar, no binário exato em uso, a precedência efetiva entre `permissions` de topo e permissões por agente para a composição viva (HIGH-2).
- Provar o comportamento atual da superfície REST `/api/session/{id}/shell` frente às políticas de shell/deny (HIGH-3), atualizando a evidência além de 2.0.23.
- Evoluir probes read-only/capability checks operacionais para reduzir dependência de promoção manual por pin (#50), sem promover automaticamente.

### 4.3 Decisão de operador (pendente)

- Tornar grants sensíveis deny/restrição correspondente nos perfis (e avaliar ativação de `runtime_grant_enforcement` somente com evidência), endereçando HIGH-1.
- Definir/alinhar regra `external_directory` no dono da configuração ativa, conforme necessidade de confirmação/bloqueio.
- Fixar versão/registrar `npx -y @kaneo/mcp` (LOW-2, supply chain) e revisar `title.model` hardcoded (LOW-1) em mudança controlada separada.
- Considerar trilha de compatibilidade V2 por família/contrato/capabilities observáveis em paralelo à lane pinada, sem substituir `exact-binary-live` para features de autoridade.

## 5. Limitações

- Sem exploit identificado; nenhum teste ofensivo executado.
- Em modo auto, `ask` é confirmação auto-aprovável, não bloqueio incondicional — não reclassificado como deny por esta auditoria.
- Nada aqui ativa flag, altera permissões/perfis ou concede enforcement novo. Itens de runtime/operador permanecem explicitamente pendentes.
- Evidências de runtime citadas (p. ex. 2.0.23 para `/shell`) são históricas/registradas; o estado do binário atual deve ser (re)provado antes de qualquer claim de enforcement.
