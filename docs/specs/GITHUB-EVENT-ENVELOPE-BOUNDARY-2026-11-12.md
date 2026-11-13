# GITHUB Event Envelope — Boundary do Produtor Externo (#183)

**Versão:** 1.0  
**Data:** 2026-11-12  
**Status:** #183 **PARCIAL** — este documento fixa a fronteira operacional e honesta; nada de novo controlador/daemon. A integração automática externa (produtor autenticado real) permanece pendente.

---

## 1. Objetivo e status

Documentar, de forma operacional e auditável, a fronteira entre o **produtor externo** de eventos GitHub e o pipeline interno de intake/bridge/kernel do #183.

- **Situação:** #183 segue **PARCIAL**. As primitivas de envelope, roteamento, correlação/dedup, entrega e ack existem e foram provadas com fixtures locais e E2E real controlado (`issue:6`).
- **O que este documento faz:** fixa contrato, papéis, fluxo, idempotência, modelo de confiança e critérios para sair de PARCIAL.
- **O que este documento NÃO faz:** não ativa webhook/Action, não instala ingress, não cria scheduler/daemon/novo controlador, não promove #183.

---

## 2. Papéis e separação de responsabilidades

Pipeline (fronteira → consumo):

1. **Produtor externo (fora do repositório/runtime atual):** webhook GitHub, GitHub Action ou componente equivalente que recebe o evento de origem, autentica a entrega, extrai metadados confiáveis e monta o envelope normativo. **Não instalado/ativo neste repositório.**
2. **Ingress autenticado (obrigatório para operação real):** ponto de confiança que valida a origem/assinatura antes de invocar o intake (ver seção 5). Sem ingress autenticado, o envelope é apenas bem-formado, não confiável.
3. **`scripts/v3/event-intake.ps1`:** valida/normaliza envelope (arquivo ou JSON, limite 64 KB), carrega rotas (256 KB), resolve rota/dedup de entrega com `-SeenFile` (256 KB) e, com `-Record`, grava `dedup_key` para rotas `ATTACH`/`NEW_TASK`/`OBSERVE` (retenção 5000, escrita atômica). Verifica HMAC opt-in para arquivo bruto via `-SignatureHeader` + segredo; sem segredo, legado não autenticado.
4. **`scripts/v3/github-event-bridge.ps1`:** intake → `Add-OrchestrationTaskEvent` / `task-kernel -Action event-attach` (CAS por revision) → opcional `-Record` no `SeenFile`; pode emitir ack via `task-kernel -Action event-ack` (idempotente por `dedup_key`).
5. **Kernel (`scripts/v3/task-kernel.ps1`, libs):** mantém inbox limitado (50 eventos), sanitiza `summary`, registra entrega/ack; ack exige `dedup_key` hex, sessão e `response_summary` (<=1000).

**Separação explícita (GH-WAKE):** `scripts/v3/github-wake.ps1` e `docs/specs/ETAPA-6D-GH-WAKE-SPEC.md` tratam **readiness/wait de CI** (`ghwait`, `next_action`, `harness github-wake-v1`) e **não** produzem o envelope de thread (`source/trigger/thread/delivery_id`). O tick do GH-WAKE **não fabrica `delivery_id`**. O envelope de evento pertence ao event-intake/bridge e a um produtor externo.

---

## 3. Contrato normativo do envelope

### 3.1 Campos e limites (validados por `New-OrchestrationEventEnvelope`)

| Campo | Tipo/forma | Regra |
|---|---|---|
| `source` | string | `github` |
| `trigger` | enum | `issue_comment` \| `pull_request_review` \| `ci_status` \| `push` |
| `thread` | string | `^(pr\|issue\|branch):[A-Za-z0-9._/-]{1,120}$` |
| `delivery_id` | string | `^[A-Za-z0-9._:-]{4,160}$` |
| `repo` | string | `owner/name` |
| `informational_only` | bool | se `true`, rota `IGNORE informational-only` |
| `summary` | string | <= 2000 chars, sanitizado; **sem segredos/PII** |

`dedup_key = SHA256(source | repo lowercased | delivery_id)` (hex). Usado para dedup de entrega e ack.

### 3.2 Origem obrigatória de `delivery_id`

- **Obrigatório:** `delivery_id` deve ser o identificador de entrega do GitHub (`X-GitHub-Delivery` do webhook/request). O produtor/ingress copia esse valor sem inventar, derivar de tick ou reutilizar.
- **Proibido:** fabricar `delivery_id` (incl. no tick GH-WAKE) ou gerar valores não rastreáveis à entrega original.

