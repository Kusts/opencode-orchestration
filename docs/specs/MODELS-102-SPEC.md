# Modelos por papel + TCO — SPEC (Issue #102)

**Projeto:** opencode-orchestration
**Versão:** 0.1 (PROPOSED)
**Tipo:** avaliação de modelos por papel (advisory-only, sem wiring)
**Status:** PROPOSED — sem implementação; nenhuma troca de modelo ativada por esta SPEC
**Escopo de escrita autorizado:** apenas este arquivo (`docs/specs/MODELS-102-SPEC.md`)

## 1. Problema

A issue #102 pede avaliar três famílias para uso por papel — **Muse Spark Open
(Muse-Spark-Open-816B-A42B)**, **Nemotron Bolt (nvidia, 74B-A9B)** e **LFM2.5
(LiquidAI, 24B-A2B)** — com matriz custo / licença / qualidade e TCO
self-host vs. vendor, sem trocar nenhum modelo em produção nesta SPEC.

Dados de partida (RES-102, a confrontar com fontes primárias na implementação):

- **Muse Spark Open 816B-A42B (+NVFP4):** MoE 816B total / 42B ativos;
  contexto 1M (prático 128–262k); licença Muse Limited Commercial —
  MaaS com receita >$20M exige acordo, exige atribuição; providers
  Baseten / Fireworks / Groq / Modal / Nebius / OpenRouter / Together;
  preço de referência ~$1.25 / $0.15 (cache) / $4.25 por 1M tokens;
  self-host ~1.5 TB em BF16 (ex.: 4×GB300 ou 32×H200 ou configuração
  equivalente).
- **Nemotron Bolt 74B-A9B 24 GB (BF16 / GGUF / LiLiCorr):** híbrido
  Mamba-Transformer; 256k contexto; licença OpenMDW-1.1 sem teto de
  receita; cabe em 24 GB locais; ~80+ TPS local.
- **LFM2.5 LiquidAI 24B-A2B:** 131k contexto; LFM Open License (teto $10M —
  acima disso exige compra/licença comercial); Console de referência
  ~$0.10 / $0.05 (cache) / $1.00 por 1M tokens.
- **TCO GPU (aluguel, $/GPU/h, referência RES-102):** H100 $2.7–4.3;
  H200 $3.6–6.3; B200 $6–8.6; GB200 ~$10.5/GPU. Custo de servir estimado:
  Muse ~$140–200+/h; Bolt ~$0.5–1/h; LFM ~$7/h.
- **Leitura inicial RES-102:** Muse = fronteira via vendor; Bolt = próprio
  em 24 GB; LFM = próprio / Console para edge.

Sem esta SPEC, qualquer experimento ad-hoc pode virar troca silenciosa de
modelo ou gasto pago sem aprovação — ambos proibidos.

## 2. Objetivo e critério de sucesso

Entregar **decisão documentada por modelo e por papel** (adotar / rejeitar /
adotar-com-fallback), com fixtures reproduzíveis offline e matriz
custo / licença / qualidade, **sem trocar modelo vigente e sem executar
teste pago** nesta SPEC.

Sucesso = cada um dos 3 modelos tem veredito explícito + fallback + gatilho
de reavaliação; qualquer leitor reproduz a matriz a partir de fixtures
versionadas sem chamar API paga; nenhum default de modelo, flag, pin ou
`agents.*.model` é alterado por esta SPEC.

## 3. Escopo e não objetivos

### Incluído

- Caracterização dos 3 candidatos (seção 5) a partir de fixtures versionadas.
- Matriz por papel do pool vigente (seção 6): Planner `build`, cheap pool,
  strong pool (`reviewer`, `debugger`, `security-reviewer`, `architect`).
- TCO vendor vs. self-host (seção 7) com calculadora offline.
- Fixtures + Golden offline (seção 8–9), sem rede, sem credencial, sem custo.
- Vereditos adotar / rejeitar + fallback por modelo (seção 10).

### Fora do escopo (não autorizar)

- **Sem troca de modelo.** Nenhuma alteração de `agents.*.model`, `model`,
  `default_agent`, pins em `source/registry/runtime-versions.json`, flags ou
  prompts de worker. Troca futura exige proposta separada + aprovação humana
  explícita (gate humano, nunca inferência desta SPEC).
