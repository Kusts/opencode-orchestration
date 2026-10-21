# F1 — Spike comportamental: override de modelo por delegação (Beam Free, live)

- **TASK_ID:** F1-99-REC (issue #99, Fase F1)
- **Veredito: F1-CONSISTENT** — metadados locais consistentes com execução efetiva no Beam (parâmetro `model` aceito sem erro + tarefa mínima concluída + registro requested §5 + self-ID distinto §6 + custo zero §7); os três sinais vêm do MESMO banco local (`session_v2` do `opencode.db`) — não são independentes; `cost` pode refletir preço configurado do modelo solicitado, não execução independente; a projeção $0.0118 é estimativa (mix input/output difere do controle). Identidade efetiva NÃO comprovada, fallback NÃO excluído; sem logs de execução do provider, certeza dedutiva é impossível de fora. Permanecem os limites de §4 (n=1, sem medição de latência, reset não testado). Este doc não autoriza F2.
- **Data:** 2026-10-21 · **Escopo:** somente registro; spike já executado pelo Planner com autorização explícita do usuário; este doc não autoriza F2.

## 1. Catálogo (models.dev)

- `opencode-go / beam-free` existe no catálogo models.dev (16 hits "beam" no catálogo).
- OpenRouter só tem `reflection/beam-1.0-501b-a23b` pago ($0.30/1M), sem `:free` — Beam Free é via opencode-go.

## 2. Delegação executada (pelo Planner)

- `subagent` com `agent=explorer`, `model=opencode-go/beam-free`, sessão nova (sem `sessionID`).
- Tarefa read-only: ler `VERSION` e retornar o conteúdo.

## 3. Resultado

- `STATUS=candidate_pass`, `RESULT=0.2.0`.
- Confirmado contra leitura direta do Planner: `D:/projetos/opencode-orchestration/VERSION` = `0.2.0`.
- Sem anomalia.
- Sem alterações rastreadas observadas: `git status` só `?? evidence/v3.1/model-router/`, diff limpo. Config externa/ignored não foi comparada antes/depois; um teste completo compararia `opencode.json` ativo, `models.jsonc` local, env de modelo, cache/telemetria local e `.ai-memory.toml`.

## 4. Limites explícitos

- 1 delegação mínima (n=1); sem medição de custo/latência do spike.
- Modelo real usado não visível ao worker (`MODEL_USED` não observável). Gap para comportamento provado: tarefa que só o modelo alvo responderia de forma distintiva, ou telemetria requested/actual (modelo solicitado vs efetivo).
- Reset pós-spike não testado nesta rodada (sessão filha descartada).
- **Não autoriza F2** — fases seguintes dependem de decisão separada.

## 5. Prova distintiva (requested/actual)

- Sessão do spike `ses_ea076ffa`: `agent=explorer`, `model={"id":"beam-free","providerID":"opencode-go"}`, `cost=0.0`, `tokens_input=45604`, `tokens_output=100`, `has_parent=1`.
- Sessões vizinhas de controle mostram os modelos esperados de cada papel (ex. `coder`/`tester`=`muse-spark-1.3-contributor`/`opencode-go`; `reviewer`=`gpt-6.1-sol`/`openai`) — o registro distingue papéis e modelos, não é valor fixo.
- Fonte: tabela `session_v2` do `opencode.db` local (colunas `id`/`agent`/`model`/`cost`/`tokens`/`time_created`); nenhum conteúdo de mensagem lido; nenhuma credencial tocada.
- Interpretação: o `model` solicitado (`opencode-go/beam-free`) foi registrado como modelo da sessão filha — consistente com execução no Beam, sem excluir fallback/ignorado, no escopo de n=1 (ver veredito recalibrado no cabeçalho e §§6–7; sem logs do provider, certeza dedutiva segue impossível).

## 6. Prova comportamental (self-ID distintivo)

- Prompt idêntico, tarefa sem I/O (sem ferramentas), sessão nova:
  - SELFID-BEAM (`model=opencode-go/beam-free`): ANSWER=`Sou o Beam Free`.
  - SELFID-BASE (sem override, default cheap): ANSWER=`Sou o Muse Spark 1.3 Contributor` (STATUS truncado na entrega; ANSWER registrado como parcial — basta como distinção).
- A diferença de resposta sob prompt e tarefa idênticos é consistente com modelos distintos executando, mas também compatível com amostragem/contexto; self-ID não autentica modelo — sinal sugestivo, não prova, e não independente do registro do §5 (mesmo banco local `session_v2`).
- Veredito final ajustado: **F1-CONSISTENT** — metadados locais consistentes com execução efetiva no Beam (registro §5 + comportamento distinto §6 + contabilidade §7, todos do mesmo banco local), identidade efetiva NÃO comprovada, fallback NÃO excluído, mantendo os limites do §4 (n pequeno, sem latência, reset não testado) e sem autorizar F2. Os rótulos anteriores "DISTINCT-PROVEN" e "STRONGLY-CORROBORATED" ficam retirados por overstated: sem logs de execução do provider, a certeza dedutiva é inalcançável de fora.

## 7. Evidência contábil (mesmo banco local `session_v2` — não independente)

- Spike `ses_ea076ffa`: `tokens_input=45604`, `tokens_output=100`, `cost=0.0`.
- Controle mesma provider/família (`ses_ea07596b`, coder `muse-spark`): `in=4456`, `out=1410`, `cost=0.00151472` → ordem de grandeza ~2.6e-7 USD/token.
- Contas (projeção sob hipótese de fallback para `muse-spark`):
  - Controle: tokens totais = 4456 + 1410 = 5866; custo/token médio = 0.00151472 / 5866 ≈ 2.58e-7 USD/token.
  - Spike: tokens totais = 45604 + 100 = 45704; projeção ≈ 45704 × 2.58e-7 ≈ **$0.0118**.
  - Observado: `cost=0.0`. A precisão da coluna vai a 1e-6 (outros rows exibem p.ex. `0.00059`); $0.0118 jamais arredondaria para `0.0`. A projeção $0.0118 é estimativa (mix input/output do spike difere do controle).
- Interpretação honesta: registro, self-ID e custo vêm do MESMO banco local (`session_v2`); `cost=0.0` pode refletir preço configurado do modelo solicitado, não execução independente — consistente com execução em modelo de custo zero, sem excluir fallback.
- Residual: sem logs de execução do provider, certeza dedutiva é impossível de fora; veredito = **F1-CONSISTENT** (metadados locais consistentes com execução efetiva no Beam, identidade efetiva NÃO comprovada, fallback NÃO excluído).
