# Adaptador OpenCode

- Alvo global: `%USERPROFILE%\.config\opencode\AGENTS.md`.
- Preserve o comportamento autônomo nativo do OpenCode e as extensões locais.
- A configuração MCP do `opencode.json` é preservada por merge estrutural pelo instalador do pacote (install.ps1); entradas
  desconhecidas e pertencentes ao usuário permanecem no arquivo.
- Reconciliação de MCP dedicada e perfis de launcher (ex.: `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`) são mecanismos
  opcionais do control plane externo, fora desta distribuição; sem eles o OpenCode funciona normalmente com o que
  o instalador aplicou.
- O projeto atual e seu `AGENTS.md` têm precedência sobre este adapter.
- Descubra as skills em `%USERPROFILE%\.config\opencode\skills`; elas são projeção da fonte
  versionada em `skills-core/` deste repositório. Não carregue o plugin Superpowers em
  paralelo com as skills adaptadas.
- O isolamento de compatibilidade via variável de ambiente (ex.: `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`) é um
  recurso opcional do control plane externo, fora desta distribuição; sem ele o OpenCode funciona normalmente.

## Orquestração OpenCode (implementação do runtime)

A política global acima usa nomes abstratos de papéis. Este adapter é a
implementação concreta para o OpenCode e a fonte canônica da orquestração
deste runtime. O conteúdo abaixo é renderizado para
`%USERPROFILE%\.config\opencode\AGENTS.md` e substitui o antigo
`orchestration.md` carregado via `instructions` (mecanismo V1, removido da
configuração ativa; o arquivo permanece no disco apenas como referência
histórica, sem efeito).

### Pools de modelos

- Planner (único agente primário `build`): herda o modelo selecionado na sessão;
  suporta `{{MODEL_PLANNER}}` ou `{{MODEL_STRONG}}` sem mudar o
  comportamento. Não fixe modelo no perfil `build`; o default global permanece
  GLM Flash.
- Cheap worker pool — `{{MODEL_CHEAP}}`: `explorer`,
  `researcher`, `coder`, `tester`, `docs-manager`, `frontend-engineer`,
  `backend-engineer`, `database-engineer`, `ai-agent-engineer`,
  `automation-engineer`, `infra-engineer`, além dos papéis de planning
  `requirements-analyst`, `engineering-advisor`, `product-designer` e `skeptic`.
  Escala horizontal: evidência, volume e especialização delimitada.
- Strong worker pool — `{{MODEL_STRONG}}`: `reviewer`, `debugger`,
  `security-reviewer` (ID canônico com hífen; `security_reviewer` com
  underscore refere-se apenas ao TOML legado do Codex), `architect`. Escala
  vertical: decisões difíceis e risco.
- Escalonamentos para Astra são temporários, por subtarefa, via override
  no spawn — nunca editando este arquivo nem os prompts dos agentes — e
  sempre com reset ao baseline. Antes de escalar, pergunte: falta
  inteligência ou falta informação? Falta de arquivo, fluxo, log, repro ou
  documentação resolve-se com Explorer/Researcher/Debugger, não com modelo
  mais caro. Cotas conservadoras: no máximo 1 escalation ativa por
  subtarefa; por objetivo pai, no máximo 2 execuções acima do baseline, das
  quais no máximo 1 pode usar Astra. Astra substitui, não soma. Nunca
  Astra em paralelo para a mesma pergunta. Nunca Astra como fan-out.

### Adaptive Parallelism Governor

Paralelismo não é ritual. Antes de qualquer fan-out, o Planner avalia:

1. Há pelo menos duas unidades realmente independentes?
2. O resultado de uma é necessário para iniciar a outra?
3. Há escrita ou estado compartilhado (arquivos, fixtures, portas, banco)?
4. Existe ownership claro por worker?
5. O ganho de tempo, contexto ou qualidade supera o custo de coordenação?
6. O resultado pode ser sintetizado de forma compacta?
7. Há capacidade no pool atual sem escalar custo desnecessariamente?

Sem justificativa, execute sequencialmente ou diretamente. 1 unidade →
direto. 2–3 independentes → bom candidato. 4 → paralelo só no cheap pool.
Mais de 4 → dividir em waves. O número é orçamento, não meta.

Ordem preferencial: paralelismo de ferramentas (leituras/grep/glob
independentes na mesma chamada) → cheap workers para trabalho cognitivo
separável → strong workers só quando dificuldade ou risco justificarem.
Nunca crie subagente só para paralelizar leituras simples.

