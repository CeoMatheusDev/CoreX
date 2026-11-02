# CoreX — Status do snapshot legado

> **Correção de estado (2026-11-02):** este arquivo registra uma demonstração legada e não deve ser interpretado como declaração de suporte gráfico. O único backend em `src/graphics/` é o Null Backend no-op/headless. Vulkan Instance/Surface/Device/Swapchain e apresentação real não existem; nenhum smoke test gráfico foi executado. Editor e Runtime ainda usam bootstraps separados e não compartilham um Engine gráfico. Ver [ADR-004](ADR-004-vulkan-surface-integration.md) e [ARCHITECTURE.md](ARCHITECTURE.md).

## Compilação
`zig build` — OK (Zig 0.17.0)

## Dependências (hashes verificados)
- `.zigway`: `zigway-0.1.0-alpha.4-J1VBH_6UDAB_K4K2qoaGf3VkKqRxg2T5tgKqJzWQsJ_P`
- `.zyntra_ui`: `zyntra_ui-1.44.1-sgzbJL9GLABJOlz_u9WkQYOw3lVB2d7TJBbbXSHudeYN`

## Subsistemas Implementados (com contratos e testes)
- [x] Platform / Window (`zigway`)
- [x] UI (`zyntra_ui`)
- [ ] Vulkan Graphics Backend / GPU Renderer (não implementado)
- [x] Null Backend (`render.zig`, `backends/null.zig`) — no-op para contratos/headless, não apresenta frames
- [x] ECS (`ecs.zig`)
- [x] Memory (`allocator.zig`)
- [x] Job System (`jobs/`)
- [x] Event System (`events/`)
- [x] Scripting Lua (`scripting/` — runtime, allocator, binding, registry, sandbox, debug, profiler)
- [x] Audio (`audio/`)
- [x] Animation (`animation/`)
- [x] Scene (`scene/`)
- [x] Serialization (`serialization/`)
- [x] Assets (`assets/`)
- [x] Profiler (`profiler/`)

## Documentação
- `docs/ARCHITECTURE.md`
- `docs/CHANGES.md`
- `README.md` atualizado

## Integração legada (`src/main.zig`)
O executável legado exercita demonstrações mínimas dos módulos listados; isso não representa a integração Editor/Runtime atual, carregamento de projeto real ou execução de Renderer/GPU. O `ProjectLoader` desta árvore fornece configuração de exemplo/fallback e o Renderer conectado é Null.

## Próximos Passos (evolução incremental)
A base arquitetural está completa. Evolução futura depende de requisitos específicos: Vulkan backend, física, multiplayer, ferramentas visuais, exportação de builds.
