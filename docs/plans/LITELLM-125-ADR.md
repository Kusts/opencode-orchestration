# ADR — LiteLLM (issue #125): virtual-keys x OAuth, isolamento e stateless

**Issue:** #125 — LiteLLM como gateway (virtual keys + OAuth/SSO, isolamento multi-tenant, operação stateless).
**Decisão:** **ADOPT condicional** — adotar desenho abaixo somente após spike de isolamento verde; sem spike, HOLD.
**Status:** ADR registrada; nenhum código, nenhuma flag, nenhum deploy por este documento.
**Escopo deste documento:** registrar baseline pinado, matriz virtual-keys x OAuth, modelo de identidade,
regras de isolamento e critérios do spike. **Sem** implementação, sem credencial, sem merge.

## 1. Baseline pinado (AC: versão pinada)

- **Pin: `v1.107.0` final, 2026-10-21.** Não usar `v1.107.0-RC` (candidata de 18/10) como prova:
  RC ≠ final; evidência de RC não transfere para o final.
- Proibido presumir comportamento de versão posterior ou de `main` — revalidar no binário `v1.107.0` exato.
- Capacidades consideradas neste ADR (a confirmar no binário pinado durante o spike, §7):
  `ID-JAG` backport, OAuth `delegate` + `dcr_bridge`, scope consent, DCR persist,
  JWT subjects, trace IDs, custom key header.
- Qualquer divergência entre doc upstream e binário `v1.107.0` → vale o binário; registrar como gap.

## 2. Matriz virtual-keys x OAuth (AC: matriz)

Modos avaliados (5). Linhas = modo OAuth; colunas = como a virtual key participa.

| # | Modo OAuth | Virtual key | Troca / emissão | Uso por chamada | Veredito |
|---|---|---|---|---|---|
| M1 | `client_credentials` (2-legs, machine) | key de serviço por workload | IdP emite token de app; gateway mapeia key → app/tenant | `Authorization: Bearer <idp-token>` a montante; key do cliente **nunca** em `Authorization` a montante (§9) | **ADOPT-ready** (caso base machine-to-machine) |
| M2 | `auth_code + PKCE` (usuário interativo) | key por usuário/sessão (machine-user pattern, §4) | login do usuário via IdP; gateway guarda sessão/token por usuário, não por key armazenada | token do usuário propagado ou delegado conforme §5; consent por scope obrigatório | **ADOPT condicional** (exige consent + DCR persist provados no spike) |
| M3 | `token_exchange` (OBO, on-behalf-of) | key do chamador preservada como identidade de origem | troca token do chamador por token delegado com audience/scope reduzido | downstream recebe token delegado; auditoria carrega subject original + subject delegado (JWT subjects) | **ADOPT condicional** (exige subjects + trace IDs provados) |
| M4 | `id_jag` 2-legs (backport) | key de serviço com asserção JAG | emite/usa asserção `ID-JAG` no fluxo 2-legs | valida asserção no gateway antes de delegar | **HOLD até probe** — backport é a peça mais frágil; sem prova no `v1.107.0` final, não usar |
| M5 | `passthrough` vs `delegate` + `dcr_bridge` | passthrough: key só identifica; delegate: gateway obtém token | `dcr_bridge`: gateway registra cliente via DCR e persiste registro (DCR persist) | passthrough nunca injeta credencial nova; delegate sempre com scope mínimo + consent | **passthrough OK; delegate + `dcr_bridge` condicional** (exige DCR persist + consent no spike) |

Regras transversais da matriz:

- **Sem per-key armazenado presumido:** não existe segredo por key persistido no gateway salvo prova
  explícita no spike. Padrão obrigatório = **machine user pattern** (§4).
- **Sem `Authorization` com `sk-`:** nenhuma virtual key (`sk-…`) viaja em header `Authorization`
  para montante/IdP. Key do cliente entra por custom key header dedicado; `Authorization`
  carrega exclusivamente token/asserção do fluxo OAuth vigente (§9).

## 3. Modelo de identidade per-user / per-key

- **per-user:** identidade = subject JWT do usuário (login M2 / OBO M3). Sessão/token por usuário.
- **per-key (sem per-key armazenado):** key é identificador opaco → resolvida a cada chamada para
  (tenant, app/usuário-máquina, scopes) via Postgres/Redis (§5). **Não** presumir coluna/coleção
  de segredo por key; se o binário exigir, tratar como gap bloqueante e redecidir.
- **machine user pattern:** workload = "usuário-máquina" com `client_credentials` (M1) ou
  asserção JAG (M4); um workload nunca assume subject de usuário humano sem `token_exchange`
  explícito (M3) com consent/scope.
