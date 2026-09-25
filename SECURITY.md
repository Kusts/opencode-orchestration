# Security Policy

## Supported Versions

| Versão do pacote | Suportada |
|---|---|
| 1.0.x | ✅ Sim |
| < 1.0 (pré-release, ex. `1.0.0-hardening`) | ❌ Não |

Nota sobre o runtime: este pacote suporta o **OpenCode V1.x** (validado
com 1.18.32). O **OpenCode V2** (`@opencode-ai/cli`, comando `opencode2`)
**não é suportado**.

## Resumo da política

- **Boundaries**: classes de permissão por agente (read-only /
  writer-shell / writer-no-shell / diagnostic) e barreiras
  runtime/prompt/planner-enforced. Workers nunca delegam
  (`subagent_depth: 1`).
- **Credenciais**: o repo contém só nomes de chaves, nunca valores.
  Segredos nunca entram em git, instruções geradas, logs, relatórios ou
  telemetria. Em uso, credenciais vêm do ambiente do runtime.
- **Backups locais**: o instalador copia byte-exato o config pré-existente
  do usuário (`~/.config/opencode/backups/`). O pacote não injeta segredos
  nesses arquivos, mas eles podem conter o que o usuário mantinha no config
  original — trate-os como dados sensíveis locais e remova backups antigos
  quando não forem mais necessários.
- **Telemetria**: sanitizada e local (`~/.opencode-orchestration/evidence/`,
  seus dados — o uninstall preserva). Falha de telemetria nunca quebra a
  sessão.
- **CI sem segredos**: nenhuma ação além de `actions/checkout`; testes
  usam canários sintéticos (ex. `sk-SYNTHETICSECRET`), nunca credenciais
  reais.

Detalhes normativos em [docs/SECURITY.md](docs/SECURITY.md) (boundaries,
credenciais, regras de produção, telemetria, limitações do runtime).

## Reportando uma vulnerabilidade

Abra uma issue privada ou contate o mantenedor diretamente — **não** abra
issue pública com detalhes da falha. Inclua versão do pacote, versão do
OpenCode e passos de reprodução. O mantenedor responde com o plano de
correção e a versão afetada entra no [CHANGELOG](CHANGELOG.md).
