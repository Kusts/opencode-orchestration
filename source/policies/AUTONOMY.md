# Limites de autonomia

## Sem confirmação adicional

Leitura/edição em escopo, código, testes, documentação, dependências locais,
builds, linters, diagnósticos, branches, commits, staging e refatorações
reversíveis; iniciar/reiniciar serviços locais; consultar memória, vault,
documentação e web; e deploy para o ambiente nomeado quando o pedido atual o
autorizar explicitamente.

## Confirmação obrigatória

- Exclusão irreversível de dados reais.
- Ação destrutiva de produção que não esteja explicitamente autorizada.
- Pagamento, compra ou assinatura.
- Criação, revogação ou rotação de credenciais.
- Comunicação externa enviada como o usuário.
- Expansão material do escopo solicitado.

O runtime pode impor limites adicionais. A política não autoriza bypass de
permissões nem substitui controles do sistema operacional.

## Authorization Envelope

O envelope de cada Objective deriva da interseção de: pedido do usuário,
project policy, global autonomy policy, task grants, environment policy e
runtime capabilities. Contrato declarativo em
`source/registry/autonomy-policy.json`; enforcement chega nas Fases 5/6.
O kernel continua sendo a autoridade.

## Authority Boundaries

| Código | Significado |
|---|---|
| `PRODUCT_INTENT_AMBIGUITY` | Intenção ambígua; prosseguir seria adivinhar produto. |
| `IRREVERSIBLE_REAL_DATA_ACTION` | Exclusão/mutação irreversível de dados reais. |
| `UNAUTHORIZED_PRODUCTION_ACTION` | Ação destrutiva em produção sem autorização explícita. |
| `EXTERNAL_COST_OR_PURCHASE` | Pagamento, compra ou assinatura. |
| `CREATE_ROTATE_REVOKE_CREDENTIAL` | Criação, rotação ou revogação de credenciais. |
| `EXTERNAL_COMMUNICATION_AS_USER` | Comunicação externa enviada como o usuário. |
| `MATERIAL_SCOPE_EXPANSION` | Expansão material do escopo solicitado. |
| `POLICY_DENIED` | Ação negada pela política aplicável. |
| `REQUIRED_EXTERNAL_INPUT_UNAVAILABLE` | Insumo externo obrigatório indisponível, sem alternativa. |

## Terminal Stop Reasons

`OBJECTIVE_COMPLETED`
`HUMAN_AUTHORITY_REQUIRED`
`EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE`
`GOAL_HARD_BUDGET_EXHAUSTED`
`POLICY_BLOCKED`
`CANCELLED`

Qualquer outro resultado (timeout de worker, erro de provider, exaustão de
tentativas) retorna ao control plane para recuperação; nunca encerra o Objective.
