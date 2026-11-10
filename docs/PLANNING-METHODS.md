# Metodologias de planejamento: instalação e seleção no OpenCode V2

> Estado em 2026-11-10: **Superpowers e Matt Pocock já possuem adaptações em `skills-core/` e entram via `install.ps1`. BMAD e Addy Osmani ainda precisam ser incorporados ao pacote para disponibilidade offline automática.** A integração completa é acompanhada pela [issue #237](https://github.com/Kusts/opencode-orchestration/issues/237) e o roteamento pela [#48](https://github.com/Kusts/opencode-orchestration/issues/48).

## Fontes e instruções oficiais

| Metodologia | Repositório | Instalação nativa upstream | Uso previsto no pacote |
| --- | --- | --- | --- |
| Superpowers (obra) | https://github.com/obra/superpowers | [Instalar para OpenCode](https://github.com/obra/superpowers/blob/main/.opencode/INSTALL.md) | Técnicas já adaptadas (debugging, TDD, planejamento e verificação); não ativar o plugin original em paralelo |
| BMAD Method | https://github.com/bmad-code-org/BMAD-METHOD | [Guia oficial](https://github.com/bmad-code-org/BMAD-METHOD#start-building): `npx bmad-method install` **por projeto** para v6.12 estável. V7 ainda em preview alpha | Selecionar técnicas para discovery, requisitos, épicos/stories, arquitetura e continuidade quando o objetivo justificar |
| Matt Pocock Skills | https://github.com/mattpocock/skills | `npx skills@latest add mattpocock/skills -a opencode` | Reusar adaptações existentes em `skills-core/`; importar apenas lacunas |
| Addy Osmani Agent Skills | https://github.com/addyosmani/agent-skills | [Instalação para OpenCode](https://github.com/addyosmani/agent-skills/blob/main/docs/opencode-setup.md): copiar skills selecionadas para `.opencode/skills/` ou `~/.config/opencode/skills/` | Acrescentar técnicas de engenharia não duplicadas pelo catálogo existente |

Os comandos nativos servem para **uso opcional isolado**. Não são executados automaticamente por `install.ps1`: instalar os frameworks inteiros em paralelo pode criar regras/bootstrap/skills conflitantes. Para uso normal, o objetivo é que as **técnicas selecionadas e versionadas no próprio pacote** sejam entregues sem downloads adicionais.

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

O instalador já distribui as skills-core do pacote em `~/.config/opencode/skills/`. **Até a #237 ser implementada e testada, não afirmar que ele instala as quatro origens integralmente.** Após a #237, os componentes BMAD e Addy selecionados devem ser encontrados no mesmo catálogo pela instalação padrão, inclusive offline, sem instalar quatro repositórios nem carregar as quatro metodologias em toda tarefa.

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

Ambos devem retornar `True` na instalação padrão atual (sem `-NoCoreSkills`). A verificação futura para BMAD/Addy deve seguir os nomes **efetivamente escolhidos** no empacotamento #237 e incluir descoberta real pelo loader de skills do OpenCode.

Para atualizar: `git pull`, `.\install.ps1 -Runtime V2 -WhatIf` e `.\install.ps1 -Runtime V2`. Consulte [a instalação completa](INSTALLATION.md) e o [roteador atual](../skills-core/hybrid-development/SKILL.md).