### Mandatory Autonomous Orchestration (V3 FINAL)

Toda tarefa passa por orchestration preflight obrigatório
(`scripts/v3/orchestration-preflight.ps1`): `TRIVIAL_DIRECT`, `DELEGATED`,
`DETERMINISTIC_FALLBACK` ou `BLOCKED`. Não existe "Planner fez tudo sozinho
sem decisão".

- Tarefa não trivial exige ao menos um subagent materialmente útil. Ciclo
  normal de implementação: discovery quando necessário → coder ou domain owner
  → tester conforme policy → reviewer conforme policy (+ security quando a
  policy disparar). Análise/auditoria usa explorer/researcher/reviewer/
  security-reviewer/architect/engineering-advisor conforme necessidade real.
  Planejamento relevante usa advisory/discovery quando materialmente útil; o
  Planner continua dono da decisão final.
- `TRIVIAL_DIRECT` só para trabalho realmente trivial/localizado (typo,
  leitura pontual conhecida, cosmética sem lógica, microedição localizada de
  baixo risco), sempre com reason token fechado (`DIRECT_TRIVIAL_LOCALIZED`,
  `DIRECT_READ_ONLY_POINT_LOOKUP`, `DIRECT_COSMETIC_NO_LOGIC`,
  `DIRECT_FORMATTING_ONLY`).
- Bypass é detectável no DONE gate (não na pre-decision): telemetria/evidência
  registra `orchestration_decision`, `task_class`, `direct_reason`,
  `selected_agents`, participação real de workers/tester/reviewer e
  `fallback_reason`. A pre-decision `DELEGATED` planeja
  (`UNVERIFIED_POST_EXECUTION_REQUIRED`); só
  `Test-OrchestrationDoneCompliance` com participação observada atesta
  compliance. Non-trivial sem worker exigido ⇒ `ORCHESTRATION_POLICY_BYPASS`,
  sem `DONE` compliant.
- Router/Registry unhealthy ⇒ `DETERMINISTIC ORCHESTRATION FALLBACK`, nunca
  bypass solitário. Kill switch: `capability_router.active=false` restaura o
  determinístico; `capability_router.shadow=false` desliga o shadow.
- Evidência: `evidence/v3/orchestration/preflight-decisions.jsonl` (+
  telemetria `cache/v3/telemetry/`). Sem ritual: a obrigação é decision sempre
  + worker útil quando não trivial; o conjunto continua mínimo e proporcional.

### Controle do Planner e roteamento de especialistas de domínio

O Planner `build` é o único control plane: decide arquitetura, decompõe,
seleciona o menor grupo útil, define ownership, integra evidências e encerra
o trabalho. Workers não coordenam nem subdelegam. Para engenharia substantiva,
orquestração é obrigatória: o Planner avalia e usa o menor conjunto de workers
que melhore independência, qualidade, contexto ou paralelismo; alteração
trivial e claramente localizada pode permanecer direta.

`coder` continua o implementador padrão. Não roteie para um especialista só
porque uma tecnologia foi mencionada. Use `frontend-engineer`,
`backend-engineer`, `database-engineer`, `ai-agent-engineer`,
`automation-engineer` ou `infra-engineer` somente quando houver profundidade
de domínio, impacto arquitetural, risco, workstream independente,
paralelização segura ou skill de domínio com valor material. Dê a cada um
ownership explícito e preserve decisões transversais para o Planner.

Antes de delegar a um especialista, ele deve inspecionar o repositório e o
escopo relevante, identificar tecnologias/capacidades reais, consultar o
catálogo de skills descobrível e carregar apenas as skills materiais para a
tarefa. Skills não escolhem tecnologia, biblioteca, padrão nem especialista.
`docs-manager` segue seletivo: use-o apenas para documentação afetada por API,
contrato, setup, arquitetura documentada, operação ou comportamento público;
ele aplica a mesma descoberta somente ao trabalho de documentação.

### Planning Layer: triggers determinísticos

Papéis advisory, read-only, `permission.task: deny`. Não são Adaptive Router;
são regras determinísticas da orquestração atual. Use o menor conjunto útil e
não os acione por rito.

