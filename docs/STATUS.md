# Status do projeto

**Escopo:** snapshot da branch CoreX em desenvolvimento. Consulte `APPLICATION_PROGRESS.md` para evidências por etapa; os números de validação registrados ali são históricos e devem ser lidos no contexto da respectiva fatia.

## Implementado e verificável

- A árvore legada CoreXEngine mantém uma configuração de build/testes nativos Linux para Zig 0.17.0 e declara pins de Zigway e ZyntraUI. O build raiz depende da resolução desses pacotes.
- Os módulos Shared, Editor e Runtime têm builds e testes próprios. Editor e Runtime oferecem contratos headless e ferramentas de linha de comando; isso não os torna aplicações gráficas.
- Os contratos de projeto, presets, compatibilidade de versão e bootstraps possuem schemas, validadores e testes. O `VERSION` na raiz é a fonte da identidade de versão da Engine.
- O adaptador CoreX↔Zigway encaminha opções, capacidades, eventos, entrada e criação/liberação de janelas lógicas. Testes headless verificam o contrato do adaptador, não sessões de janela nativa.

## Ainda não implementado

- Não há Editor ou Runtime gráfico integrado, splash funcional, carregadores de cenas/assets/scripts, nem pipeline de renderização de produto.
- Não há integração CoreX de Vulkan com Surface nativa, Device, Swapchain ou apresentação em tela.
- O adaptador de ZyntraUI existente não está conectado aos painéis do Editor, ao Runtime ou a um renderer.
- A árvore de assets indexa arquivos; isso não significa que os assets sejam decodificados, carregados ou executados.

## Limites de validação

- A verificação global `zig fmt --check` não passa atualmente: `src/ecs/system.zig`, `src/memory/allocator.zig` e `src/scripting/lua_allocator.zig` contêm sintaxe incompatível ou comentário de documentação inválido em Zig 0.17.0. Não foram reescritos nesta revisão porque isso exigiria alterar contratos de módulos legados não cobertos pela validação atual.
- Nesta revisão, `zig build test -j2` não conseguiu resolver os pins de Zigway/ZyntraUI (`ResolvConfParseFailed`). Nenhum pin/hash foi alterado e `/etc/resolv.conf` não foi modificado.
- Testes do backend null são testes headless e não demonstram funcionamento de backend nativo.
- Cross-compilar para Windows não equivale a executar em Windows. Execução nativa deve ser indicada separadamente.
- A validação Vulkan real exige Surface criada a partir de uma janela nativa, Device, Swapchain e apresentação verificadas em plataforma suportada. Sem isso, Vulkan não pode ser declarado funcional.
- Consulte os resultados por fatia em `APPLICATION_PROGRESS.md`; verificações locais, cross-compilação e checks remotos são evidências distintas.

## Dependências e integração Vulkan

Zigway está fixado em `v0.1.0-alpha.4`; sua API pública fixada ainda não fornece a interface de janela nativa requerida para Surface Vulkan. A proposta upstream de integração está em revisão e não deve ser tratada como uma API lançada. Nenhum pin ou hash foi alterado para contornar essa lacuna. Consulte [integrações](integrations.md) e [ADR-005](ADR-005-vulkan-surface-integration.md).

Este documento descreve o estado observado, não um roteiro de promessa. Uma funcionalidade só deve ser promovida para “implementada” quando código e validação correspondente estiverem disponíveis.
