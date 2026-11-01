# Integração CoreX Engine — Zigway + ZyntraUI

## Zigway (v0.1.0-alpha.4)

Melhorias recentes incorporadas na arquitetura:
- `Platform` / `Window` nativo (Win32, X11, Wayland, Null)
- Generational `WindowHandle` (prevenção de stale handles)
- Event loop com `waitEvents(timeout)` (não busy-wait) e `wakeup()` (thread-safe)
- Clipboard (`clipboard` UTF-8 via `CLIPBOARD` / `CF_UNICODETEXT`)
- Pointer capture (`capture`, `lock`, `confinement`) + `relative_motion`
- Fullscreen (`fullscreen` com EWMH no X11, borderless popup no Win32)
- Monitor enumeration (`monitor` com RandR / `EnumDisplaySettings`)
- Multi-window (`multiple_windows` com z-order e focus routing)
- Headless null backend para testes CI
- `Platform.capabilities()` para verificar suporte por backend

Arquivos na CoreX:
- `src/platform/zigway.zig`
- `src/window/zigway.zig`

## ZyntraUI (v1.44.1)

Melhorias recentes incorporadas na arquitetura:
- 35 widgets organizados por categoria (input, navigation, feedback, composition)
- Immediate-mode com frame `beginFrame` → widgets → `drawCommands` → `endFrame`
- Flex layout (`flex`) distribuído sem alocação (row/column, grow/shrink, gap)
- Dirty rect (`dirty_rect`) + partial repaint (`repaint` apenas o que mudou)
- Font atlas (`glyph atlas`) com medidas consistentes; fallback metrics quando não há fonte real
- IME (`ime`) com pre-edit (`pre_edit`) sem alocação interna; `textInputIme`
- Accessibility (`a11y`) — árvore semântica por frame
- Multi-surface (`WindowRegistry`) — z-order, focus, desktop/local coordinates, compositor (`compose`)
- Decoration (`decorations`) — title bar, resize border, close button, drag geometry
- Interactor (`interactor`) — drag/resize/move sem alocação
- Software rasterizer (`raster`) — referência para integração com renderizador externo
- Viewport 3D (`viewport3d`) — cubo, grid, câmera, ray picking, gizmo, sem GPU
- Performance: `reserveDrawCommands`, `FrameMetrics` (comandos por tipo, bytes, glyph runs), virtualização (`fixedRange`/`variableRange`), cache opcional (`text.cache`)

Arquivos na CoreX:
- `src/ui/zyntra.zig`

## Uso Planejado na Engine

1. `Platform` da CoreX delegará para Zigway (`platform.zig` importará `zigway.zig`)
2. `Window` da CoreX usará generational handles e event loop do Zigway
3. `UI` / `Debug` usará ZyntraUI para overlays de debug (FPS, stats, profiler)
4. O renderer da CoreX consumirá os `drawCommands` do ZyntraUI como comandos gráficos internos
