# Editor/Runtime — progresso de implementação

**Data:** 2026-11-01. **Branch:** `arena/25c6e700-corex`.

ADR-001, `.proj` v1 e `presets.zon` v1 aprovados pelo usuário. Esta etapa libera implementação; não exige nova aprovação para cada módulo. O desenvolvimento é incremental e o escopo abaixo não equivale à entrega completa dos dois executáveis.

## Continuação — verificação de alvos em Zig

- `tools/zig/check_application_targets.zig` verifica os builds reais de Editor/Runtime nos três alvos não suportados, aceita somente compilador absoluto com versão **0.17.0**, status de saída normal não zero e diagnóstico específico. Não executa binários cross-compilados. O build independente em `tools/zig/` também fornece testes e `check` cross.
- `shared/platform_ext/process.zig` foi extraído em `runCommand` genérico reutilizando o mesmo supervisor bounded dos bootstraps: caminho explícito, argumentos sem shell, cwd por handle, deadline, captura limitada e reap do filho imediato. `runValidation` mantém validação e argumentos anteriores. Não há sandbox nem encerramento de árvores de processos. Seis novos testes cobrem parâmetros, dois pipes/status, timeout com pipes fechados/TERM ignorado, cwd, overflow e falha de alocação.
- Linux local: tooling **9/9** e Shared **49/49**, ambos Debug/ReleaseSafe; Editor **2/2** e Runtime **16/16** Debug; integração de processos **29/29**. Python e Zig confirmaram as mesmas seis recusas reais. Testes de CLI locais adicionais cobriram caminho Unicode/com espaços, versão errada, sucesso com mensagem indevida e erro sem diagnóstico. Windows x86_64 GNU compilou ferramenta, testes e Shared sem execução nativa. CI remota desta fatia ainda não foi executada.
- Ambas as ferramentas Python originais permanecem em execução shadow. Python/pip e outros testes continuam necessários; o PR #4 está aberto e seus caminhos/workflow precisarão de reconciliação.

## Continuação — migração incremental do tooling

- `tools/zig/check_contract_fixtures.zig` implementa de forma independente a verificação de igualdade dos exemplos, versões, backends v2 e digest de presets. Lê arquivos em tempo de execução, aceita `--root` e limita arquivos a 4 MiB. Rejeita chaves JSON duplicadas e exige versões canônicas 1/2, mais estrito que o script Python original. Isso não é validação completa dos schemas nem autenticação da distribuição.
- O verificador Python permanece e o workflow executa ambos (shadow) para evitar perda silenciosa de cobertura. Sete testes Zig incluem arquivos reais em diretório temporário Unicode, corrupção, ausência, tamanho excessivo e falhas de alocação. A comparação local com o script Python passou em nove cenários válidos/inválidos; em JSON com duplicatas, Zig rejeitou e Python aceitou, conforme esperado. Os dois não são equivalentes para todas as entradas.
- Local Linux: checker Zig **7/7** em Debug e ReleaseSafe; checker compilado para Windows x86_64 GNU e testes compilados sem execução nativa; Shared Debug/ReleaseSafe **43/43** e Runtime Debug **16/16**. A CI atualizada ainda não foi executada remotamente nesta fatia. O PR #4 continua aberto e reorganiza os scripts Python; seus caminhos e o mesmo workflow precisam ser reconciliados na integração. Python/pip ainda são usados pelo pipeline e outras ferramentas; não foi declarada sua remoção.

## Continuação — input por tick e diagnóstico Zigway

A branch atual partia de antes do PR #3; foi atualizada em fast-forward para a `main` que o incorporou. O trabalho de input descrito na conversa posterior ao PR não estava em Git e foi reconstituído nesta branch. Além disso, `enqueueBatch` agora valida e insere um lote inteiro ou nenhum evento, inclusive diante de capacidade insuficiente, tick passado, fora de ordem ou esgotamento de contador.

- `runtime/src/tick_input.zig`: buffer genérico sobre memória do chamador, com ordem estável, capacidade explícita e begin/commit/abort. Valores são cópias superficiais; não define formato de replay nem propriedade de referências. Um teste o combina ao scheduler com dados sintéticos e falha antes de efeitos externos. Abort não reverte efeitos de gameplay.
- Dois testes usam Zigway fixado, backend null e eventos sintéticos. Com capacidade 1, `key_down` é substituído por `key_up` sem incremento de `droppedEvents()`. É uma limitação observada no v0.1.0-alpha.4, não comportamento desejado. Upstream exige correção/contrato antes de prometer captura sem perdas. Nenhuma alteração upstream foi feita; não há teste de janela/input nativos.
- Linux local: Runtime **16/16** e core legado **19/19** em Debug e ReleaseSafe; Shared **43/43** Debug, Editor **2/2** Debug, integração dos bootstraps **29/29**. Build Debug Editor/Runtime passou; cross Windows x86_64 GNU compilou executáveis e testes do core e Runtime, sem execução Windows. O teste legado local usou link temporário para X11 descrito abaixo. Os testes de processo não exercitam o buffer nem Zigway null; CI remota desta fatia não foi executada.