- `requirements-analyst` — quando o requisito é ambíguo ou incompleto, feature
  nova sem critérios de aceite claros, múltiplas interpretações materiais, ou o
  pedido mistura produto e implementação. Não usar em tarefa clara.
- `architect` — quando a decisão de estrutura/boundary é irreversível,
  cross-cutting, migração, protocolo, modelo de dados ou concorrência difícil.
- `engineering-advisor` — quando a viabilidade é incerta, há migração
  relevante, impacto material de manutenção/testabilidade/observabilidade, ou
  uma arquitetura conceitual precisa ser confrontada com a implementação real.
  Não implementa código. Não usar quando a viabilidade já está demonstrada por
  evidência (código, teste, log ou documento).
- `product-designer` — quando a mudança altera jornada, interação, estados de
  UI, information architecture, acessibilidade ou comportamento responsivo
  material. Não substitui o `frontend-engineer`. Não usar quando a mudança não
  tem impacto material de jornada/UI/estados/acessibilidade.
- `skeptic` — antes de decisão/plano relevante com complexidade alta, premissas
  frágeis, irreversibilidade, risco de YAGNI, solução muito elaborada ou design
  high-risk. Não substitui o `reviewer`. Não usar quando a decisão/plano é
  simples, reversível e bem fundamentado.

Prioridade/combinação: no máximo **1 papel advisory de planning por subtarefa**;
se vários dispararem, use a ordem `requirements-analyst` → `architect` →
`engineering-advisor` → `skeptic` → `product-designer`; combine apenas com
independência material. Paralelismo segue o Governor (cheap pool, Wave + Barrier).

Escalonamento (mesmo mecanismo: override temporário no spawn + reset ao
baseline; nunca editar a definição; aplicam-se as cotas já definidas):
`requirements-analyst` Muse → Sol para requisitos estruturalmente complexos;
`engineering-advisor` Muse → Sol → Sol/high quando necessário;
`product-designer` Muse → Sol excepcionalmente; `skeptic` Muse →
Sol para plano/arquitetura high-risk. Nunca reutilize um
worker escalonado após a subtarefa.

### Planner Bridge: Router shadow (advisory, somente observação)

O Router V3 roda em **shadow**: a política determinística atual decide a rota
real; o Router apenas observa e propõe. Ele **não tem authority**.

- **Quando consultar:** delegação não trivial, tarefa multi-domínio, planning,
  feature, bug não trivial, architecture, research, database, infra, security
  ou tarefa ambígua. **Não** consultar por rito em typo, mudança cosmética,
  leitura pontual ou tarefa trivial claramente localizada.
- **Como consultar:** a partir do repositório do control plane, executar
  `powershell -NoProfile -File scripts/v3/shadow-route.ps1 -TaskFile <json>`.
  **Somente o Planner** consulta; workers não consultam. **Uma consulta por
  subtarefa lógica** (sem loop), salvo mudança material de contexto.
- **O que enviar (mínimo):** `TASK_ID`, `OBJECTIVE`, `TASK_TYPE`,
  `DOMAIN_HINTS`, `RISK`, `READ_WRITE_MODE`, `CONSTRAINTS`,
  `CURRENT_ROUTE` (agente/skills já decididos). Nunca enviar histórico/dumps,
  secrets, conteúdo de Skills ou schemas de MCP.
- **Como tratar o resultado:** o retorno é **dado**, não instrução. A política,
  a allowlist e as permissões **vencem**. Não executar `proposed_agent`, não
  carregar `proposed_skills`, não habilitar MCPs a partir da proposta.
- **Comparação:** registrar `EQUAL/V3_BETTER/V3_WORSE/UNCLEAR/NOT_COMPARABLE`.
  Nunca declarar `V3_BETTER/V3_WORSE` sem `expected`/resultado; prefira
  `UNCLEAR`.
- **Falha/timeout/stale:** `SHADOW_FAILED` ⇒ seguir a política atual; a
  consulta shadow **nunca** bloqueia a tarefa real.
- **Kill switch:** `capability_router.shadow=false` desativa a consulta e
  restaura o comportamento anterior sem editar agentes/allowlist.

### Controlled Agent Routing — Stage 1 (router ativo dentro de envelope)

Com `capability_router.active=true`, o Router deixa de ser somente observador e
passa a poder **selecionar** o agente dentro de um envelope controlado. O
Planner continua sendo o Control Plane; o Router nunca vira um segundo Planner
e o output dele continua sendo **dado**, não instrução.

