# Native-First Session Shadow Equivalence — 2026-10-28 (updated)

## Ambiente
- Runtime: opencode v2.2.0 (C:\Users\walis\bin\opencode.cmd)
- Projeto: D:\projetos\opencode-orchestration
- Limite consultado (native -n): 200
- Sessoes nativas retornadas: 200
- Truncado: sim (200 == limite)

## Catalogo local
- Arquivos de tarefa em cache/runtime/tasks: analisados
- Bindings locais com session_id nao vazio: 1
- Binding real encontrado: ses_e96e5375fffeA5ajprNBwKuRHq (em evidence/v3.1/runtime-reliability/pilot-real-adaptive-workflow-result.json)

## Metricas (atualizadas)
- Total de bindings locais: 1
- Total de sessoes nativas observadas: 200
- Total de IDs comparaveis: 1
- Identity matches: 1
- Directory matches: 1
- Project matches: 0 (project_schema_incompatible: nome local vs ID opaco do runtime)
- Full matches (id + dir + project): 0
- Matches (id + dir, sem divergencia de campo comparavel): 1
- Divergencias (FIELD_MISMATCH): 0
- NATIVE_ONLY: 199
- LOCAL_ONLY: 0
- Erros de consulta: 0

## Classificacao
- ses_e96e5375fffeA5ajprNBwKuRHq: MATCH (id exato + directory concorda D:\projetos\opencode-orchestration; project_note=project_schema_incompatible: local usa nome 'opencode-orchestration', nativo usa ID opaco c0a24813568bcf09ed921d540d4ee1229ec0e888)

## Conclusao
- Correspondencia por identidade e diretório: confirmada para o binding real.
- Divergencia de projeto e' de schema (nome amigavel vs ID opaco do runtime), nao divergencia real. Classificada como NOT_COMPARABLE nessa dimensao, sem falso FIELD_MISMATCH.
- Amostra truncada (200 == limite) → NATIVE_ONLY nao e' prova de ausencia.
- Nenhuma alteracao de autoridade, Task/GoalKernel preservado, catalogo local intacto.
- Decisao: PARTIAL (correspondencia real de id+directory; equivalencia completa pendente de normalizacao de project id ou correlacao confiavel).
- Proxima fatia: ampliar cobertura nativa; correlacionar project via hash se comprovado; demonstrar equivalencia completa antes de promover.