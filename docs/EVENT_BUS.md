# Event Bus do core legado

`src/events/event.zig` fornece entrega **síncrona e sequencial** por ID de evento. Não é fila assíncrona, sistema multithread, protocolo de rede ou input por tick; não está ligado ao Editor/Runtime novo.

- `try EventBus.init(allocator, capacidade)` reserva espaço fixo para inscrições. `subscribe` não cresce o buffer: retorna `CapacityExceeded` quando cheio. Capacidade zero é permitida.
- `subscribe(id_evento, callback, contexto)` retorna uma identidade da inscrição, válida apenas naquele bus. O chamador mantém callback e contexto vivos até removê-la ou destruir o bus. Inscrições duplicadas são independentes. IDs não são reutilizados durante a vida do bus; esgotamento retorna erro.
- `publish` chama os inscritos correspondentes pela ordem de inscrição antes de retornar. O próprio dispatch não aloca nem copia o payload; o callback pode fazer isso. Os bytes do evento são emprestados e só têm validade garantida durante `publish`: copie-os antes de guardá-los.
- `unsubscribe` remove uma inscrição e preserva a ordem das restantes; retorna `false` para ID inativo. IDs não são intercambiáveis entre buses ou entre instâncias recriadas. Não copie um bus ativo.
- Durante um callback, `publish`, `subscribe`, `unsubscribe` e `deinit` no mesmo bus retornam `error.Publishing`; não altere os campos diretamente. Não há sincronização: o dono deve serializar todos os acessos. Callbacks são `void`; não há rollback, tratamento de panic ou propagação de erro do callback. Trabalho assíncrono ou que possa falhar exige um contrato externo explícito.
- Após terminar, chame `deinit` uma vez, fora de callback; não use o bus depois de destruí-lo.

Exemplo dentro de `src/`:

```zig
const events = @import("events/event.zig");

fn onEvent(context: *anyopaque, event: events.Event) void {
    const calls: *usize = @ptrCast(@alignCast(context));
    _ = event; // payload só está emprestado durante esta chamada
    calls.* += 1;
}

fn example(allocator: @import("std").mem.Allocator) !void {
    var bus = try events.EventBus.init(allocator, 4);
    defer bus.deinit() catch unreachable;
    var calls: usize = 0;
    const subscription = try bus.subscribe(42, onEvent, &calls);
    try bus.publish(.{ .id = 42, .payload = "mensagem" });
    _ = try bus.unsubscribe(subscription);
}
```

Os testes cobrem ordem, filtragem, inscrições duplicadas, limite, IDs antigos/esgotados, reentrada, falhas de alocação e interação sequencial com a fila de jobs. Não comprovam determinismo de gameplay, publicação paralela, tratamento de eventos de janela nem performance do jogo.
