# Metodologias de planejamento: instalação e seleção no OpenCode V2

> Estado em 2026-11-17: as oito `skills-core` incluem técnicas adaptadas das quatro origens e entram via `install.ps1`, inclusive offline. A issue [#237](https://github.com/Kusts/opencode-orchestration/issues/237) acompanha essa inclusão; o roteamento adaptativo por tarefa permanece separado na [#48](https://github.com/Kusts/opencode-orchestration/issues/48).

## Fontes e instruções oficiais

| Metodologia | Repositório | Instalação nativa upstream | Uso previsto no pacote |
| --- | --- | --- | --- |
| Superpowers (obra) | https://github.com/obra/superpowers | [Instalar para OpenCode](https://github.com/obra/superpowers/blob/main/.opencode/INSTALL.md) | Técnicas já adaptadas (debugging, TDD, planejamento e verificação); não ativar o plugin original em paralelo |
| BMAD Method | https://github.com/bmad-code-org/BMAD-METHOD | [Guia oficial](https://github.com/bmad-code-org/BMAD-METHOD#start-building): `npx bmad-method install` **por projeto** para v6.12 estável. V7 ainda em preview alpha | Selecionar técnicas para discovery, requisitos, épicos/stories, arquitetura e continuidade quando o objetivo justificar |
| Matt Pocock Skills | https://github.com/mattpocock/skills | `npx skills@latest add mattpocock/skills -a opencode` | Reusar adaptações existentes em `skills-core/`; importar apenas lacunas |
| Addy Osmani Agent Skills | https://github.com/addyosmani/agent-skills | [Instalação para OpenCode](https://github.com/addyosmani/agent-skills/blob/main/docs/opencode-setup.md): copiar skills selecionadas para `.opencode/skills/` ou `~/.config/opencode/skills/` | Acrescentar técnicas de engenharia não duplicadas pelo catálogo existente |

**Técnicas adaptadas no pacote** são skills locais versionadas em `skills-core/`: o instalador distribui as oito automaticamente, sem download adicional, e elas podem ser usadas offline. Isso não equivale a instalar os **frameworks upstream completos**. Os comandos da tabela são alternativas manuais e opcionais para quem explicitamente deseja usar um framework upstream; `install.ps1` nunca os executa. Instalar frameworks completos em paralelo pode acrescentar regras, bootstrap ou skills concorrentes.

## Instalação recomendada do orquestrador (Windows, OpenCode V2)

Pré-requisitos: OpenCode V2, PowerShell 5.1+ e configuração válida de modelos.

```powershell
git clone https://github.com/Kusts/opencode-orchestration.git
cd opencode-orchestration
Copy-Item models.example.jsonc models.jsonc
# Edite models.jsonc: planner, cheap e strong
.\install.ps1 -Runtime V2 -WhatIf
.\install.ps1 -Runtime V2
```

O instalador distribui as oito técnicas adaptadas em `~/.config/opencode/skills/`, inclusive offline. A validação registrada em `evidence/planner-autonomy-e2e/skills-install-validation.md` cobre instalação, preservação, idempotência e carregamento real de uma skill. Esse artefato é local e não versionado (`.gitignore` ignora `evidence/*`); o registro descreve comandos e resultados para reprodução. Não afirmar que isso instala os quatro frameworks upstream completos; esses permanecem opcionais e manuais.

## Comportamento desejado do Planner

- Entrada única: `hybrid-development`; carregar uma técnica somente quando ela muda a próxima decisão.
- Alteração simples e reversível: execução direta + teste focado.
- Bug: Superpowers (systematic debugging); implementação bem definida: Matt + técnicas de execução/teste.
- Produto/fatia grande ainda ambíguos: BMAD para organizar requisitos, marcos e stories.
- Revisão/entrega/qualidade especializada: técnica Addy que ainda não exista no catálogo.
- JEV, quando disponível, é consultor **opcional** para impasses ou escolhas materiais, nunca um segundo Planner nem pré-requisito.

O Task Kernel, a seleção de modelos, a delegação e a continuidade existentes permanecem responsáveis por execução e estado. Não duplicar workflows, gestores de planos ou documentação.

## Como verificar o estado local

```powershell
Test-Path "$env:USERPROFILE\.config\opencode\skills\hybrid-development\SKILL.md"
Test-Path "$env:USERPROFILE\.config\opencode\skills\using-superpowers\SKILL.md"
```

Ambos devem retornar `True` na instalação padrão atual (sem `-NoCoreSkills`). Os nomes atuais das oito skills estão listados no README; para validar discovery, carregue uma skill pelo mecanismo real do runtime. A evidência local acima comprova o carregamento real de uma skill, não a enumeração de todas as oito.

Para atualizar: `git pull`, `.\install.ps1 -Runtime V2 -WhatIf` e `.\install.ps1 -Runtime V2`. Consulte [a instalação completa](INSTALLATION.md) e o [roteador atual](../skills-core/hybrid-development/SKILL.md).
