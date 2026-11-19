# F2 — Certificação do instalador em HOME temporário

## Resultado

**PASS delimitado** para os ciclos de instalação em HOME temporário. Nenhuma
configuração ativa foi alterada; os hashes monitorados antes/depois são
idênticos. Referência: `docs/plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md`.

O harness `scripts/v3/certify-installer-home.ps1` certifica instalação limpa,
reinstalação idempotente e referências de instalação/desinstalação. O
`assert-active-paths-unchanged.ps1` recebeu normalização segura de baseline,
`ACTIVE_PATH_INVALID` e permissão de `-Output` sob TEMP via guard; continua
recusando `.config\opencode` e `.opencode-orchestration`. O carve-out foi
corrigido.

## Evidência e validação

| Verificação | Resultado |
|---|---|
| Certificação real (`certify-installer-home.ps1`, sem `-RepoRoot`) | exit 0; `verdict=PASS` |
| Comandos certificados | 4/4 exit 0: `install-clean`, `reinstall-idempotency`, `install-clean-reference`, `uninstall-reference` |
| Arquivos gerenciados / idempotência | 39 / PASS |
| Comparação com HOME novo | `fresh_home_comparison.equal=true`; `unexplained_files=[]` |
| Integridade de caminhos ativos | `active_after.exit_code=0`; hashes monitorados antes/depois idênticos |
| Testes `active-path-integrity.tests.ps1` | PASS, 9 checks |
| Testes `certify-installer-home.tests.ps1` | PASS; incluem recusa de `C:\oo-f2-nope`, saída fora do run, reordenação de tuplas e tupla divergente |
| `git diff --check` | limpo |

Manifesto da execução: `<TEMP>/oo-f2-20261118T142910542Z/artifacts/certification.json` (não versionado). Comparação byte a byte registra somente `AGENTS.md embeds TargetHome`; `permission_order_differs=false`. A comparação de regras usa tuplas `(action, resource, effect)`, evitando tratar reordenação como divergência semântica.

Testes anteriores: tester `OM-F2-TEST` PASS, sem regressões. Revisões de
segurança `OM-F2-SEC` e `OM-F2-SEC-2` motivaram correções M1–M4 (guard de
`-Output`, teste outside-TEMP, comparação por tuplas e cobertura de hashes) e
robustez de `-RepoRoot`; N1 foi corrigido antes da aprovação final implícita.

## HOLDs e residuais

- Descoberta runtime `opencode debug agents --standalone`: HOLD,
  “OpenCode canonical launcher is missing”; `discovered_count=null`,
  `expected_count=19` não observado.
- Smoke Planner→worker: HOLD; sem prova determinística sem provider.
- Variação anterior na ordem das regras de permissão entre processos filhos
  agora é comparada por tuplas; sem divergência semântica no run final.
- Nomes 8.3, `subst` e reparse points permanecem residuais do guard.
- Esta certificação não demonstra o smoke Planner→worker nem descoberta de
  agentes; não promover esses critérios a PASS.
