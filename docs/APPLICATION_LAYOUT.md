# Aplicações — estrutura e plano de implementação

ADR-001 e schemas `.proj`/presets aprovados pelo usuário em 2026-11-01.

## Árvore-alvo (item 4)

`[atual]` indica arquivos entregues nesta etapa; `[planejado]` não indica funcionalidade existente.

```text
CoreX/
├── build.zig / build.zig.zon       # [existente] build legado; preservar até migração
├── src/                           # [existente] biblioteca core; não reimplementar nas aplicações
├── shared/                        # [atual] pacote independente de contratos de aplicação
│   ├── build.zig                  # build/testes sem Zigway/GPU/Lua
│   ├── build.zig.zon              # pacote local sem dependências externas
│   ├── root.zig / README.md       # exports e instruções de uso
│   ├── contract_tests.zig         # testes do contrato aprovado
│   ├── project.zig                # modelo, parser fechado, ownership e serializer JSON
│   ├── validation.zig             # metadados, decimal exato, caminhos lexicais
│   ├── limits.zig                 # preflight limitado JSON/ZON
│   ├── presets.zig                # tabela ZON, resolução/validação de parâmetros
│   ├── fixtures/                  # dados aprovados sincronizados com docs/examples
│   │   ├── EmptyGame.proj
│   │   └── presets.zon
│   ├── graphics_abi.zig / .h / .c # [atual] DTO privado Zig/C23 e validação de fronteira
│   ├── logging.zig               # [planejado] envelope JSON lines com buffers limitados
│   ├── cli.zig                   # [planejado] --project, --headless e limites de CI
│   ├── platform_ext/             # [planejado] processo/atomic replace/dynamic library por SO
│   └── core_adapter/             # [planejado] tradução para serviços reais da biblioteca core
├── editor/                       # [planejado] pacote independente; não criado nesta etapa
│   ├── build.zig / build.zig.zon  # Zigway + ZyntraUI + shared + core
│   ├── README.md
│   ├── src/main.zig              # bootstrap, erros e lifecycle
│   ├── src/application.zig       # modelo de autoria e transações/undo
│   ├── src/play.zig              # supervisão de filho e drenagem dos dois pipes
│   ├── src/panels/               # hierarchy, inspector, content, console, code, viewport
│   ├── src/ui_adapter.zig        # draw commands para renderer real do core
│   └── tests/                    # snapshots e integração Play
├── runtime/                      # [planejado] pacote independente; não criado nesta etapa
│   ├── build.zig / build.zig.zon  # Zigway + shared + core; UI do jogo opcional
│   ├── README.md
│   ├── src/main.zig              # bootstrap e erros estruturados
│   ├── src/application.zig       # carga do jogo/fixed timestep/interpolação
│   ├── src/gameplay_host.zig     # módulo C de gameplay e VM única
│   └── tests/                    # replay/headless/carga/erros
├── include/engine_api.h          # [planejado] autoridade única da API C, a negociar com core
├── gameplay_api/                 # [planejado] C++20 + sol2 + Lua 5.4
│   ├── gameplay_api.cpp / .hpp    # Entity/Transform/Input sem RTTI na ponte
│   └── tests/                    # erros protegidos e contratos C++/Lua
├── examples/game/                # [planejado] cena e scripts C++/Lua executáveis
├── resources/presets.zon         # [planejado] cópia de distribuição com manifesto/hash
├── tools/                       # [atual] verificação de fixtures e toolchain com hashes; empacotamento planejado
├── .github/workflows/            # [atual] shared-contracts.yml: Linux/macOS nativos, Windows cross; aplicações pendentes
└── docs/                         # ADR, schemas, layout e progresso de implementação
```

A granularidade de arquivos planejados pode ser ajustada sem alterar contratos. A árvore não atribui ao Editor funções do core nem cria promessa de renderer/reflexão inexistentes. `shared/fixtures` permite `zig test root.zig` e empacotamento independente do diretório de documentação; sua igualdade com os exemplos deve ser verificada nos testes de repositório.

## Primeira fatia de implementação

Contrato compartilhado testável em Zig 0.17.0: limites antes de parsing alocante, versão antes de interpretar corpo, modelos tipados, validação semântica independente de filesystem, serializer em memória, tabela de presets e merge por presença. Testes usam allocator de teste para detectar leaks e falhas injetadas.

Parsing do documento não equivale a resolução de arquivos/ABI nem execução pronta. Nenhum teste desta fatia inicializa device ou afirma que renderer, jobs, gameplay, persistência atômica, snapshots de ZyntraUI ou Play estão implementados.

## Bloqueios observados e próximos incrementos

- P04: Zig 0.17.0 instalado via `ziglang==0.17.0` em venv externo ao repositório. `zig fetch` dos archives locais produz hashes esperados, mas `zig build test` legado reporta hashes `N-V-...` de pacotes contendo diretório intermediário. Investigar resolução/empacotamento sem alterar versões ou hashes para mascarar falha.
- P05/P06/P07/P09: renderer GPU, reflexão, jobs determinísticos e ABI/VM real ainda dependem do core. Não serão substituídos por implementações fictícias na aplicação.
- P14 (responsável: aplicações): implementar verificação NFC completa e resolução segura por filesystem/links/caixa. Enquanto não houver NFC, caminhos não ASCII serão recusados explicitamente com `UnicodePathNormalizationUnavailable` na camada lexical, em vez de aceitar caminhos sem comprovar o contrato. Nomes de projeto Unicode são suportados. Essa restrição temporária não muda o schema aprovado.
- P15 (responsável: aplicações): persistência atômica/backup, logs/CLI, builds dos dois executáveis, integração real Zigway/ZyntraUI, supervisor Play e CI de aplicações serão incrementos posteriores; não confundir serializer em memória com escrita atômica em disco.

O escopo de cada etapa será reportado por testes executados, sem declarar o conjunto completo concluído antecipadamente.

- P16 (responsável: build/CI): obter distribuição verificável de Zig 0.17.0 para Windows e habilitar testes nativos. PyPI desta versão não lista wheel Windows. A matriz inicial só executa contratos compartilhados em Linux/macOS e cross-compila Windows; não satisfaz ainda CI completa das duas aplicações nos três SOs.

## Resultado desta fatia

`shared/README.md` documenta API, comandos, ownership e restrições. Módulo inclui DTO C23 privado com tradução explícita e verificações independentes dos 27 campos, sem inventar interface do core. `tools/zig-requirements.txt` fixa toolchain e hashes. Resultados locais e pendências estão em `docs/APPLICATION_PROGRESS.md`.