### 3.3 Mapeamento trigger → thread

| `trigger` | `thread` esperado | Observação |
|---|---|---|
| `issue_comment` | `issue:<n>` | comentário em issue |
| `pull_request_review` | `pr:<n>` | review em PR |
| `ci_status` | `pr:<n>` ou `branch:<ref>` | conforme o contexto do status/check |
| `push` | `branch:<ref>` | ref/branch normalizada ao padrão permitido |

O mapeamento é responsabilidade do produtor externo; `thread` deve obedecer ao padrão do envelope.

### 3.4 `informational_only` e `summary`

- `informational_only=true`: evento válido porém roteado como `IGNORE informational-only` (não aciona attach/new-task observável).
- `summary`: texto curto, limitado (<=2000 no envelope; kernel sanitiza), sem segredos, tokens, credenciais ou PII desnecessária.

---

## 4. Fluxo e idempotência

### 4.1 Fluxo nominal

1. Produtor externo recebe evento GitHub e valida assinatura (seção 5).
2. Produtor monta envelope normativo e chama `event-intake.ps1` (ex.: `-EnvelopeJson ... -Record -SeenFile ...`).
3. `Resolve-OrchestrationEventRoute` decide: `INVALID`; `IGNORE duplicate-delivery` (SeenDeliveryKeys); `IGNORE informational-only`; 1 dono não-terminal → `ATTACH`; >1 → `ESCALATE ambiguous-thread-owner`; 0 → `NEW_TASK` se `AdmissionEnabled`, senão `OBSERVE admission-disabled`.
4. `github-event-bridge.ps1` (quando usado) anexa via `event-attach` (CAS por revision) e, se aplicável, registra dedup/ack.

### 4.2 Regras de roteamento

- **`ATTACH`:** exige Task/thread com **um único** dono não-terminal; CAS no kernel.
- **`ESCALATE ambiguous-thread-owner`:** mais de um dono candidato — sem attach automático.
- **`NEW_TASK` vs `OBSERVE`:** admissão automática desligada por padrão ⇒ eventos sem dono elegível viram `OBSERVE admission-disabled`; `NEW_TASK` só com admissão explicitamente habilitada.
- **Ordens possíveis:** entregas podem chegar fora de ordem ou repetidas; dedup/idempotência devem tornar replays seguros.

### 4.3 Idempotência em três camadas

1. **Rota/`SeenFile`:** dedup por `dedup_key` (SeenDeliveryKeys/ledger). `-Record` grava apenas para `ATTACH`/`NEW_TASK`/`OBSERVE`.
2. **Inbox (kernel):** entrega idempotente por `dedup_key` (duplicata não cria novo efeito observável).
3. **Ack:** `event-ack` idempotente por `dedup_key` (re-ack seguro).

### 4.4 Persistência, concorrência e retenção do `SeenFile`

- Escrita atômica; retenção limitada (5000 chaves) com descarte conforme política do ledger.
- **Concorrência:** modelo seguro assumido de **escritor único** por `SeenFile`; concorrência multi-writer não é garantida sem coordenação externa.
- Backup/recuperação do ledger é responsabilidade operacional do ambiente que hospedar o ingress/produtor; perda do ledger reduz a janela efetiva de dedup de rota (camadas kernel/ack podem ainda mitigar conforme estado persistido).

---

## 5. Modelo de confiança e segurança

**Risco material (atenuação opt-in, não padrão):** o `event-intake.ps1` dispõe de verificação interna GitHub `X-Hub-Signature-256` (HMAC-SHA256) sobre os bytes brutos, antes de parse/ledger, quando segredo e header são fornecidos. Sem segredo configurado, comportamento legado permanece e envelopes bem-formados continuam sem prova criptográfica de origem; bridge/kernel não autenticam origem independentemente.

**Replay:** mitigado por dedup (`dedup_key`) **enquanto** ledger/estado persistirem; perda de estado ou janela expirada enfraquece a proteção.

### 5.1 Requisitos e recomendações para ingress

- **DEVE (obrigatório em operação real):** ingress validar `X-Hub-Signature-256` (HMAC-SHA256 do corpo bruto) com segredo dedicado antes de montar/chamar o intake. Rejeitar assinatura ausente, inválida ou algoritmo divergente.
- **DEVE:** usar TLS ponta a ponta; limitar payload/tamanho aceito; rejeitar origem não autenticada.
- **DEVE:** tratar segredo como credencial (armazenamento seguro, rotação planejada, nunca em logs/artefatos).
- **RECOMENDA:** log sem PII/segredos, com `delivery_id`/`dedup_key` para auditoria; defesa contra replay além do ledger quando aplicável; princípio do menor privilégio para o processo chamador.
- **Sem ingress autenticado:** aceitar que o intake processa envelopes não autenticados é um **risco material aceito e documentado** — inadequado para produção/autonomia.

