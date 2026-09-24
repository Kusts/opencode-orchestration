# Limites de credenciais

- O repositório contém somente nomes de chaves, propósito, consumidores e
  obrigatoriedade. Nunca contém valores.
- `global.env` e `restricted.env` vivem fora do Git — por exemplo em `%USERPROFILE%\.agents\secrets` (opcional/legado, somente se o operador mantiver perfis externos; sem path obrigatório).
- O parser aceita UTF-8, comentários `#`, linhas vazias e chaves
  `[A-Z_][A-Z0-9_]*`; divide na primeira ocorrência de `=` e não faz
  interpolação, expansão de comando ou `Invoke-Expression`.
- Chaves duplicadas são rejeitadas. Valores nunca são ecoados ou gravados em
  escopo de usuário/máquina.
- A resolução é `common` → runtime → perfil adicional explícito → restricted
  allow-listed somente quando solicitado.
- O launcher externo é opcional/legado e não é fornecido por este pacote; quando usado, injeta o resultado apenas no processo-filho e redige valores em
  qualquer relatório. Sem ele, nada quebra: o runtime usa variáveis de ambiente normalmente.
- A pasta de segredos deve ter herança desabilitada e acesso somente do usuário
  atual e `SYSTEM`; a verificação ACL falha se houver leitores adicionais.
