# ADR-006: biblioteca Core comum e execução headless determinística

- **Status:** aceito; primeira fatia implementada (Core e Runtime). Estendido por [ADR-007](ADR-007-entity-sparse-set-and-memory.md) e [ADR-008](ADR-008-scene-lifecycle-and-runtime-integration.md); as limitações e contagens abaixo descrevem esta fatia, não o estado atual.
- **Data:** 2026-11-03.
- **Substitui:** nada.
- **Relacionado:** [ADR-001](ADR-001-editor-runtime.md), [ADR-002](ADR-002-validation-bootstrap.md), [ADR-005](ADR-005-vulkan-surface-integration.md), [ADR-007](ADR-007-entity-sparse-set-and-memory.md), [ADR-008](ADR-008-scene-lifecycle-and-runtime-integration.md).

## Contexto

A auditoria de 2026-11-03 confirmou três fatos no código, não nos READMEs:

1. Editor e Runtime compartilham apenas `shared/`, que é uma camada de contratos (CLI, projeto, presets, DTO C23, logging) e não possui ciclo de vida, ownership de subsistemas nem executor.
2. O Runtime tem dois modelos testados e **sem consumidor**: `src/timing.zig` (acumulador de passo fixo) e `src/tick_input.zig` (buffer de entrada por tick). Nenhum laço de execução existia; sem `--validate-only`, o bootstrap terminava em `application.core_unavailable` com exit 4.
3. A integração Vulkan segue bloqueada pelo pin do Zigway (`v0.1.0-alpha.4`): não há accessor público de handle nativo, extensões ou criação de Surface (ver ADR-005). Nenhuma fatia futura deve contornar isso.

Faltava, portanto, a base que o ADR-005 já listava como bloqueio próprio ("módulo privado comum do Engine usado por Editor/Runtime") e que a Fase 1 do plano de desenvolvimento exige: contratos de ciclo de vida e ownership compartilhados, sem arrastar dependências gráficas para `shared`.

## Decisão

1. **Criar o pacote `core/`** (módulo `corex_core`), biblioteca Zig pura, sem dependências externas, sem C, sem janela, sem GPU. Escopo desta fatia: `lifecycle.Lifecycle` e `subsystem.Registry(capacity)` com `Subsystem.adopt`.
2. **`shared` continua sem ligar o Core.** Ele define apenas o contrato de execução (`bootstrap.Runner`, `RunRequest`, `RunReport`) e aceita um runner opcional via `bootstrap.entryWith`. Assim `shared` não herda decisões de plataforma/GPU e continua utilizável por qualquer aplicação.
3. **A aplicação fornece o executor.** O Runtime passa `run_mode.run` como runner; o Editor passa `null` e por isso continua relatando `application.core_unavailable` quando alguém pede execução. Não existe runner inventado dentro de `shared`.
4. **Execução é opt-in explícito.** `--frames <1..1000000>` é aceito só no Runtime, só junto de `--headless` e nunca com `--validate-only`/`--check-runtime`. Qualquer outra combinação é erro de CLI (exit 2), não um padrão implícito.
5. **O modo headless é determinístico e declarado como tal.** O laço usa um relógio virtual (16 666 667 ns por frame, 1/60 s arredondado para cima), frequência de 60 Hz e orçamento de 8 passos por frame. Não lê tempo de parede, não cria janela, device, swapchain, cena ou assets, não apresenta frame e não registra entrada real. Os eventos `runtime.run_starting`/`runtime.run_complete` afirmam exatamente isso (`gpu_created=false`, `window_created=false`, `presented_frames=0`, `play_started=false`).

## Arquitetura resultante

```text
editor ─┐                    ┌─ core (lifecycle + subsystem registry)
        ├─ shared (contratos)│
runtime ┘        │           └─ runtime/run_mode (laço headless)
                 └─ Runner { context, run }  ← injetado pelo Runtime
```

- Ordem de inicialização: ordem de registro. Teardown: ordem inversa exata.
- Falha ao iniciar um subsistema: os já iniciados são parados em ordem inversa, o registro vai para `failed` e o erro original é propagado. O teardown posterior continua sendo obrigatório e é permitido a partir de `failed`.
- `Registry` não recebe `std.mem.Allocator`: a capacidade é fixada em tempo de compilação e o caminho de passo não aloca. O estado dos subsistemas é do chamador, que deve mantê-lo em local estável.
- O laço cruza quatro contadores independentes (`steps`, `ticks` do scheduler, `input_ticks` do buffer e `ledger.steps`) e devolve `error.AccountingMismatch` antes de reportar qualquer número.