---

## 6. Exemplo de referência NÃO ativado

> **Aviso:** os exemplos abaixo são **referência/documentação**. **Nada disso está instalado, configurado ou ativo** neste repositório/ambiente.

### 6.1 Pseudocódigo de handler HTTP (ingress)

```text
handler(request):
  body = request.raw_body
  sig  = request.headers["X-Hub-Signature-256"]
  if not verify_hmac_sha256(secret, body, sig): reject(401)        # OBRIGATÓRIO

  gh = parse_json(body)
  delivery_id = request.headers["X-GitHub-Delivery"]               # origem obrigatória
  envelope = map_github_to_envelope(gh, delivery_id)               # trigger/thread/summary
  # chamar intake (exemplo): event-intake.ps1 -EnvelopeJson <envelope> -Record -SeenFile <ledger>
  # opcional: bridge para attach/ack conforme política operacional
```

### 6.2 Payload GitHub mínimo (exemplo) e envelope resultante

Payload (ilustrativo, comentário em issue):

```json
{
  "action": "created",
  "issue": { "number": 6 },
  "comment": { "body": "ping" },
  "repository": { "full_name": "Kusts/opencode-orchestration" }
}
```

Envelope normativo resultante (exemplo):

```json
{
  "source": "github",
  "trigger": "issue_comment",
  "thread": "issue:6",
  "delivery_id": "00000000-0000-0000-0000-000000000006",
  "repo": "Kusts/opencode-orchestration",
  "informational_only": false,
  "summary": "issue_comment created on issue #6"
}
```

### 6.3 Esboço de GitHub Action/webhook como produtor externo

- **Webhook:** GitHub envia `X-GitHub-Delivery` + `X-Hub-Signature-256` → serviço de ingress (externo) valida HMAC → monta envelope → invoca intake/bridge com `-Record -SeenFile` em armazenamento persistente controlado.
- **GitHub Action (esboço conceitual):** job disparado por eventos suportados, calcula/propaga `delivery_id` a partir do contexto de entrega quando disponível, gera envelope e o encaminha a um ingress autenticado. **Qualquer workflow/integração deste tipo é externo e não está presente/ativo aqui.**

---

## 7. Não-objetivos

- Sem scheduler, daemon ou novo controlador.
- Sem fabricar `delivery_id` (em tick, retry ou fallback).
- Sem criar Task automaticamente por padrão (admissão desligada ⇒ `OBSERVE`).
- Sem merge/deploy ou efeitos externos não autorizados.
- Sem promoção de status de #183 além de PARCIAL.

---

## 8. Critérios de aceite para sair de PARTIAL e limitações atuais

### 8.1 Critérios para sair de PARCIAL

1. **Produtor autenticado real:** ingress/produtor operacional validando `X-Hub-Signature-256` (HMAC-SHA256) com segredo gerido/rotacionável.
2. **Ledger persistente e seguro:** `SeenFile` (ou equivalente) persistente, com política de concorrência/escritor único, retenção e backup definidas.
3. **Testes de segurança/comportamento:** cobertura para assinatura inválida/ausente, replay, spoof e concorrência relevante (além das fixtures locais atuais).
4. **Operação em CI/ambiente controlado:** execução integrada e observável do fluxo externo→ingress→intake/bridge/kernel, com runbooks e limites claros.

### 8.2 Limitações atuais

- Produtor externo/ingress **não instalado nem ativo**; exemplos são apenas referência.
- Intake/bridge/kernel **não autenticam** origem (confiança implícita no chamador) — risco material enquanto não houver ingress autenticado.
- Dedup depende de persistência de ledger/estado; `SeenFile` assume escritor único e retenção finita (5000).
- Testes existentes (EventIntake 8/8, TaskEvent 12/12, EventBridge 9/9) cobrem fixtures locais; **sem** HTTP real, Action, verificação de assinatura, replay/spoof em ingress real.
- GH-WAKE permanece separado (readiness/CI wait) e não emite envelope.

**Conclusão:** #183 permanece **PARCIAL** até que os critérios acima sejam atendidos com evidência. A fronteira documentada aqui não implica segurança nem ativação automática.
