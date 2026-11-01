# CoreX Engine

Game Engine profissional em Zig 0.17.0.

## Editor e Runtime — implementação em andamento

ADR e schemas aprovados; primeira fatia implementada em [`shared/`](shared/README.md): parser/serializer `.proj`, presets e DTO Zig↔C23, com testes independentes do build legado. **Os dois executáveis gráficos ainda não estão implementados.**

- [Estrutura-alvo](docs/APPLICATION_LAYOUT.md)
- [Progresso e evidências atuais](docs/APPLICATION_PROGRESS.md)
- [Contrato `.proj` v1](docs/PROJECT_SCHEMA_V1.md)
- [Contrato `presets.zon` v1](docs/PRESETS_SCHEMA_V1.md)

As seções abaixo registram o estado histórico do core, não evidência de build/renderer nesta sessão. O build legado apresentou falha de resolução dos pacotes; consulte o relatório atual antes de assumir compilação limpa ou recursos gráficos funcionais.

## Status — Base Compilável (Fase 1 completa + evolução incremental)

- Zigway v0.1.0-alpha.4 integrados (hash verificado)
- ZyntraUI v1.44.1 integrados (hash verificado)
- ECS (`ecs/`), Memory (`memory/`), Job System (`jobs/`), Events (`events/`), Scripting Lua (`scripting/`)
- Renderer próprio (`graphics/renderer/`), Backend Null, Graphics Abstraction
- Audio (`audio/`), Animation (`animation/`), Scene (`scene/`)
- Serialization (`serialization/`), Assets (`assets/`), Profiler (`profiler/`)
- Documentação arquitetural (`docs/ARCHITECTURE.md`)
- Testes por subsistema (`tests/*/test_basics.zig`) + integração (`tests/integration/`)
- `zig build` limpo; executável `CoreXEngine` funcional

## Uso

```bash
zig build
./zig-out/bin/CoreXEngine
```

O executável carrega a configuração do projeto e inicia o runtime.

## Integração de Melhorias Recentes

### Zigway (v0.1.0-alpha.4) — Plataforma / Janela / Input
- `src/platform/zigway.zig` — interface nativa
- `src/window/zigway.zig` — generational handles, event loop (`waitEvents`), clipboard, pointer capture, multi-window, Wayland/X11/Win32/Null
- Dependência no `build.zig.zon`: `.zigway = .{ .url = "...v0.1.0-alpha.4.tar.gz", .hash = "zigway-..." }`

### ZyntraUI (v1.44.1) — UI Toolkit / Debug / Overlay
- `src/ui/zyntra.zig` — interface renderer-agnostic
- Recursos incorporados: 35 widgets, flex layout, dirty-rect partial repaint, glyph atlas, IME, accessibility tree, window registry + compositor, viewport3D
- Dependência no `build.zig.zon`: `.zyntra_ui = .{ .url = "...v1.44.1.tar.gz", .hash = "zyntra_ui-..." }`

## Próximas Fases

- Fase 2: Window, Input, Platform (Linux/Windows).
- Fase 3: Graphics Abstraction + Vulkan Backend.
- Fase 4: Render Graph, PBR, Shadows, Profiles Low/Medium/High.
- Fase 5: ECS + Scene System.
- Fase 6: Physics Engine próprio.
- Fase 7: Lua Scripting.
- Fase 8: Asset Manager + Async Loading.
- Fase 9: Áudio + Animação.
- Fase 10: Otimização + Profiling.
