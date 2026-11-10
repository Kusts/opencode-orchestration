# Adaptador OpenCode V2

- Versao do adapter: `v2` (runtime OpenCode generation 2, config nativo
  `agents` + `permissions` + `experimental.subagent_depth`).
- Alvo global: `%USERPROFILE%\.config\opencode\AGENTS.md` (mesmo diretorio
  do V1; o V1 e o V2 honram o config root por processo via XDG_CONFIG_HOME).
- Caminhos de skills e scripts sao IDENTICOS aos do V1
  (`%USERPROFILE%\.config\opencode\skills`, mesmos 5 skills-core; o plugin
  bundle e dual-runtime). Nada muda no filesystem entre geracoes, so o
  dialeto do config.
- Preserve o comportamento autônomo nativo do OpenCode e as extensões locais.
- A configuração MCP do `opencode.json` é preservada por merge estrutural pelo instalador do pacote (install.ps1); entradas
  desconhecidas e pertencentes ao usuário permanecem no arquivo.
  Chaves gerenciadas V2: `agents` (bloco de agentes, merge por chave:
  somente os agentes do template sao gerenciados; agentes user-owned dentro
  de `agents{}` ficam intactos), `experimental.subagent_depth`, `model`,
  `default_agent`, `$schema`. NAO gerenciadas: `mcp`, `plugin`, `skills`,
  `autoupdate` (user-owned, igual ao V1).
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
implementação concreta para o OpenCode V2 e a fonte canônica da orquestração
deste runtime. O conteúdo abaixo é renderizado para
`%USERPROFILE%\.config\opencode\AGENTS.md` e substitui o antigo
`orchestration.md` carregado via `instructions` (mecanismo V1, removido da
configuração ativa; o arquivo permanece no disco apenas como referência
histórica, sem efeito).

### Pools de modelos e Model Router vNext

- Planner (único agente primário `build`): opera com modelo econômico, capaz e estável (T2/T3);
  suporta `{{MODEL_PLANNER}}` ou `{{MODEL_STRONG}}` sem mudar o
  comportamento. Não fixe modelo frontier no perfil `build` em tempo integral nem rotacione a cada wave;
  o Planner conserva autoridade contínua sobre planejamento, delegação e continuidade.
- Roteamento adaptativo por Tiers (Model Router vNext, T0..T4):
  - **T0 (Determinístico / Reuso):** Comandos determinísticos, validação de AST, reuso exato de evidências (zero tokens).
  - **T1 (Gratuito / Ultraleve):** Triagem rápida, extração de texto, busca semântica leve.
  - **T2 (Econômico / Flash — `{{MODEL_CHEAP}}`):** Coder padrão, análises rotineiras, reviews de baixo risco.
  - **T3 (Intermediário / Capaz):** Refatorações multi-arquivo, debugging de média complexidade, revisões de arquitetura.
  - **T4 (Frontier / Raciocínio Profundo — `{{MODEL_STRONG}}`):** Impasses técnicos comprovados, decisões críticas de segurança, bugs persistentes pós-falha.
- Free worker pool — `{{MODEL_FREE}}`: `explorer`, `researcher`,
  `tester`, `docs-manager` (T1 inicial; escala para T2 apenas quando necessário).
- Cheap worker pool — `{{MODEL_CHEAP}}`: `coder`, `frontend-engineer`,
  `backend-engineer`, `database-engineer`, `ai-agent-engineer`,
  `automation-engineer`, `infra-engineer`, além dos papéis de planning
  `requirements-analyst`, `product-designer` e `skeptic`.
  Escala horizontal: evidência, volume e especialização delimitada.
- Planner `build` (primario `opencode-go/deepseek-v4.1-flash`, T2): sem fallback automático configurado.
  O modelo global e `agents.build.model` permanecem DeepSeek Go; outros agentes não herdam Luna.
  O OpenCode 2.2.5 não oferece fallback nativo de modelo primario; trocas manuais são
  necessárias. Sem prova segura de que a execucao nao comecou, nao ha replay automatico
  apos timeout ambiguo. Nunca a cadeia generica DeepSeek Go/Muse/Haiku/Luna, nunca Sonnet, nunca T3/T4
  por fallback automático.
