> **Perfil atual:** ADR-003: Windows/Linux, 3D e UI/Canvas. macOS e cena 2D fora do produto.

# Aplicações — estrutura e plano de implementação

ADR-001 e schemas `.proj`/presets aprovados pelo usuário em 2026-11-01. Detalhes do bootstrap executável: ADR-002. `[atual]` significa arquivo existente; `[planejado]` não significa recurso funcional.

## Árvore de aplicações (item 4)

```text
CoreX/
├── build.zig / build.zig.zon       # [existente] build legado; identidade Engine vem de VERSION
├── VERSION                        # [atual] única autoridade da versão de produto
├── VERSIONING.md / CHANGELOG.md    # política e histórico sem releases presumidos
├── versioning/README.md            # uso do CLI Zig version/release
├── src/                           # [existente] biblioteca core; não duplicar em aplicações
├── .gitattributes                 # [atual] LF estável para fontes/fixtures e hashes
├── shared/                        # [atual] pacote independente de contratos/bootstrap
│   ├── build.zig / build.zig.zon   # módulo corex_app; Zig + C23; testes/check cross-target
│   ├── root.zig / README.md        # exports e comandos/ownership
│   ├── scope.zig                  # [atual] elegibilidade Windows/Linux e domínios 3D/Canvas
│   ├── project.zig                # modelo, parsing/serializer JSON canônico em memória
│   ├── validation.zig             # decimal exato, metadados e caminhos lexicais
│   ├── limits.zig                 # preflight JSON/ZON com limites antes da árvore alocada
│   ├── presets.zig                # tabela ZON, resolução e invariantes dos 27 parâmetros
│   ├── graphics_abi.zig / .h / .c  # DTO C23 privado com tradução e checks de fronteira
│   ├── cli.zig                    # argumentos estritos, modos e combinações permitidas
│   ├── logging.zig                # encoder/sink JSON lines de bootstrap, escritor único
│   ├── jsonl.zig                  # framing incremental e validação do envelope recebido
│   ├── product_version.zig        # parser/comparador/transições da versão CoreX
│   ├── engine_identity.zig        # identidade de produto injetada no build
│   ├── build_identity.zig         # leitor Zig de VERSION usado pelos builds
│   ├── distribution.zig           # manifesto/tabela e compatibilidade explícita
│   ├── fingerprint.zig            # hash dos valores normalizados + tabela/distribuição
│   ├── bootstrap.zig              # orquestração compartilhada, sem estado entre processos
│   ├── testing_allocator.zig      # helper de OOM determinístico; não altera produção
│   ├── contract_tests.zig         # testes de contrato e mutações; mais unit tests nos módulos
│   ├── fixtures/
│   │   ├── EmptyGame.proj         # exemplo aprovado espelhado de docs/examples
│   │   ├── presets.zon            # única tabela aprovada usada no build/distribuição
│   │   └── distribution.template.json # template; build gera identidade e SHA-256 da tabela
│   ├── platform_ext/
│   │   ├── process.zig            # [atual] captura de dois pipes, deadline, propriedade/reap
│   │   ├── process_native.c / .h  # [atual] observar término sem reap e terminar via SO
│   │   ├── atomic_file.zig        # [planejado] replace/sync/backup e conflitos por SO
│   │   └── dynamic_library.zig    # [planejado] carga de gameplay e unload seguro
│   └── core_adapter/              # [planejado] tradução para serviços reais da biblioteca
├── editor/                        # [atual] pacote independente; bootstrap CLI, sem UI ainda
│   ├── build.zig / build.zig.zon   # shared local; instala binário, manifesto e tabela
│   ├── README.md
│   ├── src/workspace.zig          # [atual] máquina de ferramentas 3D/Canvas, sem UI/GPU ainda
│   ├── src/main.zig               # entrada com process.Init; bootstrap kind=editor
│   ├── src/application.zig        # [planejado] modelo de autoria e transações/undo
│   ├── src/play.zig               # [planejado] lifecycle real de Play, logs ao vivo, Stop
│   ├── src/panels/                # [planejado] hierarchy, inspector, content, console,
│   │                              # code, viewport; todos via ZyntraUI
│   ├── src/ui_adapter.zig         # [planejado] draw commands para renderer real do core
│   └── tests/                     # [planejado] snapshots ZyntraUI e integração Play
├── runtime/                       # [atual] pacote independente; bootstrap CLI, sem jogo ainda
│   ├── build.zig / build.zig.zon   # shared local; instala binário, manifesto e tabela
│   ├── README.md
│   ├── src/main.zig               # entrada com process.Init; bootstrap kind=runtime
│   ├── src/application.zig        # [planejado] carga/fixed timestep/interpolação/core jobs
│   ├── src/timing.zig             # [atual] contabilidade isolada de ticks, sem loop
│   ├── src/tick_input.zig         # [atual] buffer limitado independente de plataforma
│   ├── src/gameplay_host.zig      # [planejado] ABI C e VM Lua única via gameplay_api
│   └── tests/                     # [planejado] replay, simulação headless e carga real
├── include/engine_api.h           # [planejado] API pública única do core; não é o DTO privado
├── gameplay_api/                  # [planejado] C++20 + sol2 + Lua 5.4
│   ├── gameplay_api.cpp / .hpp     # bindings Entity/Transform/Input pela ABI C
│   └── tests/                     # erros protegidos, ownership e fronteiras C++/Lua
├── examples/game/                 # [planejado] cena real e scripts C++/Lua executáveis
├── exemploproject/                # [parcial] .proj v2 e pastas de exemplo, sem cena funcional
├── tools/
│   ├── zig-requirements.txt        # [transitório] fallback pip das wheels fixadas
│   ├── install_zig.sh              # [atual] instala wheel Zig Linux fixada sem Python
│   ├── prepare_legacy_deps.sh      # [atual] prepara pacotes via extrator Zig e zig fetch
│   ├── test_prepare_legacy_deps.sh # [atual] testes de integração online/offline
│   ├── test_install_zig.sh         # [atual] regressões offline do instalador
│   ├── check_python_inventory.sh  # [atual] guard transitório dos arquivos Python rastreados
│   ├── test_python_inventory.sh   # [atual] regressão do guard em índice Git temporário
│   ├── python-migration-allowlist.txt # [atual] inventário explícito até a remoção
│   ├── test_zig_validate.sh       # [atual] regressão de execução e cache da validação Zig
│   ├── check_contract_fixtures.py  # [atual] referência Python para testes diferenciais
│   ├── test_fixture_checkers.py    # [atual] comparação de CLIs em árvore temporária
│   ├── zig/                       # [atual] validadores, teste CLI, extrator e captura Linux
│   ├── ci_capture.py              # [referência] tail limitado de falhas em annotations GitHub
│   ├── test_ci_capture.py         # [atual] contrato Python e Zig: streaming, status e limpeza
│   ├── test_ci_capture_smoke.sh   # [atual] smoke do capturador Zig sem Python
│   ├── CI_CAPTURE.md              # [atual] contrato e limites da ferramenta de CI
│   └── test_bootstrap.py           # [atual] contratos entre executáveis e probes adversariais
├── .github/workflows/
│   └── shared-contracts.yml        # [atual] contratos e bootstraps; não gráficos
└── docs/                          # ADRs, schemas, CLI, layout e evidências de progresso
```

