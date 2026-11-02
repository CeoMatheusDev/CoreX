> **Perfil de produto:** Windows/Linux, 3D e UI/Canvas, sem cena 2D. APIs previstas: Vulkan/OpenGL; D3D11/D3D12 somente Windows. Elegibilidade não comprova renderer implementado. ADR-003 detalha a política.

# CoreXRuntime — bootstrap de validação

Executável independente em Zig **0.17.0** + C23. **Ainda não executa jogos.** Não liga o core nem cria janela/device; Zigway continua sendo a stack obrigatória quando a integração gráfica for implementada.

## Build

```sh
cd runtime
zig build
zig build test
```

Importa `../shared`, compila C com `-std=c23` e instala `zig-out/bin/CoreXRuntime` (Windows: `.exe`) com `zig-out/share/corex/{distribution.json,presets.zon}`. Instalação incompleta/corrompida é erro, sem fallback em CWD/projeto.

## Uso (na raiz do repositório)

```sh
runtime/zig-out/bin/CoreXRuntime --project docs/examples/EmptyGame.proj --headless --validate-only
```

Esse comando lê o schema compartilhado, confere a identidade da distribuição, resolve o preset/overrides, valida o DTO C23 e emite logs JSON lines com os parâmetros concretos. Emite `runtime.validation_complete`, **nunca `runtime.ready`**. O modo não carrega cena/assets/scripts, negocia ABI do core, consulta GPU ou simula ticks. O sucesso vale apenas para documento/presets.

Sem `--validate-only`, inclusive com `--headless`, retorna erro de core indisponível (exit 4). Isso evita que uma simulação vazia seja apresentada como Player funcional. C++/Lua, loop fixed timestep, job system, hot reload e UI de jogo continuam pendentes; nenhuma UI de Editor é incorporada.

O Runtime nunca grava `.proj`. Códigos de saída, opções e protocolo: [APPLICATION_CLI.md](../docs/APPLICATION_CLI.md). Testes reais Editor→Runtime: `tools/.venv/bin/python tools/python/test_bootstrap.py` na raiz após compilar ambos. Testes nativos Windows ainda não estão disponíveis; cross-compilação não substitui execução nativa.

## Modelo de contabilidade de tempo (ainda não integrado)

`src/timing.zig` oferece um acumulador inteiro, sem alocação ou relógio próprio. Usa a frequência explícita de 1–1000 Hz do schema e contabiliza `elapsed_ns * Hz` em unidades de fase; 1 bilhão de unidades corresponde a um tick. Isso preserva a razão `1 / Hz`, inclusive em frequências que não dividem um segundo inteiro em nanossegundos. O projeto ainda não passa a configuração a esse modelo em execução.

- `addElapsed` recebe um delta monotônico não negativo calculado pelo futuro loop. Overflows são erros sem alterar o estado.
- `pending(budget)` informa quantos ticks inteiros estão disponíveis, até o limite da iteração. É uma consulta, não uma reserva: o chamador deve aplicar o budget uma vez por iteração.
- `nextTick` informa o índice (base zero) do próximo tick ou `null` quando não há tick devido. Retorna erro se o contador estiver esgotado, antes de qualquer trabalho. Quem usa `commitTick` manualmente deve verificar `nextTick` antes de executar o tick e confirmar **somente depois** de concluí-lo com sucesso.
- `runDue` oferece uma alternativa que recebe um callback explícito, verifica o contador antes de cada chamada e confirma apenas as chamadas bem-sucedidas, até o budget. Se uma chamada falhar, os ticks anteriores continuam confirmados e o tick falho permanece pendente. Mutação do agendador e execução recursiva pelos métodos são recusadas durante o callback. O callback não deve alterar diretamente os campos do agendador nem acessá-lo concorrentemente. Não há rollback de efeitos do callback: o chamador deve garantir transação ou interromper a sessão após falha, em vez de repetir cegamente.
- `interpolationAlpha` retorna `null` enquanto há ticks atrasados; quando não há, retorna a fração entre 0 (inclusive) e 1 (exclusive). Nenhum estado anterior/atual é mantido aqui.

Sem descarte automático de backlog. Pausa/retomada, relógio e tratamento de deltas, política de recuperação de falhas, medição/log de atraso, input ordenado por tick, jobs, replay e integração ao core ainda precisam ser definidos e testados no Runtime real. Esses testes aritméticos não demonstram determinismo de gameplay nem autorizam emitir `runtime.ready`.

## Buffer isolado de input por tick

`src/tick_input.zig` contém `Buffer(T)`, infraestrutura genérica para o futuro loop; **não** é adaptador Zigway nem formato persistente de replay. Usa armazenamento exclusivo fornecido pelo chamador, sem alocação própria. Valores são copiados superficialmente: o chamador é responsável pela validade de quaisquer referências em `T`; ponteiros/handles não constituem registro determinístico persistente.

`enqueue` e `enqueueBatch` aceitam entradas em ordem não decrescente de tick, preservando a ordem original dentro de cada tick. O lote é integralmente validado antes de copiar: capacidade insuficiente, tick passado, fora de ordem ou sem possibilidade de confirmação causa erro **sem inserção parcial**. A entrada do lote não pode compartilhar o armazenamento do buffer; a capacidade é verificada antes dos valores. Tick `maxInt(u64)` é recusado, pois o contador não pode avançar após ele.

`beginTick` só abre o próximo tick, inclusive vazio, e verifica overflow antes do trabalho. A fatia emprestada é válida até `commitTick` ou `abortTick`; não altere o armazenamento diretamente. `commitTick` remove o lote e avança; `abortTick` o mantém. O buffer não é thread-safe. Sua compactação custa O(backlog); o chamador define capacidade e tratamento de backpressure.

Um teste combina o buffer com `Scheduler.runDue` e falha simulada antes de efeitos externos. Na integração futura, a confirmação do buffer deve ser a **última operação infalível do callback**: falhas posteriores poderiam avançá-lo sem confirmar o scheduler. Abort não reverte efeitos de gameplay; retry só é seguro com transação ou ausência de efeitos parciais. Atribuição de eventos Zigway a ticks, serialização, replay, relógio e gameplay continuam pendentes.

**Bloqueio observado no Zigway v0.1.0-alpha.4 fixado:** no backend null com capacidade 1, `key_down` seguido de `key_up` substitui o primeiro evento, mas `droppedEvents()` permanece zero. Esse contador não detecta todas as perdas; não se deve usá-lo para garantir captura sem perdas. O teste reproduzível está em `src/zigway_input_tests.zig` no build legado. Não testa janela nativa nem corrige o Zigway upstream.