## Continuação — Event Bus síncrono do core legado

- O antigo `publish` descartava o evento. O core agora oferece inscrições filtradas por ID, callbacks síncronos em ordem de registro, remoção e capacidade fixa pré-alocada. Reentrada e mutação do mesmo bus durante callback são rejeitadas; IDs inativos não são reutilizados. Contextos e payloads são emprestados e o bus não é thread-safe. Contrato e exemplo: `docs/EVENT_BUS.md`.
- A demonstração legada registra um callback e verifica entrega; um teste liga publicação à fila sequencial de jobs. Trata-se de componentes legados, **não** da integração do novo Runtime, de input por tick ou de um sistema paralelo.
- Linux local: build Debug e **17/17 testes** legados em Debug e ReleaseSafe passaram; Runtime Debug/ReleaseSafe passaram a partir do cache; bootstrap de integração **29/29** passou. `zig build check -Dtarget=x86_64-windows-gnu -j2` compilou executável e testes legados, sem executá-los no Windows. O build Linux usou o symlink temporário da biblioteca X11 explicado abaixo. O workflow legado foi atualizado, mas não executado remotamente nesta fatia.

## Continuação — correções da fila e confirmação de ticks

- Corrigida a fila legada: `executeAll` removia nenhum job, então repetia trabalho em chamadas subsequentes. Agora processa o lote inicial em FIFO uma vez; jobs adicionados por callbacks ficam para o próximo lote, mesmo com realocação. Execução recursiva retorna `ReentrantExecution`. Falha de alocação não remove jobs existentes; o teste histórico de jobs foi atualizado para o contexto não anulável e a nova assinatura. A fila continua sequencial, sem sincronização, sem workers/cancelamento e não está ligada ao Runtime. O proprietário mantém contexto/nome vivos e não destrói a fila durante callback.
- O agendador de tempo tinha outra armadilha: detectar overflow apenas no `commitTick` podia ocorrer **depois** dos efeitos do tick. `nextTick` permite preflight e `runDue` verifica antes de chamar cada callback, aplica o budget e confirma apenas sucessos. Erros preservam o tick falho e o backlog, não revertem efeitos já executados pelo callback; reentrada pelos métodos é recusada. Não se pressupõe retry seguro. Esse driver permanece isolado, sem loop/core/replay.
- Testes locais Linux: legado Debug e ReleaseSafe **8/8**, Runtime Debug e ReleaseSafe **10/10**, bootstrap de integração **29/29**; builds Debug Editor/Runtime/core passaram. Windows x86_64 GNU compilou Runtime e testes, sem execução nativa. Shared Debug e Editor Debug passaram a partir do cache local. Nenhuma CI remota foi executada para estas alterações. O build legado local usou o symlink temporário da biblioteca X11 explicado abaixo.

## Continuação — contabilidade de tempo fixo do Runtime

- `runtime/src/timing.zig` implementa apenas a contabilidade inteira da frequência do schema (1–1000 Hz): fase em nanossegundos × Hz, limite de planejamento por iteração, confirmação explícita após tick bem-sucedido e backlog preservado. Alpha só está disponível quando não há ticks inteiros pendentes. Erros de overflow e confirmação sem tick não alteram o estado.
- São **7 testes aritméticos** mais o smoke de imports do Runtime: taxas e limites, fronteiras e frequência racional 60 Hz, partições de tempo, atraso/catch-up, confirmação, overflow e deltas grandes. Debug e ReleaseSafe passaram (8/8 em cada); `runtime build check` passou a compilar também os testes para Windows x86_64 GNU, sem executá-los. Shared Debug 43/43, Editor Debug 2/2 e integração dos bootstraps Debug 29/29 passaram localmente. CI foi atualizada para testar Runtime ReleaseSafe, mas não foi executada remotamente nesta fatia.
- O módulo **não está ligado ao bootstrap ou a um loop**: não implementa clock, simulação, input, jobs, replay, política de pausa, logs de atraso ou estados de interpolação. `--validate-only` não gera ticks; execução normal continua recusada sem core. Orquestração e determinismo real continuam P07, sem promessa de paridade entre plataformas.

