# Evidencia: simplificacao de permissoes

## Reproducao

Com `<repo>` no checkout e `<iso>` num diretorio temporario isolado:

```powershell
powershell -NoProfile -File <repo>\install.ps1 -TargetHome <iso> -Runtime V2
$env:XDG_CONFIG_HOME = '<iso>\.config'
opencode debug paths
opencode debug agents --standalone
powershell -NoProfile -File <repo>\scripts\runtime\readonly-diagnostic-permissions.tests.ps1
powershell -NoProfile -File <repo>\scripts\test-package-consistency.ps1
powershell -NoProfile -File <repo>\scripts\v3\run-v3-tests.ps1
powershell -NoProfile -File <repo>\tests\distribution\run-distribution-tests.ps1
```

## O que prova

- `static_validation`: resultados das suites e a falha de versao do binario local frente ao pin.
- `isolated_install`: instalacao e resolucao de config no destino isolado.
- `runtime_load_proof`: shape efetivo carregado para os perfis apresentados; `--standalone` evita anexar ao servico.
- `behavioral`: comandos observados para reviewer, coder, tester e limites.
- `live_config_preservation`: hashes/contagens observadas da config viva antes e depois.
- `precedence_observation`: ordenacao efetiva observada das regras em 2.3.0.

## O que nao prova

Nao prova comportamento humano, cobertura da superficie REST `/shell`, nem cadeia direta de delegacao (depth permanece 1). A prova comportamental e limitada aos comandos observados e nao afirma enforcement universal.
