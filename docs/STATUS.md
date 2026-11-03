# Status do projeto

**Escopo:** snapshot da branch CoreX em desenvolvimento. Consulte `APPLICATION_PROGRESS.md` para evidências por etapa; os números de validação registrados ali são históricos e devem ser lidos no contexto da respectiva fatia.

## Implementado e verificável

- A árvore legada CoreXEngine mantém uma configuração de build/testes nativos Linux para Zig 0.17.0 e declara pins de Zigway e ZyntraUI. Com os pacotes preparados e verificados por `tools/prepare_legacy_deps.sh`, o build raiz e seus testes executam nativamente (107/107 em Debug e ReleaseSafe: 46 do core legado, 11 do pacote Core, 46 do pacote Scene e 4 dos adaptadores Zigway).
- Os módulos Core, Scene, Shared, Editor e Runtime têm builds e testes próprios. Editor e Runtime oferecem contratos headless e ferramentas de linha de comando; isso não os torna aplicações gráficas.
- `core/` (módulo `corex_core`) é a primeira base compartilhável de execução: `lifecycle.Lifecycle` e `subsystem.Registry(capacity)` com início na ordem de registro, teardown inverso, rollback de falha de start e nenhum allocator no tipo. O Editor ainda não o consome; o Runtime consome.
- `scene/` (módulo `corex_scene`, dependente apenas do Core) fornece `EntityPool` geracional, `SparseSet(T)`, `World(Stores)` genérico, `Systems(WorldT)` e `Scene(WorldT)`. O World é dono de entidades/componentes; a Scene reutiliza `core.lifecycle.Lifecycle` e é registrada como subsistema. O Editor ainda não a consome.
- Testes nativos independentes em Debug e ReleaseSafe: Core **11/11**, Scene **46/46**, Shared **63/63**, Editor **36/36**, Runtime **24/24** e `tools/zig` **37/37** de integração. A referência Python permanece **33/33**.
- O Runtime tem um laço headless determinístico real (`--headless --frames N`): `timing.Scheduler` e `tick_input.Buffer` deixaram de ser modelos sem executor. São 60 Hz, frame virtual de 16 666 667 ns, orçamento de 8 passos/frame e quatro contadores cruzados antes do relatório. O Registry executa `runtime.input → runtime.scene → runtime.ledger`; a cena de fumaça embutida tem 8 entidades com `Position`/`Velocity`/`Age` e dois systems. Não há carregamento de cenas/assets/scripts, gameplay, jobs, entrada real, janela, GPU nem frame apresentado.
- Os contratos de projeto, presets, compatibilidade de versão e bootstraps possuem schemas, validadores e testes. O `VERSION` na raiz é a fonte da identidade de versão da Engine.
- O adaptador CoreX↔Zigway encaminha opções, capacidades, eventos, entrada e criação/liberação de janelas lógicas. Testes headless verificam o contrato do adaptador, não sessões de janela nativa.

## Ainda não implementado

- Não há Editor ou Runtime gráfico integrado, splash funcional, carregadores de cenas/assets/scripts, nem pipeline de renderização de produto.
- O laço headless não executa gameplay nem carrega cenas de conteúdo: a cena é uma fumaça embutida e fixa, sem assets, scripts, fila de jobs ou entrada real. `--frames` comprova contabilidade de passo fixo, ciclo de vida, execução de entidades/componentes/systems e determinismo, não simulação de jogo.
- O Core não inclui job system, event bus, gerência de memória nem contrato de handle nativo. A Scene adiciona ECS e lifecycle de cena, mas não carrega conteúdo, não serializa, não tem hierarquia/queries complexas e não é usada pelo Editor. `src/memory/allocator.zig` (pool real) pertence à árvore legada e não é importado pelo Editor/Runtime.
- Não há integração CoreX de Vulkan com Surface nativa, Device, Swapchain ou apresentação em tela.
- O adaptador de ZyntraUI existente não está conectado aos painéis do Editor, ao Runtime ou a um renderer.
- A árvore de assets indexa arquivos; isso não significa que os assets sejam decodificados, carregados ou executados.

## Limites de validação

- `zig fmt --check` passa em todos os caminhos Zig rastreados, inclusive `src/ecs/system.zig`, `src/memory/allocator.zig` e `src/scripting/lua_allocator.zig`, e esses três caminhos são verificados pelo passo `validate`. A única exceção é o cache de dependências gerado em `zig-pkg/`, que não é rastreado nem distribuído e por isso não entra no portão.
- Os três módulos legados recuperados não são usados pelo Editor, pelo Runtime nem pelo executável legado. `PoolAllocator`/`PoolRegistry` já reservam, entregam, reutilizam e liberam blocos reais, com detecção de liberação inválida, mas continuam sem consumidor no produto; eles não estão ligados ao scheduler de systems da Scene nem a uma VM Lua. Aprovar seus testes não os promove a funcionalidade de produto.
- A suíte de integração Editor/Runtime existe em duas implementações: `tools/zig/test-bootstrap-cli` (**37/37** em Debug e ReleaseSafe, 33 casos históricos + 2 de execução headless + 2 de estado final/determinismo da cena) e a referência Python `tools/test_bootstrap.py` (**33/33**, ainda em CI). O port Zig não substitui os testes unitários do bootstrap.
- A cena de fumaça é embutida e determinística; ela não valida carregamento de cena, assets, scripts, física, rede, jobs ou renderer. `entities_alive` e `state_checksum` são prova de estado do executor headless, não telemetria de produto.
- `zig build test` na raiz exige as dependências legadas preparadas e, em Linux, as bibliotecas de desenvolvimento X11 (`libx11-dev`) já declaradas no README. Nesta sessão a resolução direta de Zigway/ZyntraUI pelo build não foi exercitada: os pacotes vieram do cache verificado por hash produzido pelo preparador do próprio repositório.
- Testes do backend null são testes headless e não demonstram funcionamento de backend nativo.
- Cross-compilar para Windows não equivale a executar em Windows. Execução nativa deve ser indicada separadamente.
- A validação Vulkan real exige Surface criada a partir de uma janela nativa, Device, Swapchain e apresentação verificadas em plataforma suportada. Sem isso, Vulkan não pode ser declarado funcional.
- Consulte os resultados por fatia em `APPLICATION_PROGRESS.md`; verificações locais, cross-compilação e checks remotos são evidências distintas.

## Dependências e integração Vulkan

Zigway está fixado em `v0.1.0-alpha.4`; sua API pública fixada ainda não fornece a interface de janela nativa requerida para Surface Vulkan. Os handles nativos existem apenas no estado privado do registro do Zigway (`native_ptr`/`native_id`), sem accessor público — lê-los seria violar a API pública. A proposta upstream de integração está em revisão e não deve ser tratada como uma API lançada. Nenhum pin ou hash foi alterado para contornar essa lacuna. O trabalho não bloqueado seguiu pela base Core descrita em [ADR-006](ADR-006-core-library-and-headless-execution.md), pela camada Scene do [ADR-007](ADR-007-entity-sparse-set-and-memory.md) e pela integração headless do [ADR-008](ADR-008-scene-lifecycle-and-runtime-integration.md). Consulte [integrações](integrations.md) e [ADR-005](ADR-005-vulkan-surface-integration.md).

Este documento descreve o estado observado, não um roteiro de promessa. Uma funcionalidade só deve ser promovida para “implementada” quando código e validação correspondente estiverem disponíveis.