## Continuação — build legado e testes de fumaça (2026-11-02)

- P04: identificada uma solução alternativa para o cache de tarballs do Zig 0.17.0, que antes reempacotava o conteúdo com uma pasta externa adicional. `tools/prepare_legacy_deps.py` extrai as releases fixadas após verificar SHA-256 e valida o hash de pacote Zig contra o manifesto, sem alterar versões. Cache global e de pacotes isolados foram usados para verificar a reprodução. O comando normal sem preparar o cache permanece sujeito ao problema; não é uma correção upstream do Zig.
- `zig build test` da raiz apontava para `src/main.zig`, que não tinha testes. Agora executa quatro testes de fumaça explícitos: lifecycle, IDs ECS, expansão/execução de jobs e submissão ao backend null. Eles revelaram e permitiram corrigir erros de compilação antes ocultos em `JobSystem.executeAll` e `Renderer.submit`. Não substituem a suíte histórica nem testam GPU, gameplay ou recursos reais.
- Linux local: preparador e 3 testes Python passaram; `zig build` passou; 4/4 testes Zig passaram em Debug e ReleaseSafe. O teste Debug também passou com caches Zig isolados. O ambiente só possui `libX11.so.6`; para a execução local foi usado um symlink temporário de `libX11.so` via `LIBRARY_PATH`. A CI usa `libx11-dev` em vez desse artifício. Workflow novo escrito, ainda não executado no GitHub; Windows nativo/cross não foi validado nesta fatia.

## Etapa atual — Windows/Linux, 3D e UI/Canvas

Escopo corrigido pelo usuário: apenas Windows/Linux; Editor com 3D e UI/Canvas, sem modo de cena/gameplay 2D; Vulkan/OpenGL previstos nos dois e D3D11/D3D12 apenas Windows. Decisões e alternativas: **ADR-003**.

### Implementação

- A base `22d70fd` contém somente a primeira fatia. Os bootstraps descritos no histórico estavam disponíveis no commit remoto `ea6be2463e323a49ed214bdede9239aa4f59a840`, mas não na árvore-base. Seu delta foi recuperado nesta branch (sem trocar de branch) e revalidado localmente, sem presumir conclusão a partir da conversa.
- Builds/entradas independentes de Editor/Runtime, CLI, logs JSONL limitados, verificação de instalação, fingerprint e filho de validação. Não são Play nem UI gráfica.
- Novo `.proj` **v2**, enumeração fechada Vulkan/OpenGL/D3D11/D3D12 e exemplo empacotado/documentado. V1 preservado; backends antigos podem ser inspecionados, mas Metal/WebGPU não podem executar. Não há migração/gravação automática.
- `shared/scope.zig`: matriz pura e sem alocação de elegibilidade SO/API e domínios de autoria. `application.target_policy` registra a decisão e flags explícitos de GPU/renderer ainda não ligados. Execução inválida falha antes de qualquer device; validação permite inspeção cross-platform.
- Fingerprint v2 inclui perfil `desktop-3d-canvas-v1`; a identidade antiga não confirma silenciosamente o perfil novo.
- `editor/src/workspace.zig`: modelo sem alocação para trocar domínio/ferramenta 3D ou Canvas; ferramenta incompatível retorna erro sem mutação. Troca de domínio reinicia ferramenta. Ainda não ligado a painéis ou mutação real de cena.
- Builds dos aplicativos recusam macOS/FreeBSD/WASI; testes verificam o motivo da recusa. CI remove macOS e mantém Linux + cross Windows. Wheels macOS retiradas da lista de toolchain suportado.
- Zigway/ZyntraUI inspecionados: janela/input não fornecem os renderers do core; rasterizador 3D de demonstração ZyntraUI é software. Autorização para melhorias nas bibliotecas registrada, mas nenhuma alteração especulativa foi feita nelas. O bloqueio atual é o renderer/adaptador do core, não resolvido com um fork fictício de UI.

### Evidências desta branch