## Consequências

**Positivas**

- Primeira infraestrutura realmente compartilhável entre Editor e Runtime, sem dependências gráficas nem alocação no caminho quente.
- O laço de passo fixo existe e é verificável: `timing.Scheduler` e `tick_input.Buffer` passaram de modelos isolados a componentes executados.
- O contrato de erro/teardown é testável e determinístico, o que reduz risco quando subsistemas reais (cena, assets, jobs) forem adicionados.
- Nenhuma alegação gráfica nova: o caminho Vulkan continua exatamente tão bloqueado quanto antes.

**Negativas / limites**

- Nesta fatia, o laço ainda não executa gameplay: não há cena, ECS conectado, assets, scripts, fila de jobs nem entrada real. `--frames` prova contabilidade de passo fixo e ciclo de vida, não simulação de jogo. (O ADR-008 conecta uma cena de fumaça embutida; carregamento de cena de conteúdo e gameplay continuam fora.)
- O Editor ainda não consome o Core; adotá-lo exige uma fase de editor para embrulhar, o que não existe hoje.
- Job system, event bus e gerência de memória continuam fora do Core de propósito: cada um precisa de consumidor real antes de ser promovido, e o pool real de `src/memory/allocator.zig` é da árvore legada, que não é importada pelas aplicações.
- `core/` e `runtime/src/run_mode.zig` mantêm o mesmo limite superior de frames (1 000 000) por não haver dependência de `shared` para o Runtime; os dois lados rejeitam valores acima em vez de truncar.

## Alternativas rejeitadas

- **Ligar `core` dentro de `shared`:** arrastaria decisões de execução para a camada de contratos e impediria que o Editor recusasse execução por construção.
- **Executar sem flag (tratando `--headless` como pedido de execução):** transformaria um bootstrap de validação em Player implícito e quebraria o contrato já testado de `application.core_unavailable`.
- **Usar relógio de parede nesta fatia:** produziria execuções não reproduzíveis em CI/sandbox e mascararia erros de contabilidade com ruído de agendamento.
- **Reaproveitar `src/core/engine.zig` legado como Core:** é um ciclo de vida mínimo preso à árvore legada, que Editor e Runtime não importam (e não devem importar junto com Zigway/Null Backend).

## Validação desta fatia

- `core`: `zig build test` **11/11**.
- Runtime: `zig build test` **22/22** (inclui o laço headless e o ledger de passos).
- Raiz: `zig build test` **61/61** em Debug e ReleaseSafe com cache limpo (46 legado + 11 Core + 4 adaptadores Zigway).
- `zig build validate` 10/10 passos (inclui `zig fmt --check` sobre `core/`).
- `tools/zig`: `zig build test-bootstrap-cli` **35/35** em Debug e ReleaseSafe (33 casos anteriores + 2 novos de execução/CLI); `tools/test_bootstrap.py` permaneceu **33/33**.
- `zig build check -Dtarget=x86_64-windows-gnu` compilou (cross, sem execução nativa).
- Execução real verificada: `CoreXRuntime --project docs/examples/EmptyGame.proj --headless --frames 120` → exit 0 com `frames=120, steps=120, ticks=120, input_ticks=120, phase_remainder=2400, presented_frames=0`.

## Próximos passos recomendados

1. Fase 2 (contrato de handle nativo) continua bloqueada pelo upstream do Zigway; não avançar por leitura de campos privados.
2. Adotar o Core no Editor quando houver uma fase de editor a embrulhar (documento carregado, política de scope, distribuição), mantendo `shared` sem depender do Core.
3. **Concluído pelo [ADR-008](ADR-008-scene-lifecycle-and-runtime-integration.md):** conectar cena/ECS ao `Registry` como subsistema real, com uma cena de fumaça embutida; conteúdo e gameplay continuam pendentes.
4. Só então retomar Vulkan, com environment nativo e o contrato de superfície do ADR-005 resolvido.