- Nenhuma cadeia de elegibilidade abaixo e executada pelo runtime nesta versao: sao regras estaticas da politica canonica, sem retry, fallback ou override automatico.
- Researcher/Explorer/Docs Manager: T1 inicial, T2 sob escalonamento quando requerido. Tester: T0 determinístico, T1 trivial/simples, T2 não-trivial. Nenhum dos quatro usa T3/T4 automaticamente. Engineering-advisor: mínimo T3 (Sonnet primário/Terra fallback), T2 proibido.
- Elegibilidade de substituição do cheap pool (política canônica de elegibilidade por tier —
  **não** é retry/fallback/override automático; ver "Implementação nativa atual" abaixo):
  em falha de disponibilidade/erro do modelo default, a ordem candidata é estática (apenas para auditoria), **implementação em HOLD**:
  - **T1:** `opencode-go/iceman-contributor-free` → `opencode/mimo-v2.6-flash-free` (mesmo tier apenas).
  - **T2 geral:** candidatos em ordem `opencode-go/deepseek-v4.1-flash` → `opencode-go/muse-spark-1.3-contributor` → `claude-agent/haiku` → `openai/gpt-6-luna`; isto é apenas ordem estática de auditoria, a rota produtiva fica em HOLD. Capacidade Claude local e prova de no-start são condições de elegibilidade, não autorização de despacho; caller `NoExecutionStarted=true` não é prova.
    `opencode/deepseek-v4.1-flash-free` (Console) permanece desabilitado e fora de qualquer cadeia. `opencode-go/deepseek-v4.1-flash` é o primário T2 por seleção explícita do operador (adendo 2026-11-04); ZDR segue `expired-unconfirmed` sem alegação de renovação/conformidade (não envie dados sensíveis cuja proteção exija ZDR; somente dados não-sensíveis até ZDR verificado).
  - **T3:** candidatos em ordem `claude-agent/sonnet` (primário) → `openai/gpt-6.1-terra`; recuperação T2 só como candidata degradada para papéis admissíveis a T2, na ordem `opencode-go/deepseek-v4.1-flash` → `opencode-go/muse-spark-1.3-contributor`. Despacho técnico permanece HOLD sem prova independente de no-start. Engineering-advisor é T3-only.
  - **T4:** candidatos em ordem `claude-agent/opus` (primário) → `openai/gpt-6.1-sol` (mesmo tier); recuperação T2 só como candidata degradada audit-only para papéis admissíveis a T2, na ordem `opencode-go/deepseek-v4.1-flash` → `opencode-go/muse-spark-1.3-contributor` (policy-level, sem retry em runtime; reviewer high/critical, security, advisor, architect e papéis não-T2 seguem `REJECTED_DOWNGRADE_FORBIDDEN`). `openai/gpt-6-astra` somente com prova kernel-owned de falha funcional do Opus, mesma tarefa e papel admissível; `claude-agent/fable` permanece HOLD porque a prova atual é primária e não comprova falha específica do Astra. T4 não exige aprovação manual por chamada (decisão do usuário); gates de prova, capability e papel continuam.
  - Aliases `claude-agent/*` permanecem `resolution_status: runtime-unverified`;
    `catalog_inventory_id` é proveniência do inventário, nunca mapeamento.
    IDs `claude-agent/sonnet|opus|haiku|fable` exibem nomes Sonnet 5.5/Opus 5.5/Haiku 5.5/Fable 5.1 no catálogo local, todos `released=0`, `cost=[]`; outros IDs versionados não provam mapeamento dos aliases curtos. Sem prova independente, não afirmar pin/versão executada; resposta Haiku não prova passagem para Sonnet/Opus.
  - **Fallback técnico/HOLD:** `Resolve-OrchestrationModelFallback` enumera ordem para auditoria e retorna HOLD (`CandidateModel` não-autorizador, `FallbackModel=null`, `IsAuthorized=false`). Booleans `NoExecutionStarted`/erros/timeout não confiáveis; sem prova independente não há replay. `Invoke-OrchestrationModelExecution` é single-call. Capacidade produtiva de fallback permanece HOLD até prova confiável de no-start. Um teste de matriz determinístico pode reportar ordem candidata mas não faz dispatch. A ordem candidata é estática da política e a implementação permanece em HOLD.
