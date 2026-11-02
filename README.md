> **Escopo atual das aplicações:** Windows/Linux; Editor 3D + UI/Canvas, sem cena 2D. Vulkan/OpenGL previstos nos dois SOs, D3D11/D3D12 no Windows — ainda sem renderers GPU ligados. [ADR-003](docs/ADR-003-desktop-3d-canvas.md) · [Schema v2](docs/PROJECT_SCHEMA_V2.md).

# CoreX Engine

Game Engine profissional em Zig 0.17.0.

## Editor e Runtime — implementação em andamento

ADR e schemas aprovados. Contratos em [`shared/`](shared/README.md) e bootstraps independentes em [`editor/`](editor/README.md) e [`runtime/`](runtime/README.md): parser/serializer `.proj`, presets, DTO Zig↔C23, CLI, logs JSON lines e verificação entre processos. **Os executáveis ainda validam documentos; não há Editor gráfico ou execução de jogo.**

- [CLI executável e limites](docs/APPLICATION_CLI.md)
- [Estrutura-alvo](docs/APPLICATION_LAYOUT.md)
- [Progresso e evidências atuais](docs/APPLICATION_PROGRESS.md)
- [Migração para desenvolvimento sem Python](docs/PYTHON_REMOVAL.md)
- [Contrato `.proj` v1](docs/PROJECT_SCHEMA_V1.md)
- [Contrato `presets.zon` v1](docs/PRESETS_SCHEMA_V1.md)

As seções abaixo descrevem o core legado, não evidência de recursos gráficos funcionais. A preparação atual das dependências contorna falhas de resolução de pacotes; consulte o relatório de progresso para resultados e limites.

## Validação nativa com Zig

Com Zig 0.17.0 já disponível e as dependências legadas preparadas, `zig build validate -j2 --summary all` reúne formatação, ferramentas, fixtures, política de alvos, headers e testes Shared/Editor/Runtime. A validação é nativa; `zig build check -Dtarget=x86_64-windows-gnu` continua compilando sem executar. A CI e alguns testes ainda exigem Python: veja o [inventário e plano de migração](docs/PYTHON_REMOVAL.md).

## Core legado — build e testes de fumaça

O executável legado é uma demonstração independente, não o Editor/Runtime novo. Seu loader retorna uma configuração fixa, o backend gráfico é null e subsistemas como assets ainda contêm stubs; a saída do programa não comprova carregamento de projeto, GPU ou execução de jogo.

Para reproduzir no Linux com as ferramentas de sistema indicadas abaixo e desenvolvimento X11 instalado (por exemplo, `libx11-dev` no Ubuntu):

```bash
# A instalação do Zig não usa Python; escolha um diretório que ainda não exista.
mkdir -p .cache
sh tools/install_zig.sh "$PWD/.cache/zig-0.17.0"
ZIG_EXE="$PWD/.cache/zig-0.17.0/ziglang/zig"
# Preparação e verificação das dependências sem Python.
sh tools/prepare_legacy_deps.sh --zig "$ZIG_EXE"
"$ZIG_EXE" build
"$ZIG_EXE" build test --summary all
"$ZIG_EXE" build test -Doptimize=ReleaseSafe --summary all
./zig-out/bin/CoreXEngine
```

O instalador requer `curl`, `unzip`, `sha256sum` e utilitários POSIX; o preparador em shell/Zig requer `curl` para download e utilitários POSIX. O preparador baixa os arquivos das versões fixadas, confere o SHA-256 dos arquivos e o hash de pacote Zig declarado no manifesto e inicializa o cache a partir dos diretórios extraídos. É uma solução alternativa para o cache de tarballs com pasta extra observado no Zig 0.17.0; não altera o manifesto ou os pacotes upstream. Para uso offline, forneça `--archive-dir` com `zigway.tar.gz` e `zyntra_ui.tar.gz` correspondentes às versões fixadas. A suíte legada cobre lifecycle, IDs, fila sequencial de jobs, Event Bus síncrono limitado e renderer null, além de regressões de FIFO, reentrada e falhas de alocação; não executa todos os arquivos históricos em `tests/`. A fila e o [Event Bus](docs/EVENT_BUS.md) não são paralelos nem thread-safe, e não estão integrados ao Runtime. As CIs do PR #8 e de seu merge em main passaram; alterações posteriores ainda exigem nova validação remota.

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

## Projeto de exemplo e abertura do Editor

[exemploproject/](exemploproject/README.md) contém um `.proj` schema v2 para validar a entrada do Editor. O Editor aceita o caminho posicional e recusa iniciar sem projeto. A splash 800×600, a associação do arquivo, o carregamento de recursos e o Editor gráfico ainda não estão prontos; consulte o [ADR-004](docs/ADR-004-project-opening-splash.md).
