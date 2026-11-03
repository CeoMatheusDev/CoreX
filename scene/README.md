# CoreX Scene (`corex_scene`)

Biblioteca Zig pura de entidades, componentes, systems e cena determinística. A única dependência é `corex_core`, usada para `Lifecycle` e para o contrato `subsystem.Step`. Não há renderer, janela, assets, scripting, física, jobs ou threads.

## Modelo

- **Entity** é um valor `{ index: u32, generation: u32 }` (8 bytes), nunca um ponteiro. Um slot está vivo quando `index < high_water` e a geração é par. Destruir soma 1 à geração (ímpar/morta) e empilha o índice numa free-list LIFO; reutilizar soma 1 de novo (par/viva). Quando a geração alcança `maxInt(u32)`, o slot é aposentado e não volta para a free-list.
- **SparseSet(T)** guarda `dense_entities[]`, `dense[]` e `sparse[]` com `posição + 1`. `insert/get/remove` são O(1), a iteração densa é contígua e a remoção usa swap-remove. A ordem densa é a de inserção alterada por swap-remove; a mesma sequência de operações é determinística.
- **World(Stores)** é genérico sobre um struct de `SparseSet(T)`. O conjunto de tipos é propriedade de comptime; não há hash lookup no caminho quente nem boxing. `add/remove/get/slice/entities` resolvem o store com `inline for`.
- **Systems(WorldT)** executa na ordem de registro, sem alocar em `run`, e interrompe no primeiro erro. Remoção por deslocamento é permitida apenas em setup.
- **Scene(WorldT)** possui o World e os Systems, usa `core.lifecycle.Lifecycle` (não cria um segundo lifecycle) e expõe `start/step/stop` para ser registrada como subsistema Core.

## Capacidade e ownership

- A capacidade inicial de entidades é escolhida pelo chamador; o pool cresce por dobra. OOM é propagado sem perder componentes já existentes. Os sparse arrays de todos os componentes crescem antes de um novo slot ficar visível.
- A capacidade de systems é fixada no `init`; excedente retorna erro. O conjunto de systems é definido no startup, então `run` não aloca e os ponteiros de contexto permanecem estáveis.
- `World.init(allocator, entity_capacity)` e `World.deinit()` são explícitos. O World é dono absoluto de todas as alocações. Destruir uma entidade remove todos os componentes via `inline for`, sem vtable. `Scene.deinit()` libera Systems e World.
- Valores de componentes são copiados por valor. Se `T` contiver ponteiros, o ownership do recurso apontado continua sendo do chamador; o World não chama destrutores.

## Uso

```zig
const corex_scene = @import("corex_scene");

const Position = struct { x: i32, y: i32 };
const Stores = struct { position: corex_scene.SparseSet(Position) };
const World = corex_scene.World(Stores);
const Scene = corex_scene.Scene(World);

var scene = try Scene.init(allocator, .{ .entity_capacity = 64, .system_capacity = 4 });
defer scene.deinit();
try scene.addSystem(.{ .name = "move", .update_fn = moveSystem });
try scene.start();
defer scene.stop();

const entity = try scene.world().create();
try scene.world().add(Position, entity, .{ .x = 0, .y = 0 });
try scene.update(.{ .index = 0, .dt_ns = 16_666_667 });
```

## Testes

```sh
cd scene && zig build test
```

São **46/46** testes em Debug e ReleaseSafe, cobrindo geração/reuso/aposentadoria de entidades, sparse set (inserção, substituição, remoção, densidade, crescimento e OOM), World (múltiplos tipos, limpeza, crescimento, regime sem alocação e deinit), Systems (ordem, remoção, erro, zero alocação) e Scene (lifecycle, falha, stop e init sem vazamento). A raiz também executa esses testes no passo `zig build test`.
