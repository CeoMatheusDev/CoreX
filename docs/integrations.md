# Dependências legadas de UI e janelas

Esta página descreve as dependências fixadas usadas pela build legada na raiz. A presença em `build.zig.zon` não significa que estejam integradas ao Editor ou Runtime.

## Zigway — `v0.1.0-alpha.4`

CoreX possui adaptadores finos em `src/platform/zigway.zig` e `src/window/zigway.zig`. Eles encaminham opções explícitas de plataforma, consulta de backend/capacidades, criação de janelas, polling/espera de eventos, consumo da fila, estado de entrada e diagnóstico de eventos descartados. Quatro testes headless verificam esse contrato usando o backend null do Zigway; eles não abrem uma janela nativa.

O pacote fixado fornece as APIs de plataforma/janela subjacentes. Os testes CoreX não validam sessões de display X11, Wayland ou Win32. Em particular, a API pública fixada não expõe as informações emprestadas completas da janela nativa necessárias para CoreX criar Surfaces Vulkan. Esta dependência não adiciona a CoreX uma API Vulkan Surface nem transfere propriedade da janela. Consulte [ADR-005](ADR-005-vulkan-surface-integration.md).

Limitação conhecida: em um caso de overflow, a fila de eventos do backend null fixado pode remover um evento de entrada sem incrementar `droppedEvents()`. Consulte [limites de entrada do Runtime](../runtime/README.md#known-zigway-event-overflow-limitation).

## ZyntraUI — `v1.44.1`

`src/ui/zyntra.zig` contém um adaptador pequeno em torno de `zyntra_ui.Context`, com inicialização e chamadas de início/fim de frame. O pacote está fixado para a build legada, mas o adaptador não está ligado aos painéis do Editor, à UI do Runtime, a um renderer de GPU ou aos bootstraps das aplicações. Não descreva widgets, viewport, rasterizador de software ou API de acessibilidade do pacote como recurso CoreX entregue sem integração e validação próprias.

## Propriedade e validação

Zigway é responsável pela conexão de plataforma nativa e pelas janelas. CoreX recebe handles lógicos de janela e delega o ciclo de vida; os testes headless verificam apenas esse caminho. Uma futura integração Vulkan requer API upstream revisada para handles nativos emprestados, extensões corretas por plataforma e testes nativos reais antes de qualquer alteração de pin.

As versões e hashes das dependências estão declarados em [`../build.zig.zon`](../build.zig.zon). Alterar hashes de pacote exige release auditada e validação bem-sucedida; não use um branch de desenvolvimento aberto como substituto.
