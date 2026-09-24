# Limites de credenciais

- O repositório contém somente nomes de chaves, propósito, consumidores e
  obrigatoriedade. Nunca contém valores.
- `global.env` e `restricted.env` vivem fora do Git em `%USERPROFILE%\.agents\secrets`.
- O parser aceita UTF-8, comentários `#`, linhas vazias e chaves
  `[A-Z_][A-Z0-9_]*`; divide na primeira ocorrência de `=` e não faz
  interpolação, expansão de comando ou `Invoke-Expression`.
- Chaves duplicadas são rejeitadas. Valores nunca são ecoados ou gravados em
  escopo de usuário/máquina.
- A resolução é `common` → runtime → perfil adicional explícito → restricted
  allow-listed somente quando solicitado.
- O launcher injeta o resultado apenas no processo-filho e redige valores em
  qualquer relatório.
- A pasta de segredos deve ter herança desabilitada e acesso somente do usuário
  atual e `SYSTEM`; a verificação ACL falha se houver leitores adicionais.