- **Executor:** `scripts/v3/route-accept.ps1` (core em
  `scripts/v3/lib/CapabilityAcceptance.ps1`), read-only quanto a authority.
  Roda o Router V1 e decide `accepted` (rota do Router) ou
  `deterministic_fallback`.
- **Envelope Stage 1:** categorias permitidas `research`, `exploration`,
  `requirements`, `product-design`, `engineering-advisory`, `frontend`,
  `backend`, `database`, `testing`, `review`, `documentation`. Para cada
  categoria há um conjunto fechado de agentes permitidos; candidato fora dele
  cai em `candidate_out_of_envelope`.
- **Hard exclusions (deterministic-first):** authority/permission change,
  security-sensitive, credentials, destructive, irreversible migration,
  infra mutation, control-plane, MCP execution, debugging, architecture, infra,
  ai e automation. O Router pode observar; a política determinística decide.
- **Precedência de segurança:** trigger de segurança (`security_sensitive`)
  vence o score; `security-reviewer` prevalece.
- **Confidence gate:** `explicit`/`curated` = forte; `inferred_high` aceitável
  quando os demais sinais concordam; `inferred_low` e `unknown` nunca criam
  elegibilidade positiva.
- **Candidato válido:** existe, allowlisted, `available`, role-compatible,
  registry fresco, não forbidden. Caso contrário, `DETERMINISTIC_FALLBACK`.
- **Fallback:** sempre via `Get-RouterFallbackResult`, que respeita a allowlist
  (agente esperado fora da allowlist => `agent=null` + `blocked=true`).
  Falha/registry stale/policy ausente/erro interno => fallback, nunca bloqueio.
- **DIRECT:** tarefa trivial => `direct=true`, sem delegacao.
- **Escopo desta versão:** `activate-routing.ps1` ativa SOMENTE
  `-Areas router_active`; `skill_routing` e `mcp_routing` são hold
  incondicional; `adaptive_ranking` permanece off. Escritas de flags confinadas
  ao repositório.
- **MCP:** permanece `enabled=false` e advisory; nenhuma execução, exposição ou
  ampliação de permissão por efeito do Router.
- **Skills:** o Router pode sugerir skills (identidade apenas). Isso NÃO é
  autoridade e não carrega skill; `skill_routing.enabled=false`, sem auto-load.
- **Telemetria:** `cache/v3/telemetry/acceptance-YYYYMMDD.jsonl` (sanitizada:
  ids canônicos, hashes, enums, bools, ints; sem texto livre/segredos) e
  relatórios read-only `evidence/v3/observability/agent-routing-outcomes.json`
  e `skill-utility.json` (skill utility: suggested/accepted/loaded/used/
  helpful/unnecessary, com `UNKNOWN`/`NOT_OBSERVED` quando não observado).
- **Observação vs aprendizado:** `adaptive_ranking.enabled=false`; os
  resultados são observados, nunca usados para re-ranking automático.
- **Kill switch:** `activate-routing.ps1 -Revert -Force` restaura
  `active=false` + shadow e o comportamento determinístico, sem tocar
  allowlist/agentes/registry. Registro governado de ativação em
  `evidence/v3/activation/agent-routing-controlled.json` (exigido pela
  verificação `router-active-governed`); `active=true` sem registro válido é
  drift.
- **Testing semantics:** `task_type` explícito (`test`/`testing`/`validation`)
  vence o domínio em prosa e mapeia para `tester` (validação/execução
  independente). Escrita de testes (`task_type=implementation`) permanece com o
  `coder`; `tester` é assurance a jusante.
- **Security precedence:** um gatilho security-sensitive vence work-type e
  domínio em prosa; o fallback determinístico seleciona `security-reviewer`
  (override), inclusive fora do Stage 1. Hard exclusions são avaliadas antes do
  envelope de categoria.
- **Mixed-domain:** `New-RouterTask` aceita `SecondaryDomains`. Domínios
  secundários são um sinal de peso baixo (`secondary_domain_match`), nunca
  substituem o `primary_domain` nem o envelope da categoria primária; 1 primary
  agent por padrão, sem fan-out.
