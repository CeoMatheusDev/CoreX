# CoreX — Arquitetura Técnica

**Versão:** 0.1.0
**Linguagem:** Zig 0.17.0
**Filosofia:** Desenvolvimento próprio, baixo overhead, controle explícito de memória, modularidade.

## Pipeline

```
Zigway (plataforma/janelas)
  → CoreX Window
  → CoreX Application (main.zig)
  → ZyntraUI (UI renderer-agnostic)
  → UI Draw Commands
  → CoreX Renderer (render.zig)
  → Graphics Abstraction
  → Graphics Backend (vulkan/null)
  → GPU / Framebuffer
```

## Sistemas Próprios

- **ECS** (`src/ecs/`): entidade, componente, sistema, mundo.
- **Memory** (`src/memory/`): arena, pool, linear, frame, tracker.
- **Job System** (`src/jobs/`): job, job_system, execução sequencial/paralela futura.
- **Event System** (`src/events/`): event, event_bus.
- **Scripting** (`src/scripting/`): runtime Lua 5.4.x, allocator adapter, binding, registry, sandbox, debug, profiler.
- **Graphics** (`src/graphics/`): renderer próprio, pass, backend null (extensível para Vulkan).
- **Platform** (`src/platform/zigway.zig`): integração Zigway v0.1.0-alpha.4.
- **Window** (`src/window/zigway.zig`): integração Zigway.
- **UI** (`src/ui/zyntra.zig`): integração ZyntraUI v1.44.1.
- **Audio** (`src/audio/`): engine básico.
- **Animation** (`src/animation/`): animação básica.
- **Scene** (`src/scene/`): gestão de cena.
- **Serialization** (`src/serialization/`): serializador básico.
- **Assets** (`src/assets/`): pipeline básico.
- **Profiler** (`src/profiler/`): profiler básico.

## Dependências Externas (justificadas tecnicamente)

- `.zigway`: Zig 0.17.0, MIT, hash verificado.
- `.zyntra_ui`: Zig 0.17.0, MIT, hash verificado.

## Qualidade

- Compilação limpa (`zig build`).
- Testes por subsistema (`tests/*/test_basics.zig`).
- Contratos explícitos em todos os módulos.