- Implementacao nativa atual: o Planner e a propria sessao `build` (raiz do run), com
  modelo primario `opencode-go/deepseek-v4.1-flash` definido por `build.model` no `opencode.json`
  (template: `{{MODEL_PLANNER}}`); o modelo global permanece DeepSeek Go. Workers sao subagents
  filhos da sessao raiz. O Kernel liga a raiz (`bind-session`), a solta (`detach-session`)
  antes de ligar cada worker e registra model-attempt somente para filhos observados com
  `parent_session_id` igual a raiz. O dispatch externo por `opencode run` foi removido:
  a rota e recusada como ROUTE_BLOCKED_ROOT_SESSION, porque a sessao raiz nao e atribuivel.
  Escalonamentos deliberados seguem as cotas e o reset ao baseline do item
  "Escalonamentos para Astra" abaixo.
- Strong worker pool - `{{MODEL_STRONG}}`: `reviewer`, `debugger`,
  `security-reviewer` (ID canônico com hífen; `security_reviewer` com
  underscore refere-se apenas ao TOML legado do Codex), `architect`. Escala
  vertical: decisões difíceis e risco.
- Advisor Especializado Sob Demanda (`engineering-advisor`, Issue #60):
  Quando o Planner necessitar de raciocínio aprofundado diante de impasses técnicos reais ou decisões arquiteturais complexas, consulta o `engineering-advisor` sob demanda. O Advisor sempre parte de T3 Sonnet primário, Terra candidato, T2 proibido (decisão explícita ROUTER-V14-ADVISOR-T3-ONLY). Opus/Astra somente via prova kernel-owned existente. O Advisor é estritamente read-only e consultivo: produz recomendações acionáveis, mas nunca despacha workers, nunca emite DONE e nunca altera o Kernel.
- Escalonamentos para Astra são temporários, por subtarefa, via override
  no spawn — nunca editando este arquivo nem os prompts dos agentes — e
  sempre com reset ao baseline. Antes de escalar, pergunte: falta
  inteligência ou falta informação? Falta de arquivo, fluxo, log, repro ou
  documentação resolve-se com Explorer/Researcher/Debugger, não com modelo
  mais caro. Cotas conservadoras: no máximo 1 escalation ativa por
  subtarefa; por objetivo pai, no máximo 2 execuções acima do baseline, das
  quais no máximo 1 pode usar Astra. Astra substitui, não soma. Nunca
  Astra em paralelo para a mesma pergunta. Nunca Astra como fan-out.
- Prova kernel-owned (Router v1.4, sem executor/plugin/API paralelo): **somente o caminho `task-kernel model-select` com prova Task Kernel sticky autoriza escalonamento**. T3 proof usa primary `claude-agent/sonnet`; T4 proof usa primary `claude-agent/opus` e requer prova T3 anterior. Astra/Fable mantêm gates excepcionais existentes. Kernel prova via verify-run `kernel-executed` com model/provider/session/message/run/policy hash. T3 proof = `claude-agent/sonnet`, T4 proof = `claude-agent/opus`; seleção após prova T4 Opus pode selecionar Astra sob política/papel; sem aprovação manual por chamada; candidatos técnicos permanecem HOLD; Fable permanece HOLD sem prova específica do modelo.
  T3 (Sonnet) → T4 (Opus) somente com `Get-OrchestrationTaskModelFailureProof -TaskId <id> -RequiredTier T3`
  (`ok=true`, `policy_hash` igual ao da política vigente e `model`/`provider`
  canônicos de `claude-agent/sonnet` conforme policy). Opus→Astra via `task-kernel model-select` somente com
  prova `RequiredTier T4` válida da mesma tarefa (que exige T3 + Opus falhos
  persistidos; checagem T4 priorizada antes da T3 de head, sem apagar o
  histórico). Sem prova T4, Opus somente com T3 válida; sem T3, nunca T4. Astra desabilitada ou fora de
  `eligible_roles` ⇒ sem Astra (fail closed sem bypass); Fable permanece HOLD sem prova específica do modelo. Recibos/bools arbitrários (`T3FailureVerified`,
  `T3FailureReceipt`, `VerifiedFailureReceipt`), `FailureCount` e risco nunca
  autorizam T4/Astra/Fable. Candidatos técnicos (incluindo Opus→Sol) permanecem HOLD. Rota Planner-mediada: `task-kernel model-select`
  (somente leitura; retorna `tier` + `model` no formato `providerID/modelID`
  — `claude-agent/opus` em T3 válida, `openai/gpt-6-astra` em T4 válida posterior — + `policy_hash` + refs
  da prova) → Planner informa `model` verbatim na propriedade `model` da
  ferramenta nativa `subagent` → refs `session:<child>` + `message:<assistant>`
  → `task-kernel verify-run` → `model-attempt` → `model-proof`. A CLI nunca
  cria sessões. Binding produtivo PARTIAL (G1): as primitivas funcionam em runtime real (model-select, NativeDispatch com subagent.model, model-attempt, model-proof), mas a integração automática do fluxo completo (model-select → dispatch → attempt → proof → decisão) depende de comandos manuais do Planner e não está comprovada como automática. Evidência 2026-11-10: T3 dispatch real (subagente com model=claude-agent/sonnet retornou T3_DISPATCH_OK model=claude-sonnet-5-5); model-attempt registrado (attempt_n=1, model=claude-agent/sonnet, tier=T3, parent_session_id, message_id, policy_hash); model-proof verificou corretamente (PROOF_VERIFICATION_MISSING quando não há prova de falha). O fluxo manual das primitivas está comprovado; a integração automática produtiva ainda precisa ser demonstrada. Status: PARTIAL — primitivas validadas, integração automática pendente. Prova do override `subagent.model` é só do servidor OpenCode
  local vivo: `native_model_override_proven=true` somente quando a versão
  viva de `opencode api get /api/info` está exatamente na allowlist
  `2.2.5`/`2.2.6`/`2.0.23`; `runtime.profile`/`runtime.version` da task são
  metadados de observabilidade informados pelo caller e nunca autorizam;
  API viva desconhecida/indisponível falha fechada com `model` em branco.
  Suposição residual: o `/api/info` local alcança o mesmo servidor que
  recebe a chamada `subagent` subsequente (sem binding de sessão/dispatch
  provado). `DIRECT_VERIFIED` é só via classificador (trivial + baixo
  risco + motivo `DIRECT_VERIFIED_*`) e custa tokens do Planner, não é T0
  sem custo.

### Workflow Adaptativo e Rota DIRECT_VERIFIED

A imposição de subagents para qualquer alteração é substituída pelo workflow adaptativo:

1. **DIRECT_VERIFIED (Tarefas Triviais, Localizadas e Reversíveis):**
    - O Planner pode executar diretamente, sem preflight/worker/tarefa de Kernel/reviewer/worktree/PR obrigatórios, quando o classificador existente (`scripts/v3/orchestration-preflight.ps1`) reconhece o caso: mudanças cosméticas/documentação/typos e, em código funcional, **uma micro-correção que exige, no objetivo, tanto um único arquivo quanto uma única unidade de código (função, branch, condição ou expressão)**, além de um teste focado (`focused test`/`teste focado`) — os dois marcadores de escopo são obrigatórios, não alternativos — com `TaskType=trivial`, `Domain=code`, `Risk=low`, `ReadWrite=write`.
    - Se o preflight for invocado, ele deve retornar `DIRECT_VERIFIED` (`DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK`, `selected_agents=[]`) e o Planner honra zero workers; esse micro-escopo não exige preflight universal.
    - Ficam fora da rota direta, mantendo os contratos existentes de delegação, Kernel e autoridade: financeiro/pagamento/billing/pricing, permissão/auth/segurança, credenciais/segredos, produção, ações destrutivas, arquitetura, escopo amplo ou multi-arquivo/multi-módulo, feature nova, refactor, trabalho substantivo, incerto ou não trivial, concorrência e qualquer trabalho de propriedade do Kernel; o `coder` (T2) segue como implementador do trabalho substantivo rotineiro.
    - A rota direta continua sujeita às permissões nativas, limites de escrita e validação focada; não cria uma Task do Kernel nem amplia autoridade. Se o check de conformidade existente for invocado, `Test-OrchestrationDoneCompliance` valida a forma trivial/zero-worker. Trabalho fora do micro-escopo segue sua rota apropriada.
2. **SINGLE_WORKER / MULTI_WORKER (Tarefas Não Triviais):**
   - Roteamento com workers permanece disponível via runtime existente; delegação quando trouxer benefício concreto (dimensões da política compartilhada em Agent Config #21), com contratos delimitados. Sem exigência incondicional por impacto funcional.

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

### Orquestração condicional (preflight e delegação como capacidades)

Preflight (`scripts/v3/orchestration-preflight.ps1`) e delegação são
capacidades condicionais, não rito: trivial elegível segue `DIRECT_VERIFIED`
por padrão (zero workers, gate isTrivial existente, sem exigir router/registry
saudável); delegação (`SINGLE_WORKER` explícito, `MULTI_WORKER`,
`PERSISTENT_GOAL`) só com benefício concreto, com contrato limitado e
evidência. Router/registry unhealthy ⇒ `DETERMINISTIC_FALLBACK` fail-closed
para delegação e roteamento não trivial. Onde a tarefa usa o Kernel, valem os
controles existentes — CAS, evidência com refs de critério, verificação
allowlisted, review, `Test-OrchestrationDoneCompliance` no DONE gate e
autoridade do `Complete-OrchestrationTask` — sem worker exigido no trivial
direto, sem `DONE` sem participação onde worker é exigido.
Evidência: `evidence/v3/orchestration/preflight-decisions.jsonl` (+ telemetria
`cache/v3/telemetry/`).

### Planner Runtime Wiring (delegação nativa — caminho delegado)

Caminho delegado, somente quando a rota existente seleciona delegação.
Fluxo verificado no runtime V2: preflight (`orchestration-preflight.ps1`)
→ seleção do worker pela policy → chamada da tool nativa `subagent` pelo
Planner LLM → child session do worker → consumo do resultado pelo Planner
→ `Test-OrchestrationDoneCompliance` no DONE gate.

- Scripts PS nunca spawnam workers: o único Executor é o Planner LLM via
  tool nativa; scripts apenas decidem/validam (preflight, gates) e nunca
  criam sessões.
- O plugin nunca dispara workers sozinho: sem chamada do Planner, nenhum
  worker executa.
- Para cognição (ler/mapear código), prefira as tools nativas read/grep/
  glob em vez de `shell cat/ls`: menos custo e sem efeitos colaterais.
- Elegível `DIRECT_VERIFIED` não percorre estes estágios de workers; mantém
  validação focada e conformidade direta existentes
  (`Test-OrchestrationDoneCompliance -TaskClass trivial -Decision
  DIRECT_VERIFIED -ExecutionShape DIRECT_VERIFIED`).

### Controle do Planner e roteamento de especialistas de domínio

O Planner `build` é o único control plane: decide arquitetura, decompõe,
seleciona o menor grupo útil, define ownership, integra evidências e encerra
o trabalho. Workers não coordenam nem subdelegam. Para engenharia substantiva,
a delegação é condicional: o Planner avalia e usa o menor conjunto de workers
quando trouxer benefício concreto (dimensões da política compartilhada em Agent
Config #21: modelo econômico, preservação do contexto principal, isolamento de
grande volume, especialização técnica, análise/revisão independente, menor
retrabalho, paralelismo útil, qualidade e custo total até o DONE verificado);
alteração trivial e claramente localizada pode permanecer direta.

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

Papéis advisory, read-only, `permissions: [{subagent, *, deny}]`. Não são Adaptive Router;
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
- `engineering-advisor` em modo deadlock consult (#60 F2) — quando o plano
  travou: 2 tentativas sem progresso verificável, sinal `NO_PROGRESS`/ciclo
  do watchdog/telemetria, ou bloqueio por dependência/trade-off/dados
  contraditórios/hipótese esgotada (risco material comprovado dispensa
  esperar as 2 tentativas). Sem reconsulta sem evidência nova; limites de
  calls/tempo/orçamento herdados da tarefa; Jev opcional como auxiliar,
  nunca autoridade. Não usar em tarefa trivial, passo bem definido ou só
  porque a tarefa é grande. Conta como o único papel advisory da subtarefa
  (ordem de prioridade inalterada).
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
`requirements-analyst` baseline cheap → sem escalonamento para Opus/Astra; apenas dentro de seu tier admissível (T1/T2/T3 conforme policy, sem T4);
`engineering-advisor` baseline T3 Sonnet primário, Terra candidato → Opus/Astra somente via prova kernel-owned;
`product-designer` baseline cheap (sem T4; sem recomendação de Opus/Astra); `skeptic` baseline cheap (sem T4; sem recomendação de Opus/Astra). Nunca reutilize um
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
- **DIRECT:** tarefa trivial elegível => `DIRECT_VERIFIED` (zero workers), sem fan-out; `SINGLE_WORKER` explícito quando a delegação trouxer benefício concreto.
- **Escopo desta versão:** somente a área `router_active` é ativável; `skill_routing` e `mcp_routing` são hold
  incondicional; `adaptive_ranking` permanece off. Mudanças de flags são operação do mantenedor sobre o registry (`source/registry/capability-flags.json`), confinadas
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
- **Kill switch:** redefinir `capability_router.active=false` restaura
  shadow + comportamento determinístico, sem tocar
  allowlist/agentes/registry. Ativação requer registro governado do operador; `active=true` sem registro válido é
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
- **Outcome validation:** mecanismo de validação de outcomes classifica rotas propostas (GOOD/ACCEPTABLE/SUBOPTIMAL/WRONG/
  NOT_ENOUGH_EVIDENCE; `evidence_level=CONTROLLED_ROUTING`); métricas de
  execução não observadas são `NOT_MEASURABLE`, nunca inventadas. Os harnesses de outcomes não fazem parte desta distribuição (ficam no control plane de origem).
- **Skill utility:** `suggested` é observável; `accepted`/`used`/`helpful`
  são explicit-only e `loaded` exige evento nativo (senão `NOT_OBSERVED`).
  Regras de observabilidade definidas no control plane de origem; `skill_routing.enabled=false`.
- **Readiness:** veredito por categoria é emitido pelo harness de validação de outcomes (opcional, fora desta distribuição). Ativação de Stage 2 é decisão
  humana; authority inalterada.

### Controlled Agent Routing — Stage 2 (infra — definido e suportado, off por default)

Envelope Stage 2 — definido e suportado. A distribuição pública inicia com `capability_router.active=false` (shadow desligado): nada do Controlled Routing roteia numa fresh install. Quando Controlled Routing for explicitamente habilitado pelo operador, o Stage 2 adiciona `infra-planning` e `infra-implementation` ao envelope suportado. A ativação continua sendo decisão humana explícita do operador, registrada pelo mantenedor (gate closure), nunca inferência.

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
  MCP ou Skills.
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

Contrato de resultado do worker (Evidence Contract): o worker retorna SOMENTE
`candidate_pass` (candidato, com evidência reivindicada), `failed` ou
`blocked` — sempre com refs de critério (`criterion:<idx>:<evidencia>`).
O worker NUNCA emite `verified_pass`, `done` ou aprovação: `verified_pass`
vem só do verificador (`Set-OrchestrationTaskVerification`, allowlist em
`source/registry/verification-policy.json`), `DONE` só do kernel
(`Complete-OrchestrationTask`, após `Test-OrchestrationTaskCompletion`), e
aprovação só de reviewer/security-reviewer. Claim do worker é input para
verificação determinística, nunca prova.

### Ciclo, tentativas e DONE

Estágios possíveis `coder`, `tester`, `reviewer` conforme política de verificação
e risco da tarefa, sem ciclo padrão obrigatório em toda mudança (com superfície
sensível, Reviewer + Security Reviewer como análises independentes). Finding válido → Planner
delimita → Coder corrige → repete só validações e review afetados. 1ª
tentativa falhou → reavaliar evidência. 2ª falhou → parar e acionar
Debugger com evidência nova; se incerteza estrutural, Architect. 3ª
tentativa só com hipótese, informação ou estratégia nova.

Estados internos do Planner para trabalho relevante: `DISCOVERING`,
`PLANNING`, `IMPLEMENTING`, `VALIDATING`, `REVIEWING`, `FIXING`, `BLOCKED`,
`DONE`. `DONE` exige: requisitos atendidos, critérios verificados,
comportamento validado, checks exigidos executados, integração verificada, findings
aplicáveis resolvidos ou conscientemente aceitos, reviews exigidos conforme
política de verificação e risco encerrados, riscos residuais
conhecidos, nenhuma unidade essencial esquecida.

Fluxo canônico do Task Kernel (`scripts/v3/task-kernel.ps1`; detalhes em
`scripts/v3/lib/OrchestrationTaskKernel.ps1`) — caminho delegado, somente
quando a rota existente seleciona delegação e as flags relevantes estão
ativas: preflight → criar task →
planejar scopes/grants (interseção: baseline do papel ∩ grants da task ∩
capacidade do runtime ∩ ambiente; nunca união) → adquirir lease (+ worktree
quando paralelo/alto risco) → dispatch → resultado candidato →
verificação determinística allowlisted → checagens (`tester`/`reviewer`
conforme política de verificação e risco; + security quando disparado) → gate
de conclusão (`Test-OrchestrationTaskCompletion`)
→ cleanup (release do lease, remoção do worktree owned) → DONE
(`Complete-OrchestrationTask`, kernel-authorized). Orçamento de retry: 2ª
falha exige Debugger; 3ª tentativa exige evidência, hipótese ou estratégia
nova, senão EXHAUSTED (kernel-enforced). Flags `task_kernel`,
`worktree_isolation` e `runtime_grant_enforcement` iniciam OFF (shadow
rollout, Phase 19): o fluxo torna-se obrigatório somente após ativação
com evidência. Elegível `DIRECT_VERIFIED` contorna os estágios de workers
e mantém a conformidade direta existente, sem worker exigido no trivial
direto.

### Papéis: invariantes (dialeto V2)

- Especialistas nunca criam subagentes (`experimental.subagent_depth: 1` no
  `opencode.json` + `permissions: [{subagent, *, deny}]` nos agentes). Hierarquia rasa sempre.
- Tester valida sem modificar a aplicação (`permissions` sem `edit` + `shell`
  allow-default com denies de destruição/elevação/mutação Git e `ask` de
  deploy/publish).
- Debugger diagnostica sem modificar a aplicação (`permissions` sem `edit` + `shell`
  allow-default com denies de destruição/elevação/mutação Git e `ask` de
  deploy/publish).
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
`SINGLE_WORKER`/fallback rate; retry rate; Debugger escalation rate; Reviewer/Security
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
  (canônico control-plane) duplicados em `opencode.json → agents.<nome>.model`
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

### Evidência de testes (observada)
- `test-package-consistency` 16/16; `OrchestrationModelRouterMatrix` 35/35; `OrchestrationModelRouter` 107/107; V14 60/60; `OrchestrationModelRouterHaikuPlanner` 52/52 (nome legada; suíte mantém semântica alias+HOLD); `OrchestrationModelRouterModelConfig` 36/36; Kernel `OrchestrationTaskKernelModelProof` 104/104; `OrchestrationModelExecution` 36/36; `OrchestrationModelRouterKernelProof` 7/7.
- Estes valores são estado/evidência atual; não afirmar que todos rodaram contra o `head` final integrado a menos que o código esteja inalterado — revalidação final pendente. Teste de matriz determinístico reporta ordem candidata mas não faz dispatch. `AGENTS.md` continua não reconciliado por conflito de proveniência (config ativa ajustada antes; agora direcionada para `build` Luna; root Luna igual; backups/rollback em `~/.config/opencode/reconciliation-backups/`; sem restauração whole-file).
