# CoreX Engine — Arquitetura Inicial

## Objetivo
Fundação de uma Game Engine profissional em Zig 0.17.0, baseada em:
- Data-Oriented Design (DOD)
- Entity Component System (ECS)
- Modularidade nativa
- Baixo acoplamento
- Gerenciamento explícito de memória
- Abstrações de baixo custo

## Fases
1. Core Foundation (atual)
2. Platform Foundation
3. Graphics Foundation
4. Graphics Advanced
5. ECS e Scene System
6. Physics
7. Lua Scripting
8. Assets e Recursos
9. Áudio e Animação
10. Otimização

## Estrutura de Módulos
- core: engine lifecycle, version
- memory: allocators, tracking, profiling
- platform: abstração de sistema
- window: criação e gerenciamento
- input: teclado, mouse, gamepad
- events: sistema de eventos
- threading / jobs: paralelismo
- ecs: entidades, componentes, sistemas
- scene: carregamento de cenas
- assets: gerenciamento de recursos
- graphics / renderer / backends: renderização
- physics: física própria
- scripting / lua: runtime Lua
- audio: áudio
- animation: animação
- serialization: serialização
- project: parser .proj
- debug / profiler: ferramentas
- runtime: execução principal

## Memória
- Arena Allocator
- General Purpose Allocator
- Linear Allocator
- Pool Allocator
- Stack Allocator
- Frame Allocator
- Temporary Allocator
- Memory Tracking e Profiling

## Build
- Zig 0.17.0
- Build nativo sem framework externo pesado
- Módulos independentes

## Dependências
Nenhuma biblioteca externa obrigatória. APIs gráficas acessadas via bindings quando necessário.
