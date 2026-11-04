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
- `World.init(allocator, entity_capacity)` e `World.deinit()` são explícitos. O World é dono do pool e dos buffers dos stores, não dos recursos apontados pelos componentes. Destruir uma entidade remove todos os componentes via `inline for`, sem vtable. `Scene.deinit()` libera Systems e World.
- Valores de componentes são copiados por valor. Se `T` contiver ponteiros, o ownership do recurso apontado continua sendo do chamador; o World não chama destrutores.


## Hierarquia e cenas de conteúdo

`hierarchy.Parent` e `hierarchy.Children` são componentes opcionais; declare ambos os `SparseSet`s no `Stores`, com qualquer nome de campo. As operações usam o mesmo allocator que criou as listas. Antes de `world.destroy(entity)`, chame `hierarchy.onDestroy(World, allocator, &world, entity)`; antes de `world.deinit()`, chame `hierarchy.clear(World, allocator, &world)` para liberar todas as listas. `onDestroy` pode ter concluído alguns reparentings se houver falha de alocação: os vínculos ficam consistentes e a operação pode ser repetida.

`content_format.parse`, `content_loader.load` e `content_serializer.serialize` usam o descritor JSON de conteúdo existente. A hierarquia é uma **extensão opcional**: arquivos antigos sem os campos continuam válidos, e o serializer não os emite em cenas planas. Leitores antigos que rejeitam campos desconhecidos não conseguem ler os novos vínculos. O `.proj` e seus schemas não foram alterados.

```json
{
  "entity_capacity": 8,
  "system_capacity": 4,
  "entities": [
    {"parent_index": 1, "sibling_index": 1, "components": [{"kind": "position", "x": 10, "y": 0}]},
    {"components": [{"kind": "position", "x": 20, "y": 0}]},
    {"parent_index": 1, "sibling_index": 0, "components": [{"kind": "position", "x": 30, "y": 0}]}
  ]
}
```

- `parent_index` é a posição **zero-based no array `entities`**, não um slot ou handle do World; pais podem aparecer depois dos filhos. Ausente ou `null` significa raiz. Slots destruídos e gerações são remapeados ao salvar/carregar.
- `sibling_index` preserva a ordem exposta por `getChildren`. Para cada pai, informe todos os índices como uma permutação de `0..N-1` ou omita todos para usar a ordem do arquivo. Raízes não podem ter `sibling_index`. Índices inválidos, ciclos, duplicatas e hierarquia sem os dois stores são erros explícitos.
- `Parent`/`Children` são reconstruídos, nunca gravados como handles brutos. A exportação verifica reciprocidade, gerações e ciclos. O carregamento usa listas dimensionadas em lote e é linear no número de entidades/vínculos; a exportação varre até `highWater` e os vínculos. Não há recursão proporcional à profundidade.
- Componentes genéricos persistíveis têm campos inteiros de até 64 bits, `bool` ou `[]const u8` UTF-8. Há um codec explícito adicional para `LocalTransform3D`, descrito abaixo; outros structs aninhados continuam retornando `UnsupportedComponentType`. `content_format.supportsComponent` consulta apenas o suporte escalar genérico, não os codecs específicos. `name` é lido no descritor, mas não é armazenado no World nem preservado pelo serializer.
- Textos dos componentes carregados **emprestam** memória do `SceneFile`: mantenha-o vivo até deixar de usar esses componentes. Use `content_format.deinit` uma vez após o World. Strings do JSON retornado pelo serializer pertencem ao chamador.
- Em erro, `load` remove as entidades e listas criadas pela chamada e preserva entidades preexistentes. A capacidade, os contadores de geração e a ordem da free-list podem mudar; não é rollback binário completo do World.

Exemplo de ownership (com `Stores` incluindo `hierarchy.Parent` e `hierarchy.Children`):

```zig
var file = try corex_scene.content_format.parse(allocator, bytes);
defer corex_scene.content_format.deinit(allocator, &file);
var world = try World.init(allocator, file.entity_capacity);
defer world.deinit();
defer corex_scene.hierarchy.clear(World, allocator, &world);
try corex_scene.content_loader.load(Stores, &world, &file);
const json = try corex_scene.content_serializer.serialize(Stores, allocator, &world, file.system_capacity);
defer allocator.free(json);
```

