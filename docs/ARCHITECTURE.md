# Arquitetura CoreX: implementado e pretendido

Este documento distingue o que existe na árvore atual do destino arquitetural. Os termos **Editor**, **Runtime** e **Renderer** não implicam, por si só, uma aplicação gráfica entregue.

## Componentes atuais

- **CoreXEngine legada:** a aplicação raiz e seus módulos existentes. Mantém seus contratos sem ser confundida com os novos executáveis Editor/Runtime.
- **Shared:** contratos e componentes usados pelos módulos independentes Editor e Runtime.
- **Editor:** CLI, abertura/preflight de projetos e descoberta de recursos. Ainda não há bootstrap gráfico, painéis integrados nem carregadores de cena/assets.
- **Runtime:** CLI e contratos de execução/headless. Ainda não há janela de produto, renderer ou apresentação gráfica.
- **Zigway:** dependência de plataforma e janelas através de um adaptador fino em `src/platform/zigway.zig` e `src/window/zigway.zig`.
- **ZyntraUI:** dependência da build legada e adaptador em `src/ui/zyntra.zig`; não está ligada ao Editor/Runtime ou a um renderer.

O [status](STATUS.md) resume implementação e limitações; o [índice da documentação](README.md) lista os ADRs e demais contratos.

## Separação entre produto e validação

Editor/Runtime são organizados como componentes de produto; os bootstraps e ferramentas headless são executáveis de validação. Eles não substituem aplicações gráficas. Presets de qualidade, perfil de renderer, backend e perfil de produto/plataforma são conceitos diferentes e não devem ser inferidos uns dos outros.

Advanced, Standard e Lite são perfis de renderer independentes. Seus pipelines não são antecipados por esta arquitetura, nem selecionados implicitamente por backend, plataforma, preset ou fallback.

## Fronteira gráfica futura

A integração gráfica depende de propriedade de recursos nativos bem definida:

1. O adaptador de janela cria e destrói a janela.
2. Uma futura camada Vulkan cria e destrói a Surface associada; a Surface não destrói a janela.
3. A camada gráfica gerencia Device, Swapchain, filas de Graphics/Present e apresentação. Graphics e Present podem exigir filas distintas.
4. A destruição ocorre na ordem inversa das dependências: recursos de apresentação, Surface e, por fim, janela.

Uma implementação real precisa lidar com capacidades consultadas na Surface, `SUBOPTIMAL`, `OUT_OF_DATE`, `SURFACE_LOST`, resize, minimização/extent zero e falha do Device. Não deve aguardar o Device ocioso a cada frame nem alocar desnecessariamente no caminho quente.

Até haver Surface, Device, Swapchain e apresentação efetivamente validados, essa fronteira é requisito arquitetural, não funcionalidade entregue. A decisão pendente e a dependência upstream estão em [ADR-005](ADR-005-vulkan-surface-integration.md).

## Árvore arquitetural inicial

`architecture/initial.md` é mantido como registro histórico da proposta inicial. Se divergir dos contratos numerados ou deste estado atual, prevalecem os ADRs e a documentação atualizada.