- **Sem teste pago.** Nenhuma chamada a endpoint faturável, nenhuma ativação
  de trial que gere cobrança, nenhum envio de dado interno a vendor. Teste
  pago futuro exige autorização explícita de custo/ambiente antes de executar.
- **Sem wiring.** Sem `route-accept`, sem bridge de capability, sem mudança
  de envelope Stage 1/2, sem promoção de `hold-unproven`.
- **Sem relicenciamento.** Esta SPEC não interpreta licença como parecer
  jurídico; tetos ($20M Muse / $10M LFM / sem teto Bolt) são fatos a verificar
  contra o texto vigente da licença antes de qualquer uso comercial.

## 4. Invariantes

1. **Baseline vigente congela.** Até veredito aprovado e proposta de troca
   aceita, os modelos em uso não mudam.
2. **Custo zero nesta SPEC.** Toda evidência é offline (fixtures + cálculo
   determinístico). Qualquer passo que custe dinheiro fora de fixtures = fora
   do escopo, proibido sem aprovação prévia.
3. **Licença antes de uso.** Nenhum "adotar" vira deploy sem checagem da
   licença vigente (texto + teto + atribuição + MaaS) contra o caso de uso real.
4. **Qualidade se prova, não se alega.** Veredito de qualidade exige Golden
   offline +, quando autorizado no futuro, avaliação paga/aprovada em runtime
   exato; nunca só tabela de marketing.
5. **Fallback obrigatório.** Todo "adotar" nomeia o fallback (modelo +
   superfície) para indisponibilidade, degradação ou veto de licença/custo.
6. **Reprodutibilidade.** Mesmas fixtures + mesmo script = mesma matriz.
   Sem rede, sem relógio, sem aleatoriedade não semeada.

## 5. Caracterização dos candidatos (fixtures)

Cada candidato tem uma fixture JSON versionada (a criar na implementação,
fora desta SPEC; aqui o schema exigido):

```json
{
  "model": "<id>",
  "params_total": "<ex. 816B>",
  "params_active": "<ex. 42B>",
  "quant": ["BF16", "NVFP4", "GGUF"],
  "ctx_claimed": 1000000,
  "ctx_practical": [128000, 262000],
  "license": { "name": "Muse-Limited-Commercial | OpenMDW-1.1 | LFM-Open",
               "revenue_cap_usd": "20000000 | null | 10000000",
               "attribution": true, "maas_clause": true },
  "vendor_pricing_per_1M": { "input": 1.25, "cached": 0.15, "output": 4.25 },
  "selfhost": { "vram_tb_bf16": 1.5, "reference": "4xGB300 | 32xH200" },
  "sources": ["<url + data de acesso>"]
}
```

Valores iniciais (RES-102, a reconfirmar contra fonte primária):

| Modelo | Total / ativos | Quant | Ctx | Licença | Vendor ref. $/1M | Self-host |
|---|---|---|---|---|---|---|
| Muse-Spark-Open-816B-A42B | 816B / 42B | BF16 + NVFP4 | 1M (prático 128–262k) | Muse Limited Commercial (MaaS >$20M = acordo; atribuição) | ~1.25 / 0.15 / 4.25; 7 providers listados | ~1.5 TB BF16; 4×GB300 ou 32×H200; ~$140–200+/h servir |
| Nemotron Bolt 74B-A9B | 74B / 9B | BF16 / GGUF / LiLiCorr | 256k | OpenMDW-1.1, sem teto | local (sem vendor obrigatório) | 24 GB; 80+ TPS; ~$0.5–1/h |
| LFM2.5 24B-A2B | 24B / 2B | — (verificar) | 131k | LFM Open ($10M teto; acima = comprar) | Console ~0.10 / 0.05 / 1.00 | próprio / Console edge; ~$7/h servir |

## 6. Matriz custo / licença / qualidade por papel

Papéis vigentes: Planner `build` (herda sessão); cheap pool (`explorer`,
`researcher`, `coder`, `tester`, `docs-manager`, especialistas de domínio);
strong pool (`reviewer`, `debugger`, `security-reviewer`, `architect`).

