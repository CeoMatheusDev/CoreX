# ADR-007: entidade geracional, sparse set e política de capacidade/memória

- **Status:** aceito; implementado em `scene/`.
- **Data:** 2026-11-03.
- **Substitui:** nada.
- **Relacionado:** [ADR-006](ADR-006-core-library-and-headless-execution.md), [ADR-008](ADR-008-scene-lifecycle-and-runtime-integration.md).

## Contexto

O Runtime já executava um laço headless determinístico, mas não tinha estado de aplicação: não havia entidades, componentes nem systems. O ECS legado em `src/ecs/` pertence à árvore raiz e não é importado pelas aplicações; reutilizá-lo arrastaria a árvore legada e não oferecia geração de handle nem sparse set tipado. A nova base precisava ser um pacote Zig puro, dependente apenas de `core`, sem GPU, janela, threads, assets ou scripting.

## Decisão

### 1. Entity é um handle valor

`Entity = { index: u32, generation: u32 }`, exatamente 8 bytes, nunca um ponteiro. O pool guarda apenas o array de gerações e uma free-list LIFO de índices. Um slot está vivo quando:

- `index < high_water`; e
- a geração é par.

Destruir soma 1 à geração (fica ímpar/morta) e empilha o índice. Reutilizar soma 1 de novo (fica par/viva). Um slot cuja geração alcança `maxInt(u32)` é aposentado e não volta para a free-list. Não existe bitset separado de entidades vivas. Handles antigos falham porque a geração armazenada não coincide mais; handles com índice fora do high-water também falham.

### 2. Component storage é sparse set tipado

Para cada `T`, `SparseSet(T)` mantém:

- `dense_entities[]`: handles na ordem densa;
- `dense[]`: valores contíguos;
- `sparse[]`: `posição_densa + 1` por índice de entidade; zero significa ausente.

`insert/get/remove` são O(1). A remoção faz swap-remove do último elemento para a posição removida e atualiza o sparse do elemento movido. A ordem densa é a ordem de inserção alterada por swap-remove; a mesma sequência de operações produz a mesma ordem. A iteração é contígua e não faz hash lookup.

O `World(Stores)` é genérico sobre um struct de `SparseSet(T)`. O conjunto de tipos de componente é uma propriedade de comptime, resolvida com `inline for` sobre `@typeInfo(Stores).@"struct"`. Não há type erasure, boxing, vtable de componente nem hash map no caminho quente. `add/remove/get/slice/entities` validam o handle no World antes de tocar no storage.

### 3. Capacidade de entidades

A capacidade inicial é escolhida pelo chamador em `World.init(allocator, entity_capacity)`. Quando não há slot livre, o pool cresce por dobra. O novo array de gerações, a free-list e os sparse arrays de todos os componentes são preparados antes de um novo slot ficar visível. OOM é propagado; capacidade já ampliada e componentes existentes permanecem válidos, sem perda de estado. A capacidade zero é aceita e cresce para 4 no primeiro `create`.

### 4. Capacidade de systems

`Systems(WorldT)` recebe a capacidade no `init` e usa um array fixo. Excedente retorna `error.CapacityExceeded`. O conjunto de systems é definido no startup; isso mantém `run` sem alocação e os ponteiros de contexto estáveis. Remoção por deslocamento preserva a ordem e é permitida apenas em setup (`Scene` recusa `addSystem` depois de `start`).

### 5. Ownership e limpeza

`World.init`/`deinit` são explícitos. O World é dono absoluto do pool de entidades, dos sparse arrays e dos arrays densos; a Scene é dona do World e do array de systems. `World.destroy(entity)` remove todos os componentes com `inline for`, sem vtable, e só então invalida o handle. `Scene.deinit()` libera Systems e World. Valores de componentes são copiados por valor; se `T` contiver ponteiros, o recurso apontado continua sendo do chamador, e o World não executa destrutores.

## Complexidade

| Operação | Complexidade | Observação |
| --- | --- | --- |
| `EntityPool.create` | O(1) amortizado | dobra de capacidade; OOM propagado |
| `EntityPool.destroy` | O(1) | invalida geração e empilha índice |
| `SparseSet.insert` | O(1) amortizado | pode crescer o array denso |
| `SparseSet.get` | O(1) | índice sparse + checagem de geração |
| `SparseSet.remove` | O(1) | swap-remove + atualização do sparse |
| Iteração densa | O(n) | memória contígua |
| `World.destroy` | O(k) | k = número de tipos de componente |
| `Systems.run` | O(s) | s = número de systems registrados |
| `Scene.update` | O(s + trabalho dos systems) | sem alocação própria |

## Alternativas rejeitadas

- **Ponteiro de entidade ou ID sem geração:** não detecta handle obsoleto depois do reuso do slot.
- **Bitset de entidades vivas:** adiciona uma segunda fonte de verdade; geração par + high-water já responde.
- **Hash map de componentes:** pior localidade e lookup no caminho quente; o conjunto de tipos é conhecido em comptime.
- **Type erasure com vtable de componente:** boxing e indireção desnecessários; `inline for` resolve o store.
- **Capacidade fixa de entidades:** obrigaria o chamador a superdimensionar ou falhar em runtime; a dobra mantém O(1) amortizado.
- **Systems em lista encadeada alocada por registro:** `run` alocaria ou teria ponteiros instáveis; o array de capacidade fixa é adequado ao startup.

## Consequências

**Positivas**

- Handles obsoletos são detectáveis sem bitset e sem varredura.
- Storage tipado, contíguo e sem hash lookup no caminho quente.
- OOM em crescimento não perde componentes já existentes.
- `run` de systems e `Scene.update` não alocam.
- O conjunto de tipos e systems é explícito no startup, o que facilita auditoria e determinismo.

**Limites**

- Não há remoção de componente durante iteração densa sem cuidado; o contrato é coletar handles e remover fora do laço.
- A ordem densa não é ordem de criação de entidade; é ordem de inserção alterada por swap-remove.
- Componentes com ownership interno exigem que o chamador os remova antes de `World.deinit`; o World não chama destrutores.
- A capacidade de systems é fixa por design; aumentar exige reconstruir a Scene.
- Não há hierarquia, prefabs, serialização, reflection ou query cache nesta fatia.

## Validação

`scene`: **46/46** testes em Debug e ReleaseSafe. `runtime`: **24/24**. Raiz: **107/107** em Debug e ReleaseSafe (46 legado + 11 Core + 46 Scene + 4 adaptadores Zigway). `zig build validate`: **11/11** passos. `tools/zig test-bootstrap-cli`: **37/37** em Debug e ReleaseSafe. `tools/test_bootstrap.py`: **33/33**. Cross-compilação Windows: raiz **7/7** passos, Scene **2/2** e Runtime **4/4**; nenhum executável Windows foi executado.