| Verificação | Resultado |
| --- | --- |
| Shared Debug | **43/43 passaram** |
| Editor Debug | build e **2/2 testes** passaram, incluindo interação 3D/Canvas |
| Runtime Debug | build e **1/1 smoke** passaram |
| Integração real Debug | **29/29 passaram**, incluindo v2, política de host e legado |
| Alvos fora do produto | **6 recusas verificadas**: três alvos em cada aplicativo |
| Shared ReleaseSafe | **43/43 passaram** |
| Editor ReleaseSafe | build e **2/2 testes** passaram |
| Runtime ReleaseSafe | build passou |
| Integração real ReleaseSafe | **29/29 passaram** |
| Cross Windows x86_64 GNU | shared/testes, Editor e Runtime compilaram/linkaram; sem execução nativa |
| Headers privados C++20 sem RTTI/exceções | sintaxe passou |
| YAML e schemas JSON v1/v2 | validados com parsers independentes; matriz positiva/negativa dos backends passou |
| Fixtures/hash, Python syntax e Zig fmt | passaram |

Presets/DTO C23 v1 não foram modificados semanticamente. `.proj` segue somente leitura; testes comparam bytes/mtime. Testes de processo cobrem captura dos dois pipes, timeout/reap de filho resistente a TERM, flood/limites, protocolo e fingerprint; não cobrem árvores de processos nem crash/SIGINT do Editor.

**Não há renderização GPU, UI/viewport real, cenas/assets/gameplay carregados, simulação/ticks, persistência atômica ou snapshots funcionais.** Elegibilidade de backend não comprova implementação/capacidade de hardware. A CI Linux foi confirmada para o commit de código `f540225`: [run 41367124736](https://github.com/CeoMatheusDev/CoreX/actions/runs/41367124736), **success**, job Ubuntu 24.04 em 5m24s. Contratos nos dois modos, interação, seis recusas, integração Debug/ReleaseSafe e cross Windows passaram. Não há execução nativa Windows. Atualizações posteriores somente deste relatório/README não alteram o código validado.

## Etapa 1 — contratos originais (histórico)

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

## Evidência local da etapa 1 (histórico)

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
| P04 (parcial) | Build/CI | Preparador com hashes verificados contorna o wrapper incorreto no cache; build e quatro testes de fumaça passaram localmente em Linux. Validar o novo workflow remoto, ampliar a cobertura legado e investigar correção upstream do Zig. |
| P05 | Core/renderer | Device/backend real, capacidades pré-device, viewport e draw commands da UI. Backend null não é renderer real. |
| P06 | Core/reflexão | Inspetor genérico, edição e serialização de componentes/cenas reais. |
| P07 (parcial) | Core/jobs + aplicações | Contabilidade racional e buffer genérico de input testados isoladamente; faltam loop real, replay, input/jobs integrados, política de relógio e budgets medidos. Nenhuma simulação foi implementada. |
| P08 | Plataforma/Zigway/ZyntraUI | Superfície/input/DPI e interop Windows/Linux; Zigway fixado pode substituir evento sem contabilizar perda, reproduzido em null. Corrigir/validar upstream antes de prometer captura sem perdas. Melhorias upstream autorizadas, com testes e versões fixadas. macOS removido do escopo (ADR-003). |
| P09 | Core + gameplay | Header público `engine_api.h`, negociação de ABI, C++20, sol2 e VM Lua 5.4 única. DTO privado de gráficos não substitui essa API. |
| P10/P15 (parcial) | Aplicações | CLI, logger de bootstrap, builds e filho de validação implementados. Faltam persistência atômica/backup/conflitos, logger concorrente/frame, UI real 3D/Canvas e lifecycle completo de Play. |
| P11 | Gameplay + aplicações | Hot reload Lua transacional e chamadas protegidas, com estado migrável. |
| P12 | Gameplay + aplicações | Reload C++ opcional após caminho estático, com unload seguro ou reinício explícito. |
| P13 | Build/CI + renderer | Testes GPU e medição de desempenho/budgets. |
| P14 | Aplicações | NFC completa e resolução segura no filesystem (links, caixa real, existência, permissão e contenção). Hoje caminhos não ASCII falham explicitamente; nenhuma normalização é presumida. |
| P16 | Build/CI | Distribuição verificável de Zig 0.17.0 no Windows e testes nativos dos três SOs. PyPI consultado não publicou wheel Windows desta versão. Há apenas cross-compilação Windows nesta etapa. |

## Próxima fatia planejada

Implementar CLI/logging/persistência e builds separados, resolver integração real de Zigway/ZyntraUI e formalizar contratos do adaptador do core. Bootstrap deve recusar recursos ausentes com erros claros. Só declarar janela, viewport, snapshots ou Play como funcionais depois de testes reais, sem criar uma engine paralela ou publicar mocks como implementação do core.
