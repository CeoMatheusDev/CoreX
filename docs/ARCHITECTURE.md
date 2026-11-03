# Arquitetura CoreX: implementado e pretendido

Este documento distingue o que existe na árvore atual do destino arquitetural. Os termos **Editor**, **Runtime** e **Renderer** não implicam, por si só, uma aplicação gráfica entregue.

## Componentes atuais

- **CoreXEngine legada:** a aplicação raiz e seus módulos existentes. Mantém seus contratos sem ser confundida com os novos executáveis Editor/Runtime.
- **Shared:** contratos e componentes usados pelos módulos independentes Editor e Runtime.
- **Editor:** CLI, abertura/preflight de projetos e descoberta de recursos. Ainda não há bootstrap gráfico, painéis integrados nem carregadores de cena/assets.
- **Core:** biblioteca Zig sem dependências (`core/`, módulo `corex_core`) com ciclo de vida e ownership explícito de subsistemas — ordem de início, teardown inverso e rollback de falha. Não contém janela, plataforma, GPU, jobs, eventos nem memória.
- **Runtime:** CLI, contratos de validação e um laço headless determinístico de passo fixo (`--frames`). Ainda não há janela de produto, cena, gameplay, renderer ou apresentação gráfica.
- **Zigway:** dependência de plataforma e janelas através de um adaptador fino em `src/platform/zigway.zig` e `src/window/zigway.zig`.
- **ZyntraUI:** dependência da build legada e adaptador em `src/ui/zyntra.zig`; não está ligada ao Editor/Runtime ou a um renderer.

O [status](STATUS.md) resume implementação e limitações; o [índice da documentação](README.md) lista os ADRs e demais contratos.

## Separação entre produto e validação

Editor/Runtime são organizados como componentes de produto; os bootstraps e ferramentas headless são executáveis de validação. Eles não substituem aplicações gráficas. Presets de qualidade, perfil de renderer, backend e perfil de produto/plataforma são conceitos diferentes e não devem ser inferidos uns dos outros.

Advanced, Standard e Lite são perfis de renderer independentes. Seus pipelines não são antecipados por esta arquitetura, nem selecionados implicitamente por backend, plataforma, preset ou fallback.

## Camada Core e execução headless

`core/` é a base compartilhável entre Editor e Runtime: `lifecycle.Lifecycle` (máquina de estados estreita, início único, teardown obrigatório mesmo após falha) e `subsystem.Registry(capacity)` (capacidade fixa, sem allocator, início na ordem de registro, parada na ordem inversa, rollback dos subsistemas já iniciados quando um falha). O estado dos subsistemas pertence ao chamador e precisa permanecer em local estável.

O pacote não tem dependências, fontes C nem opções de build: Editor e Runtime podem depender dele sem herdar decisões de plataforma ou GPU. `shared` **não** depende do Core; ele apenas define o contrato de execução (`bootstrap.Runner`, `RunRequest`, `RunReport`) que a aplicação injeta via `bootstrap.entryWith`. Sem runner, um pedido de execução continua terminando em `application.core_unavailable`.

O Runtime implementa esse contrato em `runtime/src/run_mode.zig`: dois subsistemas reais (`runtime.input` sobre `tick_input.Buffer`, `runtime.ledger` sobre o contrato de passo) conduzidos pelo `timing.Scheduler` a 60 Hz, com relógio virtual de 16 666 667 ns por frame e orçamento de 8 passos por frame. Quatro contadores independentes precisam concordar antes de qualquer relatório. O laço não recebe allocator, não lê relógio de parede, não cria janela/GPU/cena e não apresenta frame. Ver [ADR-006](ADR-006-core-library-and-headless-execution.md).

O Editor ainda não consome o Core: falta uma fase de editor concreta para embrulhar. Não há scheduler de sistemas de jogo, fila de jobs, bus de eventos novo ou gerência de memória no Core — cada um entra quando tiver consumidor real.

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