`Scene.loadWorld` e `scene.loader.Loader.loadWorld` são APIs legadas ainda não ligadas a esse caminho de conteúdo; não as use como carregadores de conteúdo. O Runtime headless usa `content_loader` em modo somente leitura, com `position`, `velocity`, `age`, hierarquia, `local_transform3d` e `transform_velocity3d` opcionais. O `Position` dos systems de fumaça é independente dos transforms 3D; os detalhes do movimento 3D limitado estão no [README do Runtime](../runtime/README.md#deterministic-headless-execution---frames).

### Codec de transform 3D

Declare `SparseSet(transform3d.LocalTransform3D)` no `Stores`; o `kind` do JSON é o nome desse campo (no Runtime, `local_transform3d`). O codec usa os doze campos escalares `m00`…`m03`, `m10`…`m13`, `m20`…`m23` em ordem de linhas; a última linha é implicitamente `0 0 0 1`. Cada campo é um inteiro **i32 Q16.16 bruto**: `65536` representa `1`, `-65536` representa `-1`. Valores omitidos partem da identidade (diagonal `65536`, demais `0`); floats, números fora de i32, campos desconhecidos e JSON aninhado são rejeitados.

```json
{"entities":[
  {"components":[{"kind":"local_transform3d","m03":65536}]},
  {"parent_index":0,"components":[{"kind":"local_transform3d","m13":131072}]}
]}
```

A Scene serializa os doze campos do transform local em ordem determinística; o formato escalar e o `.proj` não mudaram. Leitores antigos que não conhecem esse tipo de componente não o carregarão. `WorldTransform3D` é calculado, não um componente de entrada do Runtime. `serializeAuthored(Stores, allocator, &world, system_capacity)` omite explicitamente **somente** `WorldTransform3D` e `TransformDirty`; o consumidor precisa recalculá-los. Outros tipos não suportados continuam causando erro. A API original `serialize` mantém seu comportamento: uma instância presente de `WorldTransform3D` é rejeitada como componente aninhado não suportado. O Runtime não grava cenas.

A composição usa produtos Q16.16 arredondados individualmente para o inteiro mais próximo, empates afastados de zero, seguidos de somas da esquerda para a direita. `Mat4.tryMul` e `tryApplyPoint` retornam `TransformOverflow` se qualquer produto ou soma intermediária não couber em i32, mesmo que termos posteriores se cancelassem. `Mat4.mul`, `applyPoint` e `propagateTransforms3D` são APIs legadas sem essa checagem; a última também é best-effort quanto a alocação. Não use essas APIs legadas com valores não confiáveis.

## Transforms dirty

`markDirty(World, &world, entity)` preserva o comportamento original: marca a entidade **e todos os ancestrais**, portanto a subárvore do ancestral mais alto será recalculada. `dirtyCount` inclui essas marcas. A API é `void` e best-effort: uma falha de alocação pode deixar marcas parciais sem aviso. `tryMarkDirtyWithAncestors` oferece a mesma marcação com erro explícito; após erro, corrija a causa e repita a marcação antes de propagar, pois marcas anteriores são mantidas.

Para limitar o trabalho à subárvore alterada, `tryMarkDirty` marca apenas a entidade; seus ancestrais devem ter transforms mundiais válidos. Marcar uma folha assim não recalcula irmãos. `tryPropagateDirty` recalcula em ordem pai→filho mesmo se os índices estiverem invertidos, e mantém o comportamento legado de ignorar nós sem transform local. A variante aditiva `tryPropagateDirtyWithImplicitIdentity` atravessa essas lacunas, copiando o world do pai; sem ancestral transformado ela remove um world obsoleto. Para subárvores, ancestrais externos já devem estar atualizados.

Ambas as variantes `try` detectam `TransformOverflow`. Em caso de erro preservam uma marca para nova tentativa, mas transforms já calculados são provisórios até o sucesso. `propagateDirty` continua `void` e best-effort, sem informar falhas; prefira a versão `try` quando for necessário confirmá-las. Ciclos e handles obsoletos não provocam laços infinitos. Com zero marcas a propagação não aloca; com marcas, o trabalho inclui subárvores afetadas e percursos de ancestrais, sem promessa geral de O(dirty). O chamador deve marcar mudanças de transform **e reparenting**.

Para reutilizar a pilha de travessia entre chamadas, use a variante aditiva com scratch pertencente ao chamador:

```zig
var scratch = corex_scene.transform_dirty.PropagationScratch.init(allocator);
defer scratch.deinit();
try scratch.reserve(world.aliveCount());
try corex_scene.transform_dirty.tryPropagateDirtyWithImplicitIdentityUsingScratch(World, &world, &scratch);
```

A reserva de `aliveCount` cobre a pilha de uma hierarquia válida; **não** reserva os stores de dirty/world, que podem alocar ao inserir componentes. O scratch retém sua capacidade mesmo após erro, pode ser reutilizado para retry e não deve ser compartilhado por chamadas concorrentes. Seu allocator pode ser distinto do allocator do World e deve permanecer válido até `deinit`. O Runtime reserva a capacidade necessária no setup para sua cena de entidades e hierarquia fixas; opcionalmente move transforms locais por tick e propaga as subárvores afetadas.

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

A suíte inclui round-trip de hierarquia, reuso de slots, referências futuras, ordem dos irmãos, ciclos, falhas de alocação/rollback, transforms e detecção de vazamentos, além dos testes de ECS e lifecycle. Rode em Debug e em `-Doptimize=ReleaseSafe`; a raiz também executa a suíte em `zig build test`.