`zig-out/`, `.zig-cache/`, dependências baixadas e artefatos de teste não entram no Git. Cada pacote instala `bin/` e `share/corex/` em seu próprio prefixo. Os dois podem compartilhar um prefixo somente com manifesto/tabela idênticos.

## Fatias implementadas

1. Contratos compartilhados de documento/presets e DTO Zig/C23, sem dependência de janela ou core fictício.
2. CLI/logging e bootstraps separados; distribuição verificada; subprocesso de **validação**, não Play. Handshake compara a configuração completa e usa arquivos + CLI + JSON lines.

Parsing/resolução de presets não equivalem a resolução de recursos por filesystem/ABI nem execução pronta. Nenhum teste do bootstrap comprova renderer, jobs, gameplay, persistência atômica, snapshots ou janelas. Os binários ainda não ligam Zigway/ZyntraUI/core; isso é integração pendente, não substituição por outro toolkit.

## Pendências com responsáveis

- P04 — build/CI: resolução do build legado/pacotes Zigway/ZyntraUI, sem trocar hashes/versões para ocultar falha.
- P05/P06/P07/P09 — responsáveis pelo core e aplicações: GPU/reflexão/jobs/ABI/VM reais; sem substituí-los por mocks apresentados como produção.
- P08 — plataforma/Zigway/ZyntraUI: superfícies/input/DPI Windows/Linux e capacidades reais por backend; melhorias upstream autorizadas.
- P10/P15 — aplicações: persistência atômica/backup/conflitos, logger concorrente/frame, UI, ciclo de Play ao vivo e encerramento seguro inclusive fechamento do Editor. CLI/logs síncronos/builds/validação por filho foram entregues parcialmente.
- P14 — aplicações: NFC completa e resolução segura por filesystem/links/caixa. Caminhos não ASCII no documento falham explicitamente até sua implementação; nomes de projeto e caminho CLI ao `.proj` podem ser Unicode.
- P16 — build/CI: distribuição verificável Zig 0.17.0 Windows e testes nativos nos dois SOs. Há cross-compilação, não execução Windows.

Comandos e limitações: `APPLICATION_CLI.md`, `shared/README.md`, READMEs das aplicações. Evidências por etapa: `APPLICATION_PROGRESS.md`.