| Papel | Muse-Spark-Open | Nemotron Bolt | LFM2.5 | Leitura inicial (hipótese a provar) |
|---|---|---|---|---|
| Planner `build` (fronteira, contexto longo) | vendor $1.25/4.25; ctx prático 128–262k; licença com teto MaaS | 256k, barato, mas 74B — capacidade de planning a provar | 131k, edge — janela curta p/ planning grande | Muse candidato; Bolt/LFM só se Golden de planning passar |
| Cheap (`coder`, `explorer`, `tester`, domínio) | overkill/caro p/ volume; bom p/ tarefa dura | **melhor ajuste esperado:** 24 GB local, 80+ TPS, sem teto | edge/barato; bom p/ tarefas curtas e locais | Bolt primeiro; LFM para edge/curto; Muse sob demanda |
| Strong (`reviewer`, `debugger`, `security`, `architect`) | **melhor ajuste esperado:** fronteira p/ decisão irreversível | insuficiente como única autoridade forte até prova | insuficiente como única autoridade forte até prova | Muse; Bolt/LFM no máximo como pré-triagem sem autoridade |
| Edge / offline / air-gap | inviável self-host (1.5 TB) | **adotar:** 24 GB local | adotável onde 131k basta | Bolt default edge; LFM quando envelope menor ok |

Qualidade: colunas acima são hipótese RES-102. Veredito final exige Golden
offline por papel (ex.: planning com 128k fixture, review com diff fixture,
coder com repo fixture) — sem chamar vendor pago nesta SPEC.

## 7. TCO (vendor vs. self-host, referência)

Premissas RES-102 (a reconfirmar; calculadora offline deve parametrizá-las):

- Aluguel GPU $/GPU/h: H100 2.7–4.3; H200 3.6–6.3; B200 6–8.6; GB200 ~10.5.
- Servir: Muse ~$140–200+/h (ex.: 32×H200 a ~$4.4–6.3 = ~$140–200/h);
  Bolt ~$0.5–1/h (1× GPU 24 GB classe); LFM ~$7/h.
- Vendor por token: Muse ~1.25/4.25; LFM Console ~0.10/1.00.

Regra de decisão (a codificar na calculadora offline):

- **Muse:** vendor até o volume em que `tokens/mês × preço vendor`
  cruzar `servir próprio + opex`; acima disso, só com acordo MaaS (teto
  $20M) assinado. Self-host só com cluster já amortizado.
- **Bolt:** próprio por default (marginal ~$0.5–1/h); vendor só se existir
  oferta pontual mais barata que o kWh local — improvável.
- **LFM:** Console para esporádico/edge; próprio quando uso contínuo
  superar ~$7/h equivalentes em tokens.

A calculadora recebe `{tokens_in, tokens_out, cache_hit, horas_serving,
preço_gpu, opex}` e devolve `vendor_total vs. selfhost_total + break-even`,
determinístico, sem rede.

## 8. Contrato funcional desejado (implementação futura, fora desta SPEC)

1. `fixtures/models-102/*.json` — uma por candidato, com `sources[]`
   (URL + data) e valores da seção 5.
2. `scripts/v3/models-102-matrix.ps1` (ou equivalente) — lê fixtures,
   aplica matriz da seção 6 e TCO da seção 7, emite `matrix.json` + `tco.json`
   determinísticos (ordenação estável, sem rede, sem segredo).
3. Golden offline: fixture de planning/review/code por papel × 3 modelos
   (respostas gravadas, não chamadas live); asserts de veredito + fallback.
4. Nenhum step toca `agents`, flags, pins, registry ou rede faturável. Teste
   que detectar chamada paga = FAIL.

## 9. Golden test + fallback/rollback

