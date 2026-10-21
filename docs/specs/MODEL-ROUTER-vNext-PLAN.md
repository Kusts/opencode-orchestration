# PLAN — Model Router vNext (planejamento futuro, SEM código/rollout)

> **HEADER EXPLÍCITO: SEM CÓDIGO / SEM ROLLOUT NESTA FASE.**
> Plano de planejamento: descreve fases FUTURAS e condicionais para a issue #99 (V2-only, V1 `LEGACY_FROZEN`).
> Nenhuma fase está autorizada; cada fase exige gate humano + evidência da anterior.
> Companion SPEC: `MODEL-ROUTER-vNext-SPEC.md`. INDEX NÃO alterado.

## 1. Estratégia

Sequência prova-primeiro: (F0) provar/refutar a capability de override no runtime V2 exato → (F1) tipar contratos em shadow sem efeito → (F2) avaliar em shadow contra `cost-to-DONE` → (F3) piloto ativo mínimo com kill switch → (F4) expansão condicional. Qualquer fase pode terminar em `PROOF_ABSENT` / `HOLD` honesto (alternativa segura SPEC §6.1) sem dívida.

Ordem respeita dependências: runtime pin (#4) e goldens (#30) antes de qualquer comparação; DecisionProvider (#6) e dispatch (#16) antes de tipar; telemetria (#48) e outcomes (#55) antes de avaliar; budgets (#61) e DONE (#62) antes de ativar; security (#78) antes de expandir.

## 2. F0 — Prova de override (pré-requisito de tudo)

**Objetivo:** responder binário: a tool nativa `subagent` do runtime V2 pinado aceita parâmetro de modelo por chamada?

**Trabalho (futuro, NÃO executar agora):**
1. Fixar runtime exato via `source/registry/runtime-versions.json` (loader `scripts/runtime/lib/RuntimeVersions.ps1`, sem fallback literal).
2. Teste mínimo: despacho `coder` com baseline `{{MODEL_CHEAP}}` vs mesma task com modelo alternativo no spawn; observar modelo efetivo da child session + recibo.
3. Registrar `PROOF` (param + valor observado + log) ou `PROOF_ABSENT` (alternativa segura SPEC §6.1 vira o caminho).

**Gate F0:** evidência runtime-exata OU `PROOF_ABSENT` documentado. Sem gate, F1+ não existem.

## 3. F1 — Contratos record-only

**Objetivo:** tipar `ModelRoutingRequest/Result` (SPEC §4) como tipos shadow: construídos, validados e logados, nunca lidos pelo despacho.

**Alterações futuras (proposta, sem aplicar):** novo lib `OrchestrationModelRouting.ps1` (construtores + validação + `user_model_override` short-circuit); nenhum campo novo em `OrchestrationNativeDispatch.ps1:791-905` nem `OrchestrationDispatchPipeline.ps1:506`; nenhum toque em `jev-advisory-policy.json` (reserva `select-model` mantida).

**Casos de teste (futuros):** request válido → envelope ok; `user_model_override` → sem consulta + `OVERRIDE_USER`; candidato fora da matriz §5 → `candidate_out_of_envelope`; confiança < 0.5 → fallback baseline; HIGH/CRITICAL sem Planner → `DENY_POLICY`.

**Gate F1:** suíte Pester verde + `git diff --check` limpo; zero mudança de comportamento (shadow puro).

## 4. F2 — Shadow eval + benchmark reproduzível

**Objetivo:** medir se a proposta valeria a pena, sem afetar nenhuma task real.

**Protocolo:**
1. Harness: golden workflows #30 (= `...-v0.1.0-SPEC.md` §24 itens 19–25: curto, SPEC+PLAN longo, failure→recovery, rotation, reuse, Jev-fallback, bloqueio seguro).
2. Shadow (F2, sem efeito): para cada workflow, ≥ 3 runs com proposta do router SOMENTE logada + despacho real sempre no baseline estático (pago-atual). Shadow NÃO autoriza claim causal de ganho — registra apenas a proposta, sem comparar braços.
3. Métricas (taxonomia `...-v0.1.0-SPEC.md` §23): primária `cost-to-DONE` (tokens + wall-clock + escalations consumidas + latência router/Jev separadas); secundárias `verified-success-rate, tokens-to-DONE, time-to-DONE, human-intervention-rate, jev-useful-call-rate`.
4. Custos (3 orçamentos — SPEC §8 item 5): cada run registra separadamente (a) baseline, (b) consultas adicionais do router/Jev, (c) escalonamentos; `max_paid_calls` conta SOMENTE (b)+(c), default `0` (esperado 0 em shadow). O benchmark executa integralmente sobre o baseline pago-atual sem autorização extra; sem autorização paga, o fallback BLOQUEIA (b)/(c) e degrada ao baseline.
5. Experimento controlado (condicional, SÓ com autorização explícita): braços baseline vs candidato nas MESMAS tasks/goldens, mesmas métricas comparáveis. SÓ este experimento pode fundamentar promoção.

**Promoção F2→F3:** SOMENTE com ganho medido em experimento controlado autorizado — `cost-to-DONE` menor com `verified-success-rate` não inferior em ≥ 2/3 runs por workflow, zero violação de cota/authority/DONE, em runtime pinado. Ganho ESTIMADO de shadow nunca promove.
**Reversão:** qualquer violação de authority/cota/DONE, `WRONG/SUBOPTIMAL` recorrente, ou latência que degrade `time-to-DONE` → `HOLD`, baseline estático mantido, sem debate.

**Gate F2:** relatório de benchmark + decisão humana explícita (ativar piloto ou HOLD).

## 5. F3 — Piloto ativo mínimo (condicional)

**Objetivo:** 1–2 classes de baixo risco (ex. `trivial → cheap`, `research → cheap`) com efeito real e kill switch.

**Alterações futuras (proposta):** leitura do `ModelRoutingResult` SOMENTE dentro do envelope piloto; cotas SPEC §4.1 enforcement; `fallback` sempre = baseline; kill switch = remover leitura (volta ao estático sem tocar registry); telemetria de `escalation_consumed` por objetivo pai.

**Gate F3:** piloto verde nos goldens + reviewer/security APPROVED + gate humano; qualquer finding sensível → reversão imediata ao baseline.

## 6. F4 — Expansão condicional

Linha por linha da matriz SPEC §5, excluídos os proibidos globais (nunca roteáveis). Cada linha: shadow → piloto → ativo, com os mesmos critérios F2/F3. `security-reviewer`, `reviewer`, `debugger`, `architect` e `infra_mutation` NUNCA saem do baseline sem SPEC própria + #78.

## 7. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Capability `subagent(model=)` não existe no V2 | F0 prova-primeiro; `PROOF_ABSENT` → alternativa segura (troca de AGENTE/estratégia, SPEC §6.1) |
| Duplicação com CapabilityRouter/DecisionProvider | Limites SPEC §3; `select-model` continua recusado no DecisionProvider/Jev |
| Custo pago silencioso | `max_paid_calls = 0` default; pago só com autorização por ambiente; auditoria por run |
| Dependência de Free permanente | Baseline atual funciona sem router; router é opcional para sempre |
| Latência Jev/router mascarando ganho | Latências medidas separadas; nunca bloqueiam despacho |
| Promoção prematura | Gates humanos por fase; reversão automática em violação |

## 8. Entregas desta fase (o que ESTE PLAN entrega agora)

- [x] `docs/specs/MODEL-ROUTER-vNext-SPEC.md` (criado nesta sessão)
- [x] `docs/specs/MODEL-ROUTER-vNext-PLAN.md` (este arquivo)
- [ ] Review do Planner (indexação em `INDEX.md` é decisão dele — NÃO fazer aqui)
- [ ] Nenhum código, flag, registry, template ou commit (proibido — cumprido)

## 9. Comando de validação (pós-escrita)

```powershell
git diff --check
powershell -NoProfile -File scripts/test-package-consistency.ps1
```