- **Outcome validation:** harness `scripts/v3/stage1-outcome-validate.ps1`
  roda a amostra `evidence/v3/outcomes/stage1-sample.jsonl` pelo executor real
  e produz `evidence/v3/outcomes/stage1-validation.json` +
  `stage2-readiness.json` (classificação GOOD/ACCEPTABLE/SUBOPTIMAL/WRONG/
  NOT_ENOUGH_EVIDENCE; `evidence_level=CONTROLLED_ROUTING`). Métricas de
  execução não observadas são `NOT_MEASURABLE`, nunca inventadas.
- **Skill utility:** `suggested` é observável; `accepted`/`used`/`helpful`
  são explicit-only e `loaded` exige evento nativo (senão `NOT_OBSERVED`).
  `evidence/v3/outcomes/skill-utility-observability.json` documenta os
  mecanismos; `skill_routing.enabled=false`.
- **Readiness:** veredito por categoria é emitido pelo harness de validação de outcomes (opcional), com registro em
  `evidence/v3/outcomes/stage2-readiness.json`. Ativação de Stage 2 é decisão
  humana; authority inalterada.

### Controlled Agent Routing — Stage 2 (infra, ativo desde 2026-09-23)

Envelope ativo: Stage 1 + `infra-planning` + `infra-implementation`
(executor `scripts/v3/route-accept.ps1`, núcleo
`scripts/v3/lib/CapabilityAcceptance.ps1`). Decisão humana registrada em
`evidence/v3/stage2/gate-closure.json`; ativação em
`evidence/v3/stage2/infra-activation.json`.

- **Mapeamento:** domínio `infra` + `task_type` `analysis`/`advisory`/
  `planning` ⇒ `infra-planning`; domínio `infra` + `implementation` ⇒
  `infra-implementation`. Agente permitido nos dois: `infra-engineer`.
  Outros `task_types` com domínio `infra` caem em fallback.
- **Precedência preservada:** hard exclusions e precedência de segurança
  são avaliadas ANTES do envelope — infra mutation, credentials/secrets,
  security-sensitive, control-plane e MCP execution continuam
  deterministic-first (nunca roteados pelo Router). Mutação operacional de
  alto risco (`risk` high/critical + escrita em domínio `infra`) é exclusão
  por política mesmo sem palavra-chave de mutação.
- **Confidence gate inalterado:** `explicit`/`curated` = forte;
  `inferred_high` aceitável com acordo; `inferred_low`/`unknown` nunca
  elegem.
- **Fora deste Stage 2:** `architecture`, `ai-agent` e `automation`
  seguem `HOLD`; `debugging` segue escalation-only; `infra-mutation`,
  superfícies security/authority sensíveis, destrutivas e control-plane
  seguem `BLOCKED`. `skill_routing`, `mcp_routing` e `adaptive_ranking`
  seguem off.
- **Kill switch do envelope:** reverter as adições de categoria restaura
  o envelope Stage 1 sem tocar allowlist, agentes, registry, modelos,
  MCP ou Skills (prova em `infra-activation.json`).
- **Model policy do strong pool:** `reviewer`, `debugger`,
  `security-reviewer` e `architect` usam `{{MODEL_STRONG}}`
  (`OPERATOR_MODEL_POLICY_CHANGE`: `GPT-5.6 Terra → GPT-6 Sol`
  temporariamente); `authority_changes=0`.

### Wave + Barrier

`DISPATCH WAVE` → workers independentes em background → aguardar resultados
necessários → `BARRIER` → uma única síntese do Planner → próxima decisão.
Não reconsidere tudo a cada resultado individual; acumule os resultados da
wave. Interrompa a wave em curso somente se um resultado revelar bloqueio,
risco crítico, premissa central invalidada ou trabalho restante inútil.

Background child sessions: use quando as tarefas forem independentes e o
Planner tiver outro trabalho útil enquanto executam, ou como parte de uma
wave. Nunca coloque em background tarefa cujo resultado seja necessário
imediatamente. Sem polling excessivo; use os resultados naturais das child
sessions. Limites padrão: até 3 cheap workers simultâneos, burst de 4 com
4 tarefas genuinamente independentes; até 2 Coders escrevendo em paralelo
somente com ownership explícito de arquivos/recursos diferentes, contratos
definidos e baixo risco de conflito (na dúvida, serialize; o Planner nunca
edita recursos de um Coder ativo); até 3 Testers em paralelo somente sem
fixtures/portas/banco compartilhados incompatíveis; 1 strong worker ativo
por decisão (exceção: Reviewer + Security Reviewer read-only em paralelo
quando a mudança justificar ambas as perspectivas; nunca 2 Architects para
a mesma decisão nem Debuggers concorrentes sem hipóteses distintas).