- JWT subjects e trace IDs devem acompanhar cada decisão (quem chamou, em nome de quem,
  qual fluxo) para auditoria ponta a ponta.

## 4. Isolamento tenant + stateless

- Hierarquia: **Org > Team > User > Key**. Enforcement por `object_permission` em cada nível;
  chamada fora do boundary = negar.
- Sinais de negação/falha a observar no spike (sem inventar semântica além do binário):
  `401` (identidade inválida/ausente), `412` (pré-condição de isolamento/escopo não atendida),
  `503` (dependência de estado indisponível). Resposta deve carregar `_meta` agregado
  (tenant/fluxo/decisão) **sem vazar segredo**.
- Stateless operacional: Postgres + Redis como único estado; `DISABLE_SCHEMA_UPDATE` ligado
  em réplicas; **2+ réplicas**; cache/estado transitório com **TTL 60s**; nenhuma sessão
  local pegajosa presumida.

## 5. Spike de isolamento (AC: critérios 401/412/503 + reconvergência ≤ 60s)

Pré-requisito: binário `v1.107.0` final + Postgres + Redis + IdP de teste. Proibido atalho
sem IdP real (mock só para fumaça, não é prova).

1. **Isolamento negativo:** key do Tenant A chama recurso do Tenant B (cada nível
   Org/Team/User/Key) → esperado negar com `401`/`412` conforme camada, com `_meta` agregado
   sem segredo. Falha aberta ou vazamento entre tenants = spike FAIL.
2. **Matriz positiva:** um caso verde por modo M1–M5 (M4/M5-delegate podem registrar
   `blocked-parcial` com motivo se o binário não suportar; nunca alegar verde sem prova).
3. **`object_permission`:** negar acesso a objeto fora do grant mesmo com token válido → `412`.
4. **Resiliência:** derrubar 1 réplica / Redis primário → esperado `503` transitório com
   `_meta`; ao restaurar, **reconvergência ≤ 60s** (coerente com TTL 60s) sem intervenção
   manual e sem sessão presa a réplica.
5. **DCR/consent (M2/M5-delegate):** registrar cliente via `dcr_bridge` → restart do gateway →
   registro persiste (DCR persist); scope consent negado → chamada negada.
6. **Auditoria:** cada chamada do spike exibe JWT subjects + trace IDs ponta a ponta.

Critério de saída: 1–6 verdes (com parciais documentados só em M4/M5-delegate) ⇒ ADOPT
condicional vira plano; qualquer FAIL em 1, 3 ou 4 ⇒ HOLD, sem promoção.

## 6. Bug #36358 — checar

- Antes de qualquer plano: verificar no tracker upstream o status de **#36358** contra o
  binário `v1.107.0` final (aberto/corrigido/afetado, versão do fix, workaround).
- Se #36358 afetar qualquer capacidade das §§2–5 no `v1.107.0`: registrar severidade,
  aplicar workaround documentado ou manter HOLD até fix pinado. Não presumir correção por
  versão posterior.

## 7. Segurança — sem vazar key em `Authorization`

- **REJECT** qualquer desenho que encaminhe virtual key (`sk-…`) em header `Authorization`
  para montante/IdP/logs/telemetria.
- Key do cliente: exclusivamente via custom key header dedicado, redigido em log/telemetria.
- `Authorization` a montante: só token/asserção do fluxo vigente (M1–M5), com scope mínimo.
- Segredos (client secret, DCR seed, chaves de assinatura) via env do runtime; nunca em doc,
  log, `_meta` ou lockfile.

## 8. Esforço, dependências, fora de escopo

- **Esforço: M.** Motivo: 5 modos + isolamento 4 níveis + DCR/consent + spike com IdP real
  e failover; sem prova, qualquer estimativa menor seria chute.
- **Dependências:** Postgres, Redis, IdP de teste com DCR + `token_exchange` + PKCE; binário
  `v1.107.0` final.
- **Fora de escopo deste ADR:** implementação, migração de keys, wiring de gateway em prod,
  rotação de segredos, qualquer flag/policy nova, qualquer claim de enforcement antes do spike.
- Arquivo tocado: somente `docs/plans/LITELLM-125-ADR.md` (este documento).

## 9. Recomendação

**HOLD até o spike §5 verde no `v1.107.0` final** (com #36358 checado, §6). Após verde:
ADOPT na ordem M1 → M3 → M2/M5-delegate → M4 por último (backport mais frágil primeiro
isolado, nunca como porta de entrada).
