# CoreX — Arquitetura Técnica

> **Estado real da integração gráfica (2026-11-02):** a seção de pipeline abaixo descreve a arquitetura pretendida, não um caminho Vulkan funcional. `src/graphics/` contém somente Null Backend; não há Vulkan Instance, Surface, Device, Swapchain ou apresentação GPU. Editor/Runtime usam o bootstrap de `shared` e não integram hoje a janela Zigway da árvore legada. A API `.proj`/V3 não prova inicialização gráfica. Ver [ADR-004](ADR-004-vulkan-surface-integration.md).

**Versão:** 0.1.0
**Linguagem:** Zig 0.17.0
**Filosofia:** Desenvolvimento próprio, baixo overhead, controle explícito de memória, modularidade.

## Pipeline pretendido (GPU ainda não implementada)

```text
Zigway (janela, somente na árvore legada)
  → CoreX Application (src/main.zig, executável legado)
  → CoreX Renderer (src/graphics/renderer/render.zig)
  → Null Backend (único backend existente; no-op/headless)
  → sem GPU / sem apresentação
```

O pipeline de destino, ainda pendente, conecta uma janela com handles nativos acessíveis ao adaptador privado do Engine, que possui a Vulkan Instance/Surface/Device/Swapchain. Só após apresentação efetiva de frames a ligação Renderer→GPU poderá ser declarada. Editor e Runtime atualmente são bootstraps independentes e ainda não consomem esse Engine gráfico comum.

## Sistemas Próprios

- **ECS** (`src/ecs/`): entidade, componente, sistema, mundo.
- **Memory** (`src/memory/`): arena, pool, linear, frame, tracker.
- **Job System** (`src/jobs/`): job, job_system, execução sequencial/paralela futura.
- **Event System** (`src/events/`): event, event_bus.
- **Scripting** (`src/scripting/`): runtime Lua 5.4.x, allocator adapter, binding, registry, sandbox, debug, profiler.
- **Graphics** (`src/graphics/`): Renderer/DrawCommand mínimos e Null Backend no-op; nenhum passe/GPU/pipeline Vulkan funcional. A integração Vulkan está bloqueada conforme ADR-004.
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
