---
name: addy-incremental-delivery
description: Use for incremental implementation, review, performance work, or architecture boundaries: ship the smallest vertical slice, measure before optimizing, review correctness before style, and keep changes reversible. Skip pure requirements gathering and diagnosis.
license: MIT
---

# Addy Incremental Delivery

Técnica inspirada nas Agent Skills de Addy Osmani sobre implementação
incremental, revisão, performance e arquitetura. Texto original; nenhum
conteúdo upstream foi copiado.

## Quando carregar

- a implementação pode ser entregue em fatias menores;
- é preciso revisar uma mudança com foco em correção e regressão;
- há suspeita de problema de performance;
- uma fronteira de arquitetura precisa ser justificada por callers reais.

## 1. Menor fatia utilizável

Prove o caminho feliz ponta a ponta antes de endurecer. Reutilize contratos e
componentes existentes; não crie camada nova sem consumidor demonstrado.
Cada fatia deve ser observável e reversível.

## 2. Revisão antes de estilo

Leia o diff real, não a descrição do autor. Verifique:

1. o comportamento exigido existe;
2. regressões e caminhos de erro foram considerados;
3. concorrência, idempotência e efeitos externos estão seguros;
4. testes provam o comportamento, não a implementação;
5. estilo só depois de correção e risco.

Um claim de sucesso não substitui evidência.

## 3. Performance por medição

- defina orçamento ou baseline antes de otimizar;
- meça o caminho real, não o microbenchmark conveniente;
- otimize o gargalo medido, uma mudança por vez;
- evite cache, paralelismo ou complexidade sem ganho observado;
- registre custo, latência e limites da medição.

Sem medição, a mudança é hipótese — não melhoria comprovada.

## 4. Fronteiras de arquitetura

Coloque a fronteira onde existe caller, dado ou contrato real. Prefira
composição a hierarquia especulativa. Uma abstração só se paga quando reduz
duplicação real ou isola uma mudança frequente.

## 5. Entrega segura

- preserve trabalho preexistente;
- mantenha rollback para migração ou efeito irreversível;
- não amplie autoridade, permissões ou escopo por conveniência;
- declare o que foi verificado e o que ficou fora.
