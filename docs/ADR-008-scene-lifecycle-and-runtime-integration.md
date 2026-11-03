# ADR-008: lifecycle da Scene e integração real no Runtime

- **Status:** aceito; implementado em `scene/` e no Runtime headless.
- **Data:** 2026-11-03.
- **Substitui:** nada.
- **Relacionado:** [ADR-006](ADR-006-core-library-and-headless-execution.md), [ADR-007](ADR-007-entity-sparse-set-and-memory.md).

## Contexto

O ADR-006 entregou o Core (`lifecycle.Lifecycle` e `subsystem.Registry`) e um laço headless com `timing.Scheduler`, `tick_input.Buffer` e um ledger. Faltava o estado da aplicação: uma cena real, entidades/componentes e systems executados no mesmo caminho, sem duplicar lifecycle nem scheduler.

A restrição central é não inventar um segundo ciclo de vida. A Scene precisa ser um subsistema Core comum, iniciado e parado pelo `Registry`, e o Runtime precisa continuar sem janela, GPU, assets, scripts, threads ou relógio de parede.

## Decisão

### 1. Scene usa o lifecycle do Core

`Scene(WorldT)` possui:

- um `World(Stores)`;
- um `Systems(WorldT)`;
- um `core.lifecycle.Lifecycle` (o mesmo tipo do Core, não uma cópia).

Transições:

- `created → starting → running` em `start()`;
- `update(step)` só é aceito em `running`;
- erro de system marca `failed` e é propagado sem rollback parcial;
- `stop()`/`tryStop()` aceitam `running` ou `failed` e levam a `stopped`;
- `stopped` é terminal; um novo uso exige nova Scene.

`start()` é falível para que trabalho de start futuro não mude a assinatura. `stop()` é `void` porque `Subsystem.adopt` exige um `stop` que não falha; `tryStop()` expõe `InvalidTransition` para chamadas explícitas.

### 2. Scene é um subsistema Core

A Scene expõe `start`, `step` e `stop` com as assinaturas exigidas por `Subsystem.adopt`. O Runtime a registra como `runtime.scene`, na ordem:

```text
runtime.input → runtime.scene → runtime.ledger
```

O `Registry` faz start na ordem de registro, step na mesma ordem e teardown inverso. Não há scheduler paralelo, fila de cena ou lifecycle duplicado. O ledger continua verificando índices contíguos e `dt_ns` constante.

### 3. Builder explícito depois do start

O Runtime cria a Scene, registra os systems e registra a Scene no `Registry`. Somente depois de `registry.start()` o builder `headless_app.populate` cria entidades e componentes. Isso mantém a fronteira de ownership: a Scene já está `running`, mas o World continua pertencendo à Scene.

### 4. Allocator vem de `main`, sem global

`run_mode.run(allocator, request)` recebe o allocator explicitamente. `main` monta um `Context { gpa }` na stack e o passa em `Runner.context`; o runner faz `@ptrCast(@alignCast)` e usa `state.gpa`. Não há allocator global, singleton ou estado de processo escondido.

### 5. Cena de fumaça declarada, não gameplay

`runtime/src/headless_app.zig` define uma cena de fumaça determinística:

- 8 entidades com `Position`, `Velocity` e `Age`;
- system `smoke.move`: `position += velocity`;
- system `smoke.age`: `age.ticks += 1`;
- iteração por índice crescente de entidade.

O relatório ganhou dois campos aditivos:

- `entities_alive`: quantidade de entidades vivas ao final;
- `state_checksum`: FNV-1a 64 sobre handles e valores de componentes em ordem de índice.

Esses campos aparecem em `runtime.run_complete`, em `shared.bootstrap.RunReport` e em `run_mode.Report`. O evento também declara `scene="smoke"`. A cena **não** é gameplay, não carrega assets, não lê entrada real e não prova renderer. Ela existe para provar que o caminho headless executa estado real e determinístico.

### 6. Determinismo

- Sem threads, sem relógio de parede e sem GPU.
- O scheduler usa 60 Hz, frame virtual de 16 666 667 ns e orçamento de 8 passos/frame.
- A iteração de entidades e de systems é documentada e estável.
- Duas execuções com o mesmo `--frames` produzem o mesmo checksum; contagens diferentes produzem checksums diferentes.
- O checksum usa ordem de índice, não ordem de hash map.

## Fluxo completo

```text
main(Context{gpa})
  └─ bootstrap.entryWith(init, .runtime, Runner{context, run})
       └─ run_mode.run(gpa, {frames})
            ├─ headless_app.init(gpa)                 Scene + World + Systems
            ├─ installSystems                         antes de start
            ├─ Registry(3)
            │    ├─ runtime.input
            │    ├─ runtime.scene   (Scene.adopt)
            │    └─ runtime.ledger
            ├─ registry.start()                       created → running
            ├─ headless_app.populate()                depois do start
            ├─ loop: scheduler → registry.step()      input → scene → ledger
            ├─ cross-check steps/ticks/input/ledger
            ├─ entities_alive + state_checksum
            └─ registry.stop() → Scene.deinit()
```

## Alternativas rejeitadas

- **Criar um segundo lifecycle na Scene:** duplicaria estados e tornaria o teardown ambíguo.
- **Registrar a Scene fora do Registry:** o Runtime teria dois caminhos de start/stop e o ledger não veria a cena na ordem.
- **Popular a cena antes do start:** misturaria construção de estado com lifecycle e enfraqueceria a prova de que o builder roda no caminho real.
- **Allocator global/estático:** dificultaria testes de vazamento e esconderia ownership.
- **Chamar a cena de fumaça de Play ou gameplay:** seria uma alegação falsa; o evento declara `play_started=false` e `gpu_created=false`.
- **Usar hash map para checksum:** a ordem dependeria de detalhes de implementação; índice crescente é determinístico e auditável.

## Consequências

**Positivas**

- O Runtime passa a executar estado de aplicação real, não apenas contadores.
- A Scene reutiliza o lifecycle e o scheduler existentes; não há caminho paralelo.
- O checksum prova determinismo entre execuções e sensibilidade à contagem de ticks.
- O allocator explícito permite provar zero alocação por tick e detectar vazamentos com `std.testing.allocator`.

**Limites**

- A cena de fumaça é fixa e embutida; não há carregamento de cena, assets, scripts, prefabs ou serialização.
- Não há hierarquia, queries complexas, jobs, física, networking ou editor de cenas.
- `entities_alive` e `state_checksum` não são gameplay, telemetria de produto nem prova de renderer.
- O Editor continua sem consumir Core/Scene.
- Vulkan continua bloqueado pelo ADR-005.

## Validação

- `scene`: **46/46** testes em Debug e ReleaseSafe.
- Runtime: **24/24** testes (inclui cena de fumaça, determinismo e zero alocação por tick).
- Raiz: **107/107** testes em Debug e ReleaseSafe.
- `tools/zig test-bootstrap-cli`: **37/37** em Debug e ReleaseSafe; `tools/test_bootstrap.py`: **33/33**.
- Execução real: `CoreXRuntime --project docs/examples/EmptyGame.proj --headless --frames 120` → exit 0, `frames=120`, `steps=120`, `ticks=120`, `input_ticks=120`, `phase_remainder=2400`, `entities_alive=8`, `state_checksum=4676086859710612434`, `presented_frames=0`.
- `zig build validate`: **11/11** passos; cross Windows: raiz **7/7**, Scene **2/2**, Runtime **4/4** (sem execução Windows).
