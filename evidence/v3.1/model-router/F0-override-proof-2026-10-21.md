# F0 — Override de modelo POR DELEGAÇÃO no runtime OpenCode V2 exato 2.0.23

- **TASK_ID:** F0-99 (issue #99, Fase F0)
- **Veredito: PROVEN** — override de modelo por chamada é suportado no 2.0.23, sem alterar defaults.
- **Data:** 2026-10-21 · **Escopo:** somente leitura; nenhum install global; tarball só em TEMP aprovado.

## 1. Artefato examinado (runtime exato)

- Pin canônico: `source/registry/runtime-versions.json` → `runtimes.v2.spec = "@opencode/cli@2.0.23"`.
- `npm pack @opencode/cli@2.0.23 --pack-destination C:/Users/walis/AppData/Local/Temp/opencode/F0-99`
  → wrapper de 2,4 kB (`package/bin/opencode.exe` = shim de 229 bytes; `postinstall.mjs` baixa o binário da plataforma via `optionalDependencies`).
- `npm pack @opencode/cli-windows-x64@2.0.23` (mesmo destino TEMP) → `opencode-cli-windows-x64-2.0.23.tgz`
  (92 442 093 bytes; shasum `edc9b4d78f10855523dd85e910be90fe5eb5dc`; `integrity: sha512-X9yJUAfk5fS2[...]MMDU+c75s97Ww==`).
- Binário extraído só em TEMP: `extr/package/bin/opencode.exe` (**206 234 504 bytes**).
- Identidade do binário: `./extr/package/bin/opencode.exe --version` → `opencode v2.0.23` (confere com o pin).

## 2. Prova no bundle: schema da tool `subagent` tem `model` opcional por chamada

Localização: dentro de `extr/package/bin/opencode.exe` (offsets decimais do binário):

- **Schema de input (offset ≈ 149894172):**
  `LI=o({agent:t.annotate({...}), description:t.annotate({...}), prompt:t.annotate({...}), model:We(t).annotate({description:'NEVER set this unless the user explicitly asks for a particular model or variant. The value is written as "providerID/modelID", or "providerID/modelID#variant" to include a variant. Do not guess the ID: look the model up with the models tool, filtering to your own provider first.'}), sessionID:We(At).annotate({...}), background:We(j).annotate({...})})`
  (`We(...)` = wrapper de opcional; `agent`/`description`/`prompt` obrigatórios, `model`/`sessionID`/`background` opcionais.)
- **Registro da tool (offset ≈ 149895631):**
  `QI={id:"opencode.tool.subagent", effect:u("SubagentTool.Plugin")(function*(e){...` com
  `y.add({name:Dl /* "subagent" */, options:{codemode:!1}, description:EI, input:LI, output:$I, execute:...})`.
  Descrição da tool (`EI`): `"Spawns an agent in a child session to work on the specified task."` + continuação de sessão via `sessionID` + modos foreground/background.
- **Resolução/validação do modelo (`SubagentTool.resolveModel`, mesmo trecho):**
  parse `DT.parse(y)`; erro se inválido: `Invalid model "${y}". Use "providerID/modelID" or "providerID/modelID#variant".`;
  confere existência em `available()` (`providerID`+`id`) e existência da `variant`; erros orientam usar a tool `models`.
- **Semântica de execução (mesmo trecho, `execute`):**
  `let B=f.model===void 0?void 0:yield*_(f.model)` (só resolve quando o chamador passou `model`);
  sessão nova: `let Y=B??K.model??S.model` + `a.create({parentID:M.sessionID, title:f.description, agent:..., model:Y})`
  → **precedência: modelo da chamada > modelo configurado do agente > modelo da sessão pai**;
  continuação: `switchModel({sessionID:U.id, model:Fe})` com `Fe=B??(trocou de agente ? K.model : void 0)`.
- **Hook `execute.before` (offset ≈ +4000 do trecho):** só normaliza `""` → remove `model`/`sessionID` vazios; **não** proíbe combinar `model` + `sessionID`.
- **Consumo no TUI (offset ≈ 146578400):** `Pt(i.input.model)`, `Pt(i.input.agent)??Pt(i.input.subagent_type)`, `Pt(i.input.description)`, `Pt(i.input.sessionID)` — o input por chamada carrega `model` (exibido como badge `· model` no item "Delegating…/Continue subagent").
- **Compat/migração V1→V2 (offset ≈ 96681997):** `The 'subagent' tool takes 'agent' instead of 'subagent_type' and 'sessionID' instead of 'task_id'.` (+ `c0={bash:"shell", task:"subagent", ...}` em 149725681: a tool V1 `task` é a tool V2 `subagent`).
- **Guards preservados:** `subagent_depth` (default 1, checado em `execute`: `Subagent depth limit reached...`); `Agent ${f.agent} cannot run as a subagent` para `mode==="primary"`; permissão `subagent` por agente (nosso `templates/opencode.v2.json.tmpl` já libera `build → *`).

## 3. Corroboração oficial (docs, 2026-10-21)

- V2 `https://opencode.ai/v2/docs/agents/` → seção **Model**: `model: provider/model` com `#variant` opcional; **"A subagent uses its configured model, or inherits the parent session's model when none is configured."** — consistente com `Y=B??K.model??S.model` quando `model` é omitido; o bundle prova o terceiro nível (override por chamada) que a doc de agentes não detalha por chamada.
- V1 `https://opencode.ai/docs/agents/` confirma o formato `provider/model-id` e herança por omissão (mesma semântica).
- Nota: issues públicas pedindo seleção dinâmica de modelo via Task (#6651) e atrito no path SDK (#18615) referem-se a outros surfaces/versões; **não** invalidam o observado no bundle 2.0.23 da tool `subagent` (schema + resolve + `B??K.model??S.model` + `switchModel`).

## 4. Esquema exato do parâmetro + exemplo mínimo + limites

- **Parâmetro:** `model` (string, opcional) no input da tool `subagent`.
- **Formato:** `"providerID/modelID"` ou `"providerID/modelID#variant"` (ex.: `"openai/gpt-6.1-sol"`, `"openai/gpt-6.1-sol#high"` — IDs reais via tool `models`, filtrando o próprio provider primeiro; nunca adivinhar).
- **Exemplo mínimo de chamada (1 chamada, sem tocar config):**
  `subagent({ agent: "reviewer", description: "Review auth diff", prompt: "...", model: "openai/gpt-6.1-sol" })`
  (omitir `model` = comportamento atual inalterado: usa `K.model ?? S.model`).
- **Escopo da chamada:** em sessão nova e independente criada naquele `execute`, vale só para aquela child; cada nova delegação sem `model` volta ao default — **reset automático, sem alterar `opencode.json`/template/flags**. Em continuação via `sessionID` com `model`, o `switchModel` **PERSISTE na child continuada** — quando aplicável, exigir restauração explícita ao baseline.
- **Limites:** modelo/variante precisa existir em `models` (senão erro fail-closed com mensagem); `subagent_depth` (default 1) continua bloqueando sub-nesting; agente `primary` não roda como subagent; permissão `subagent` do agente-pai continua exigida; o texto do schema ("NEVER set this unless the user explicitly asks...") é guardrail de prompt e **não** há bloqueio de runtime — capacidade técnica separada de autorização. Autorização segue a policy vigente: override temporário no spawn com reset ao baseline, cotas e decisão humana onde exigido (ex.: exceção Astra). Decisão do Planner **não** equivale a pedido explícito do usuário.

## 5. Comandos executados (saídas reais citadas acima)

1. `npm pack @opencode/cli@2.0.23` → tarball 2,4 kB, `opencode-cli-2.0.23.tgz`, shasum `9432bf7f...`.
2. `npm pack @opencode/cli-windows-x64@2.0.23` → `opencode-cli-windows-x64-2.0.23.tgz` (92 442 093 bytes).
3. `tar -tzf` → `package/package.json` + `package/bin/opencode.exe`.
4. `./extr/package/bin/opencode.exe --version` → `opencode v2.0.23`; `--help` lista subcomandos V2 (`serve`, `acp`, `debug agents`, ...).
5. Scans Python por `subagent` (273 hits), `input.model` (2 hits), `opencode.tool.subagent` (2 hits), `Continue subagent` (2 hits) → trechos citados na §2.
6. `git diff --check` → limpo (sem saída); `git status --short` → limpo antes e depois (só este arquivo novo).

## 6. Impacto no PLAN (F1+ — decisão separada, não liberadas por este doc)

Com o veredito PROVEN, o suporte está **identificado ESTATICAMENTE no bundle 2.0.23** (schema + resolve + precedência + `switchModel`): base de runtime confirmada no pin exato, sem edição de config. **Sem prova comportamental de delegação/reset live neste doc.** F1+ depende de decisão separada (possível spike comportamental) e **não** está liberada por este doc. Nenhuma troca de agente/estratégia alternativa foi necessária para este veredito estático.