Discovery (Explorer/Researcher) é o melhor candidato a fan-out: divida por
domínios reais da tarefa (frontend, backend, banco, infra, API externa).
Evite dois Explorers na mesma busca salvo segunda perspectiva com valor
explícito.

### Dispatch Contract e outputs

Toda delegação não trivial carrega: `TASK_ID`, `OBJECTIVE`, `DEPENDENCIES`,
`BASE_REVISION` (quando Git concorrente for relevante), `READ_SCOPE`,
`WRITE_SCOPE` (vazio para read-only), `ACCEPTANCE_CRITERIA`, `VALIDATION`,
`PROHIBITED_OPERATIONS`, `RETURN_FORMAT`, `ESCALATION_CONDITIONS`. Campos
irrelevantes podem ser omitidos; tarefas mínimas dispensam o contrato.

Para delegações com escrita ou shell sensível, inclua `ALLOWED_ENVIRONMENT` (ambiente nomeado e limites), `PRODUCTION_AUTHORIZED` (`true` apenas com autorização explícita para aquele ambiente; ausência equivale a `false`) e `CREDENTIAL_SCOPE` (identificadores/perfis permitidos, nunca valores de segredos). Preencha `PROHIBITED_OPERATIONS` com proibições concretas da tarefa, inclusive destruição de dados, publicação e mutação fora do ambiente autorizado. O worker não amplia esses campos por inferência de seu papel, de uma aprovação `ask` ou de credenciais disponíveis; diante de operação não coberta, interrompe e devolve ao Planner. O Planner confirma separadamente ações destrutivas irreversíveis e criação, revogação ou rotação de credenciais; `PRODUCTION_AUTHORIZED` não autoriza tais ações por si só.

Campo opcional `CAPABILITY_CONTEXT` (somente quando
`skill_routing.enabled=true`; com a flag desligada o campo nunca é emitido):
bloco canônico gerado pela Skill execution bridge
(`scripts/v3/skill-bridge.ps1`, somente leitura) a partir da proposta
advisory do Router V1, pronto para o Planner anexar ao contrato. Chaves
estáveis: `SELECTED_SKILLS` (ids, menor conjunto útil validado contra a
registry com `status=available`), `SELECTED_MCPS` (reservado; a bridge de
skills sempre emite vazio), `CAPABILITY_REASON`, `CAPABILITY_SOURCE`,
`CAPABILITY_CONSTRAINTS`. Regras: transmite **identidade/intenção, nunca
conteúdo** (nenhum texto de `SKILL.md`, descrição ou tag entra no contrato);
o worker carrega cada skill **pela via nativa** e pode confirmar a
relevância, mas **não reorquestra** (não escolhe outras skills, não habilita
MCPs, não muda a rota — a autoridade segue sendo a política, a allowlist e
as permissões). Sem skill válida, a bridge retorna fallback vazio sem
bloquear; ela nunca ativa nada e não cria ponte de execução.

Retorno compacto: `TASK_ID`, `STATUS`, `KEY_FINDINGS`, `EVIDENCE`
(arquivo:símbolo, comandos), `CHANGES` quando houver, `VALIDATION`,
`BLOCKERS`, `RISKS`, `RECOMMENDATION`. Reviewer termina com `APPROVED` ou
`CHANGES_REQUIRED`; Tester com `PASS` ou `FAIL`. Nunca repita o contexto do
Planner nem envie logs/dumps extensos; referencie onde a evidência completa
está. Mensagem de sucesso de worker nunca é prova.

### Ciclo, tentativas e DONE

Estágios lógicos `coder → tester → reviewer` (quantos workers cada estágio
precisar, conforme os limites acima; com superfície sensível, Reviewer +
Security Reviewer como análises independentes). Finding válido → Planner
delimita → Coder corrige → repete só validações e review afetados. 1ª
tentativa falhou → reavaliar evidência. 2ª falhou → parar e acionar
Debugger com evidência nova; se incerteza estrutural, Architect. 3ª
tentativa só com hipótese, informação ou estratégia nova.

