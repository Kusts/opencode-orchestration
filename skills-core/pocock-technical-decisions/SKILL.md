---
name: pocock-technical-decisions
description: Use when choosing or reviewing an API shape, type contract, interface boundary, error model, or naming that callers depend on. Skip cosmetic renaming and decisions with no material alternative.
license: MIT
---

# Pocock Technical Decisions

Técnica inspirada nas skills de Matt Pocock sobre decisões técnicas e
qualidade de interfaces. Texto original; nenhum conteúdo upstream foi copiado.
Decide com base em callers reais, não em preferência estética.

## Quando carregar

- um contrato público ou compartilhado vai nascer ou mudar;
- tipos, erros, estados inválidos ou compatibilidade estão em jogo;
- duas interfaces plausíveis competem e a escolha afeta manutenção;
- uma revisão precisa julgar qualidade de API, não estilo.

## 1. Comece pelos callers

Liste quem chama, o que precisa saber e o que não deveria precisar saber.
Projete a menor superfície que satisfaz esses usos. Se não existe caller real,
não crie abstração antecipada.

## 2. Torne estados inválidos improváveis

- prefira um tipo/forma que não represente combinações impossíveis;
- evite booleanos posicionais que se confundem;
- erros devem ser explícitos no contrato, não descobertos em runtime;
- ausência, vazio e desconhecido são estados distintos;
- valores derivados não devem ser aceitos como entrada sem validação.

## 3. Design twice apenas quando for material

Quando duas opções mudam custo, compatibilidade ou ergonomia, descreva as duas
em termos de caller, evolução e falha. Escolha uma e registre o motivo. Não
produza alternativas para decisão já resolvida.

## 4. Compatibilidade e evolução

- mudanças aditivas antes de quebra;
- depreciação com prazo e caminho de migração;
- contratos persistidos ou externos exigem versão e rollback;
- não esconda quebra atrás de um alias silencioso.

## 5. Checklist de revisão

1. O contrato expressa o uso real?
2. O erro é explícito e acionável?
3. O estado inválido é difícil de representar?
4. A mudança é compatível ou tem migração?
5. Há teste/consumidor que prova o contrato?

Se a resposta exigir uma decisão de produto, arquitetura ampla ou autorização,
devolva ao Planner em vez de decidir sozinho.
