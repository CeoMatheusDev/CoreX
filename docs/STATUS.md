# Status do projeto

**Escopo:** snapshot da branch CoreX em desenvolvimento. Consulte `APPLICATION_PROGRESS.md` para evidências por etapa; os números de validação registrados ali são históricos e devem ser lidos no contexto da respectiva fatia.

## Implementado e verificável

- A árvore legada CoreXEngine mantém uma configuração de build/testes nativos Linux para Zig 0.17.0 e declara pins de Zigway e ZyntraUI. Com os pacotes preparados e verificados por `tools/prepare_legacy_deps.sh`, o build raiz e seus testes executam nativamente (50/50 em Debug e ReleaseSafe: 46 do core legado e 4 dos adaptadores Zigway).
- Os módulos Shared, Editor e Runtime têm builds e testes próprios. Editor e Runtime oferecem contratos headless e ferramentas de linha de comando; isso não os torna aplicações gráficas.
- Os contratos de projeto, presets, compatibilidade de versão e bootstraps possuem schemas, validadores e testes. O `VERSION` na raiz é a fonte da identidade de versão da Engine.
- O adaptador CoreX↔Zigway encaminha opções, capacidades, eventos, entrada e criação/liberação de janelas lógicas. Testes headless verificam o contrato do adaptador, não sessões de janela nativa.

## Ainda não implementado

- Não há Editor ou Runtime gráfico integrado, splash funcional, carregadores de cenas/assets/scripts, nem pipeline de renderização de produto.
- Não há integração CoreX de Vulkan com Surface nativa, Device, Swapchain ou apresentação em tela.
- O adaptador de ZyntraUI existente não está conectado aos painéis do Editor, ao Runtime ou a um renderer.
- A árvore de assets indexa arquivos; isso não significa que os assets sejam decodificados, carregados ou executados.

## Limites de validação

- `zig fmt --check` passa em todos os caminhos Zig rastreados, inclusive `src/ecs/system.zig`, `src/memory/allocator.zig` e `src/scripting/lua_allocator.zig`, e esses três caminhos são verificados pelo passo `validate`. A única exceção é o cache de dependências gerado em `zig-pkg/`, que não é rastreado nem distribuído e por isso não entra no portão.
- Os três módulos legados recuperados não são usados pelo Editor, pelo Runtime nem pelo executável legado. `PoolAllocator`/`PoolRegistry` já reservam, entregam, reutilizam e liberam blocos reais, com detecção de liberação inválida, mas continuam sem consumidor no produto; não há scheduler de sistemas nem VM Lua conectada. Aprovar seus testes não os promove a funcionalidade de produto.
- `zig build test` na raiz exige as dependências legadas preparadas e, em Linux, as bibliotecas de desenvolvimento X11 (`libx11-dev`) já declaradas no README. Nesta sessão a resolução direta de Zigway/ZyntraUI pelo build não foi exercitada: os pacotes vieram do cache verificado por hash produzido pelo preparador do próprio repositório.
- Testes do backend null são testes headless e não demonstram funcionamento de backend nativo.
- Cross-compilar para Windows não equivale a executar em Windows. Execução nativa deve ser indicada separadamente.
- A validação Vulkan real exige Surface criada a partir de uma janela nativa, Device, Swapchain e apresentação verificadas em plataforma suportada. Sem isso, Vulkan não pode ser declarado funcional.
- Consulte os resultados por fatia em `APPLICATION_PROGRESS.md`; verificações locais, cross-compilação e checks remotos são evidências distintas.

## Dependências e integração Vulkan

Zigway está fixado em `v0.1.0-alpha.4`; sua API pública fixada ainda não fornece a interface de janela nativa requerida para Surface Vulkan. A proposta upstream de integração está em revisão e não deve ser tratada como uma API lançada. Nenhum pin ou hash foi alterado para contornar essa lacuna. Consulte [integrações](integrations.md) e [ADR-005](ADR-005-vulkan-surface-integration.md).

Este documento descreve o estado observado, não um roteiro de promessa. Uma funcionalidade só deve ser promovida para “implementada” quando código e validação correspondente estiverem disponíveis.
