# Editor/Runtime — progresso de implementação

**Data:** 2026-11-01. **Branch:** `arena/9235d0d6-corex`.

ADR-001, `.proj` v1 e `presets.zon` v1 aprovados pelo usuário. Esta etapa libera implementação; não exige nova aprovação para cada módulo. O desenvolvimento é incremental e o escopo abaixo não equivale à entrega completa dos dois executáveis.

## Entregue nesta etapa

1. Árvore-alvo e responsabilidades em `APPLICATION_LAYOUT.md` (item 4), com arquivos atuais separados dos planejados.
2. Pacote `shared/`, independente do build legado, com Zig **0.17.0**:
   - Parser JSON limitado, sem defaults para obrigatórios, com detecção de duplicatas inclusive escapadas, recusa de desconhecidos e verificação antecipada da versão.
   - Conversão tipada estrita: strings numéricas não viram números, enums não aceitam inteiros, decimais inteiros são convertidos sem arredondamento via `f64`.
   - Validação de identidade/metadados, datas reais, SemVer, resolução, scripts e caminhos lexicais.
   - Ownership de strings em arena; destruição explícita; diagnóstico de campos via JSON Pointer em buffer próprio.
   - Serializer canônico **em memória**, com opcionais equivalentes omitidos e round-trip de todos os 13 overrides.
   - Parser ZON limitado da tabela aprovada, todos os 27 parâmetros por preset, verificação de todos os presets e merge por presença.
   - Configuração resolvida sem alocação/device; invariantes revalidadas após overrides.
3. DTO **privado de aplicação** Zig↔C23, 116 bytes, com tradução de cada campo, flags/enumerações explícitas, validação C e testes de todos os offsets/tamanho/alinhamento. Compilado com `addCSourceFiles` e `-std=c23`. **Não é a API pública do core** nem implementa GPU.
4. 27 testes Zig, com cenários de contrato, mutações determinísticas, ownership e falhas de alocação injetadas.
5. Toolchain Python fixado por versão e SHA-256 das wheels; fixtures empacotadas comparadas aos exemplos aprovados.
6. Workflow inicial de **contratos compartilhados**: Linux/macOS nativos e cross-compilação Windows. Não é a CI final das aplicações.
7. README do módulo, atualização do README raiz e registro dos portões aprovados.

## Evidência local executada

Ambiente Linux x86_64; Zig instalado em venv externo ao checkout com `ziglang==0.17.0`. O próprio binário reportou `0.17.0`. Não houve substituição por Zig 0.15/0.16.

| Verificação | Resultado |
| --- | --- |
| `cd shared && zig build test --summary all` | 27/27 testes passaram, Debug |
| `cd shared && zig build test -Doptimize=ReleaseSafe --summary all` | 27/27 testes passaram, ReleaseSafe |
| `cd shared && zig test -I . -lc root.zig -cflags -std=c23 -Wall -Wextra -Werror -- graphics_abi.c` | runner direto Zig+C23 passou |
| `cd shared && zig build check -Dtarget=x86_64-windows-gnu -j2 --summary all` | compilação/link dos testes Windows passou; sem execução |
| Header privado compilado como C++20 sem RTTI/exceções, com `c++ -fsyntax-only` | passou; não exercita gameplay C++/sol2 |
| `python tools/check_contract_fixtures.py` | exemplos e fixtures idênticos |
| `zig fmt --check shared` | passou |

Os comandos Zig foram executados nesta sessão via `python -m ziglang`, pois `zig` não estava originalmente no PATH. A tabela representa resultados locais, **não resultados do GitHub Actions**. O workflow foi escrito, mas não disparado nesta etapa. macOS nativo e Windows nativo não foram executados no sandbox Linux.

### O que os testes comprovam

- Dois consumidores em memória compartilham modelos idênticos após serialização; inclui Unicode no nome do projeto, todos os overrides, C++ dinâmico e entrypoint Lua.
- Para low/medium/high, parâmetros resolvidos são iguais entre os dois consumidores.
- `false`, seed zero, bias zero e tone mapping `none` não são substituídos por defaults.
- Entrada inválida, duplicatas, versão futura/ausente, tipos errados, limites e invariantes retornam erros em vez de usar configuração fixa.
- Arenas são liberadas nos caminhos de sucesso e nas falhas de alocação injetadas.
- DTO C23 real recebe valores traduzidos e recusa flags/enums/headers/números inválidos; layout é verificado dos dois lados.

O teste chamado Editor→Runtime ainda representa **papéis de consumidor dentro do processo de teste**, não comunicação entre binários. Não se deve reportá-lo como teste Play por processo filho.

## Limitações e pendências com responsável

| ID | Responsável | Próximo trabalho / justificativa |
| --- | --- | --- |
| P04 | Build/CI | Resolver build legado das dependências. Download por curl dos tags e `zig fetch` local retornaram hashes esperados; `zig build test` legado ainda detectou pacotes intermediários `N-V-...` com diretório wrapper e hash incompatível. Preservados hashes/versões originais, sem alteração silenciosa. |
| P05 | Core/renderer | Device/backend real, capacidades pré-device, viewport e draw commands da UI. Backend null não é renderer real. |
| P06 | Core/reflexão | Inspetor genérico, edição e serialização de componentes/cenas reais. |
| P07 | Core/jobs + aplicações | Fixed timestep/replay integrados a input/jobs e budgets medidos. Nenhuma simulação foi implementada nesta etapa. |
| P08 | Plataforma/Zigway | Confirmar capacidade macOS gráfica e portabilidade real das janelas; headless/cross-build não comprovam isso. |
| P09 | Core + gameplay | Header público `engine_api.h`, negociação de ABI, C++20, sol2 e VM Lua 5.4 única. DTO privado de gráficos não substitui essa API. |
| P10/P15 | Aplicações | Persistência atômica em disco, backup e conflitos; logger JSON lines, CLI, builds independentes do Editor/Runtime e supervisor de processo filho. |
| P11 | Gameplay + aplicações | Hot reload Lua transacional e chamadas protegidas, com estado migrável. |
| P12 | Gameplay + aplicações | Reload C++ opcional após caminho estático, com unload seguro ou reinício explícito. |
| P13 | Build/CI + renderer | Testes GPU e medição de desempenho/budgets. |
| P14 | Aplicações | NFC completa e resolução segura no filesystem (links, caixa real, existência, permissão e contenção). Hoje caminhos não ASCII falham explicitamente; nenhuma normalização é presumida. |
| P16 | Build/CI | Distribuição verificável de Zig 0.17.0 no Windows e testes nativos dos três SOs. PyPI consultado não publicou wheel Windows desta versão. Há apenas cross-compilação Windows nesta etapa. |

## Próxima fatia planejada

Implementar CLI/logging/persistência e builds separados, resolver integração real de Zigway/ZyntraUI e formalizar contratos do adaptador do core. Bootstrap deve recusar recursos ausentes com erros claros. Só declarar janela, viewport, snapshots ou Play como funcionais depois de testes reais, sem criar uma engine paralela ou publicar mocks como implementação do core.