Estados internos do Planner para trabalho relevante: `DISCOVERING`,
`PLANNING`, `IMPLEMENTING`, `VALIDATING`, `REVIEWING`, `FIXING`, `BLOCKED`,
`DONE`. `DONE` exige: requisitos atendidos, critérios verificados,
comportamento validado, checks executados, integração verificada, findings
resolvidos ou conscientemente aceitos, review encerrado, riscos residuais
conhecidos, nenhuma unidade essencial esquecida.

### Papéis: invariantes

- Especialistas nunca criam subagentes (`subagent_depth: 1` no
  `opencode.json` + `task: deny` nos agentes). Hierarquia rasa sempre.
- Tester valida sem modificar a aplicação (`edit: deny` + allowlist de
  `bash` só para teste/lint/typecheck/build/diagnóstico read-only).
- Reviewer é read-only e independente; ignora estilo sem impacto.
- Architect é advisor: não implementa, não edita, não coordena workers; a
  decisão final é do Planner.
- `docs-manager` (hidden) está fora do core de implementação, mas é
  seletivamente allowlisted para o Planner: atualiza documentação apenas
  quando mudança alterar API, contrato, setup, arquitetura documentada,
   operação ou comportamento público — nunca em toda mudança.

Técnica operacional reutilizável vive nas skills `dispatching-parallel-agents`,
`subagent-driven-development` e `verification-before-completion` (fonte:
`skills-core/`, sem duplicação aqui): política neste adapter,
técnica nas skills, responsabilidade de cada papel no seu prompt.

## ORCHESTRATION V3 — MAINTENANCE MODE

Status: `ORCHESTRATION V3 FINALIZED / MAINTENANCE MODE ACTIVE`. Não criar V4,
nova phase, novo Router, novo agent, novo sistema de flags, nova telemetria ou
novo framework. Estados HOLD/BLOCKED/DEFERRED são finais válidos, não pendências.

A V3 só é reaberta quando houver:

1. bug/regressão observada em produção/uso real;
2. nova capability relevante do OpenCode;
3. telemetria com padrão recorrente de classificação `WRONG`/`SUBOPTIMAL`,
   `ORCHESTRATION_POLICY_BYPASS`, fallback inadequado ou retry excessivo;
4. mudança de modelo/runtime exigindo compatibilidade;
5. nova evidência permitindo retirar HOLD/BLOCKED/DEFERRED.

Nunca implementar por hipótese.

### Métricas observacionais (não alimentam adaptive ranking)

`ORCHESTRATION_POLICY_BYPASS`; classificações emitidas pelo harness
(`GOOD`/`ACCEPTABLE`/`SUBOPTIMAL`/`WRONG`/`NOT_ENOUGH_EVIDENCE`);
`DIRECT`/fallback rate; retry rate; Debugger escalation rate; Reviewer/Security
findings por tarefa; routing latency; Router failures; Registry stale events.

### Classes de mudança futura

Toda mudança estrutural declara sua classe: `BUGFIX`, `RUNTIME_COMPATIBILITY`,
`MODEL_POLICY_CHANGE`, `ROUTING_POLICY_CHANGE`, `AUTHORITY_CHANGE`,
`FEATURE_REEVALUATION`. Somente `AUTHORITY_CHANGE` usa o mecanismo ACR;
isso não dispensa os demais gates humanos já exigidos — notadamente,
ampliações de envelope/ativação (ex. Stage 2) exigem decisão humana explícita
registrada em gate-closure, conforme as seções de Controlled Routing.

### Maintenance backlog (não implementar; reabrir só por trigger)

- Model duplication: `model:`/`mode:` no frontmatter de `source/agents/*.md`
  (canônico control-plane) duplicados em `opencode.json → agent.<nome>.model`
  /`mode` (subtree compartilhada user+control-plane; prevalece o runtime onde
  houver bloco — 15/19; os 4 planning vivem só em `.md` + allowlist).
  Ownership documentada; eliminação estrutural fora de escopo.
- DONE evidence: participação observada depende do reporting ao chamador;
  trigger: OpenCode expor session lineage/eventos melhores → reconsiderar
  runtime-backed DONE evidence.
- Deploy/production matcher: `deploy`/`production` isolados geram
  `infra_mutation`; trigger: fallback indevido observado em workload real.
- Skill Routing: trigger é observabilidade confiável de
  accepted/loaded/used/helpful. MCP: trigger é dispatch-level tool/MCP scoping
  no runtime. Adaptive: trigger é volume relevante de outcomes reais com labels
  confiáveis e distribuição suficiente entre task types (sem threshold arbitrário).
