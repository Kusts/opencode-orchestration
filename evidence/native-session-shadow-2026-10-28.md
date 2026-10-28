# Native-First Session Shadow Equivalence — 2026-10-28

## Ambiente
- Runtime: opencode v2.2.0 (C:\Users\walis\bin\opencode.cmd)
- Projeto: D:\projetos\opencode-orchestration
- Limite consultado (native -n): 50
- Sessoes nativas retornadas: 50
- Truncado: sim (native count == limite)

## Catalogo local
- Arquivos de tarefa em cache/runtime/tasks: analisados
- Bindings locais com session_id nao vazio: 1
- Observacao: o unico binding local (rr-p29-jev-transport-s2b) usa id sintetico (ses-jev-s2-coder), nao uma sessao real do OpenCode.

## Metricas
- Total de bindings locais: 1
- Total de sessoes nativas observadas: 50
- Total de IDs comparaveis: 1
- Matches: 0
- Divergencias (FIELD_MISMATCH): 0
- Ausencias sem prova conclusiva (LOCAL_ONLY, truncado): 1
- Erros de consulta: 0

## Classificacao
- ses-jev-s2-coder: LOCAL_ONLY (nao presente na amostra nativa; amostra truncada, ausencia nao conclusiva)

## Conclusao
- Nenhuma correspondencia real medida (o unico binding local e sintetico).
- A amostra nativa esta truncada (50 == limite), portanto ausencias locais nao sao prova de desaparecimento.
- Nenhuma alteracao de autoridade ou remocao de catalogo local realizada.
- Proxima fatia: ampliar cobertura nativa (aumentar -n) ou correlacionar bindings reais; demonstrar equivalencia antes de promover.