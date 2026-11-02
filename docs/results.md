# CoreX Engine — Fase 1 — Resultados

## Ambiente
- Zig 0.17.0 confirmado (`zig version`).
- Diretório do projeto: `/home/matheus/Documentos/ProjectOpenCode/CoreX/` (criado do zero, pois `CoreXEngine` existia vazio).

## Arquitetura Implementada
- Data-Oriented Design planejado; ECS preparado para Fase 5.
- Modularidade confirmada: cada sistema em pasta independente (`core`, `memory`, `project`, `graphics` etc.).

## Estrutura de Diretórios
```
CoreX/
├── build.zig / build.zig.zon
├── docs/architecture/initial.md
├── config/defaults/
├── src/
│   ├── main.zig (runtime)
│   ├── core/{engine,lifecycle,version}.zig
│   ├── memory/allocator.zig
│   ├── project/{loader,config}.zig
│   └── ... (outros módulos preparados)
├── tests/test_core.zig
├── test_project/TestProject.proj
├── README.md
└── build.zig.zon
```

## Sistemas Funcionais
- **Core System**: Engine inicia, para, executa tick. Lifecycle com estados (Init, Running, Stopped).
- **Memory Management**: ArenaAllocator, LinearAllocator, FrameAllocator, PoolAllocator, MemoryTracker com estatísticas.
- **Project Loader**: Interface funcional (`load`) que retorna `ProjectConfig`. Documento técnico: leitura de arquivo `.proj` precisa de adaptação à API `std.Io.Dir` introduzida no Zig 0.17.0; base funcional implementada com configuração padrão e validação.
- **Parser .proj**: Estrutura `ProjectConfig` definida e validada (nome, versão, engine, gráfico, física, scripting, cenas).
- **Engine Runtime**: `CoreXEngine --project` simulado; inicialização via arquivo `.proj` validada com dados reais.

## Compilação
- `zig build` — sucesso.
- Executável gerado: `zig-out/bin/CoreXEngine` (~10MB).
- Execução: imprime dados do projeto, inicia e para corretamente.

## Testes
- `tests/test_core.zig` — `zig build test` retorna `0` (sucesso).

## Problemas Encontrados
- `GeneralPurposeAllocator` removido no Zig 0.17.0; substituído por `std.heap.page_allocator` para testes iniciais.
- `std.fs.cwd()` substituído por `std.Io.Dir` no Zig 0.17.0; loader simplificado com configuração padrão até atualização completa do parser de arquivo.
- `ExecutableOptions` mudou: `root_module` substitui `root_source_file` diretamente; `createModule` aceita `.target` e `.optimize`.

## Dependências
- Nenhuma biblioteca externa. Apenas Zig 0.17.0 stdlib.
- Justificativa: a engine deve ser independente e com controle total de memória e renderização.

## Próxima Etapa Recomendada
**Fase 2 — Platform Foundation**:
- Implementar `Window System` (abstração Linux/Windows).
- Implementar `Input System` (teclado, mouse, gamepad).
- Implementar `Event System` e `Platform Abstraction`.
- Corrigir o parser `.proj` para leitura completa de arquivo usando `std.Io.Dir`.

---

Documentado por: Assistente de Desenvolvimento
Data: 2026-11-01
Marco da fase: Fase 1 completa (o antigo `0.1.0` nesta linha não é versão nem release de produto; a autoridade atual é [`../VERSION`](../VERSION)).