**Golden (hermético):** fixtures mínimas (1 planning 100k, 1 review com
finding plantado, 1 tarefa cheap) × 3 modelos com respostas gravadas;
a matriz emitida deve seguir as regras das seções 6–7 e 11, verificadas
com expectativas independentes por cenário: cenário com evidência
aprovada gera adotar / adotar-com-fallback com fallback nomeado;
cenário com qualidade reprovada, fixture `UNVERIFIED`, veto de licença
ou estouro de TCO gera rejeitar ou `MODEL_BLOCKED:<licença|custo>` +
baseline vigente; qualquer divergência da regra = FAIL. Nenhum cenário
exige adoção predeterminada — recomendações reais seguem bloqueadas até
evidência (seção 11). Asserts negativos: nenhuma mutação de
`agents`/flags/pins; nenhuma chamada de rede; nenhum segredo em log.

**Fallback (runtime):** por veredito — Muse indisponível/vetado →
fallback para baseline vigente (nunca troca automática para outro
candidato); Bolt/LFM indisponível → baseline vigente; veto de licença ou
estouro de TCO → `MODEL_BLOCKED:<licença|custo>` + baseline.

**Rollback:** não há o que reverter nesta SPEC (nenhum default muda).
Proposta futura de troca deve incluir interruptor único (flag OFF por
padrão) e reversão limpa ao baseline.

## 10. Requisitos e aceite

| ID | Critério |
|---|---|
| AC-01 | As seções 5–7 estão preenchidas a partir de fixtures versionadas com fonte + data; valores RES-102 reconfirmados ou marcados `UNVERIFIED`. |
| AC-02 | Matriz por papel (seção 6) com veredito explícito por modelo: adotar / rejeitar / adotar-com-fallback, cada "adotar" com fallback nomeado. |
| AC-03 | Calculadora TCO offline reproduz `vendor_total vs. selfhost_total + break-even`; mesmos inputs = mesmos outputs, sem rede. |
| AC-04 | **Sem troca:** `git diff` desta SPEC não altera `agents`, flags, pins, prompts, grants ou defaults de modelo. |
| AC-05 | **Sem gasto:** nenhuma evidência exige chamada paga; Golden é 100% offline; qualquer teste pago futuro está marcado `REQUIRES_APPROVAL` e fora do aceite desta SPEC. |
| AC-06 | Licença: cada "adotar" registra teto/condição (Muse $20M MaaS + atribuição; LFM $10M; Bolt sem teto) e o gatilho de rechecagem do texto vigente. |
| AC-07 | `git diff --check` limpo; apenas este arquivo tocado; nenhum commit por esta SPEC. |

## 11. Segurança e modos de falha

Cobrir: fixture sem fonte (→ `UNVERIFIED`, bloqueia "adotar"); licença
vencida/alterada (→ rechecar texto vigente, veredito cai para
`adotar-com-fallback` ou `rejeitar`); teto de receita atingido (Muse/LFM →
`MODEL_BLOCKED:licença`); break-even calculado com GPU errada (parametrizar
H100/H200/B200/GB200, nunca literal fixo); contexto prático < alegado
(128–262k vs. 1M — planejar pelo prático); quant não disponível no alvo
(NVFP4/GGUF/LiLiCorr — recusar deploy, não improvisar); vazamento de dado
interno para vendor em futuro teste pago (exige aprovação + sanitização +
canário, nunca dado real); log com segredo (FAIL).

## 12. Baseline de runtime e limitações observadas

- Modelos vigentes e pins em `source/registry/runtime-versions.json`; loader
  fail-closed. Esta SPEC não altera nenhum.
- Preços GPU e de token são referência datada (2026-10-21, RES-102) —
  voláteis; a calculadora deve aceitar parâmetros, nunca congelar literal.
- Contexto "1M" do Muse é teto de marketing; planejar pelo prático
  128–262k até prova em runtime exato.
- Licenças resumidas aqui não substituem o texto vigente; rechecagem
  obrigatória antes de qualquer uso além de avaliação offline.

## 13. Classe e decisão de escopo

Classe: `FEATURE_REEVALUATION` (avaliação, sem autoridade). Nenhuma troca de
modelo, ativação de flag, mudança de pin/grant ou teste pago é autorizada por
esta SPEC. Troca futura = proposta separada + gate humano com evidência
(Golden offline + avaliação aprovada em runtime exato + checagem de licença +
TCO assinado). Ativação em ambiente real é decisão de operador, nunca
inferência desta SPEC.
