# Captura de saída da CI

O capturador `corex-ci-capture <executável> [argumentos...]`, adotado pelo workflow Linux nesta alteração, e a referência `python tools/ci_capture.py <executável> [argumentos...]` executam o comando sem shell, transmitem sua saída imediatamente e retornam seu código. stdout e stderr do filho compartilham um único pipe. Em execução no GitHub Actions (`GITHUB_ACTIONS=true`), uma falha também produz uma annotation com os últimos 16 KiB da saída: bytes UTF-8 inválidos são substituídos e `%`, CR e LF são escapados. Caso a saída não termine em LF, é acrescentada uma quebra de linha antes da annotation para que ela seja reconhecida.

Comando ausente retorna 2; falha ao iniciar retorna 127. Em POSIX, um filho encerrado por sinal `N` resulta no código `128 + N`. Se a saída do capturador falhar, ele tenta encerrar e recolher o filho imediato. O wrapper Python não impõe timeout próprio; no Zig, ele é opcional e desativado por padrão. Nenhum dos dois supervisiona descendentes; o prazo do job é a proteção externa. Ele não é sandbox.

A saída do filho é transmitida sem neutralizar comandos de workflow do GitHub; execute apenas ferramentas confiáveis e não imprima segredos. Não é o logger da aplicação nem um executor de hooks de projetos.

`python tools/test_ci_capture.py` exercita a interface, transmissão, status, limites e annotations. Os testes de streaming e limpeza de processos são específicos de Linux; o teste de sinal é POSIX. Esses testes são um contrato de regressão, não demonstram paridade exaustiva ou execução nativa Windows.

## Capturador Zig (Linux)

`tools/zig/zig-out/bin/corex-ci-capture <executável> [argumentos...]` é a implementação Linux adotada no workflow de contratos nesta alteração; a validação remota dela ainda está pendente. Usa um único pipe para stdout/stderr, o mesmo limite de 16 KiB e a mesma política de annotation nos casos testados. Se um descritor padrão já estiver fechado, falha antes de iniciar o filho. Na falha de saída tenta forçar o encerramento e recolher o filho imediato, inclusive se ele ignorar SIGTERM; isso depende do SO. Não supervisiona descendentes, e a saída bruta continua podendo conter comandos de workflow.

Após `cd tools/zig && zig build`, o contrato comum pode ser exercitado na raiz com `COREX_CAPTURE_BIN="$PWD/tools/zig/zig-out/bin/corex-ci-capture" python tools/test_ci_capture.py`. O workflow alterado testa Debug e ReleaseSafe usando a suíte Python existente e `sh tools/test_ci_capture_smoke.sh /caminho/absoluto/corex-ci-capture` sem Python. Ele usa o binário Debug para capturar as etapas posteriores, mas ainda usa Python em outros testes. A CI remota desta alteração ainda não foi executada. A implementação do pipe é Linux; a compilação para Windows produz uma CLI que informa plataforma não suportada. Não há execução nem suporte nativo Windows desta ferramenta nesta etapa.

### Testes black-box Zig

Em Linux, `cd tools/zig && zig build test-capture-cli --summary all` compila e testa a CLI real com onze testes black-box, em Debug por padrão ou `-Doptimize=ReleaseSafe`. Eles também rodam em `zig build test` e na validação nativa (`tools/zig` e raiz), sem Python e com resultados não cacheados. Exercitam status e sinais, output binário, annotations, PATH/argumentos, tail, UTF-8, timeout inválido antes do spawn, encerramento/recolhimento do filho imediato, streaming antes do fim do filho e carga intercalada de 2 MiB com tail limitado. Usam `/bin/sh`, `/bin/sleep` e `/proc` para probes Linux, com prazo externo limitado. O passo dedicado recusa cross e hosts não Linux; `check` compila sem executar.

A cobertura ainda é parcial: stdout bloqueado/pressão, pipe quebrado, flags dos descritores e descendentes mantendo o pipe continuam na suíte Python. Não removê-la com base nestes testes.

### Prazo opcional do capturador Zig

No Linux, `COREX_CI_CAPTURE_TIMEOUT_MS` ativa um prazo, em milissegundos decimais de 1 a 86.400.000. Exemplo: `COREX_CI_CAPTURE_TIMEOUT_MS=60000 tools/zig/zig-out/bin/corex-ci-capture comando`. Sem a variável, não há prazo próprio, como no Python. Valor inválido falha antes de iniciar o comando. Ao esgotar o prazo, o capturador Zig tenta encerrar e recolher o filho imediato, retorna 124 e, no Actions, tenta emitir uma annotation com o tail. Um comando pode também retornar 124 por conta própria; a mensagem de timeout em stderr distingue os casos.

O prazo é verificado durante a leitura, a espera de disponibilidade do stdout e após EOF enquanto aguarda o filho, inclusive se um descendente mantiver o pipe aberto. Com prazo configurado, emite saída em blocos de até 4 KiB após `poll`, sem alterar `O_NONBLOCK` no descritor compartilhado. Após timeout, a annotation recebe uma janela adicional de até 100 ms; se a saída continuar bloqueada, a annotation pode ficar incompleta ou ausente e o problema é informado em stderr. Se o prazo expirar ao emitir a annotation após o filho já ter terminado, o wrapper também retorna 124.

Não é uma garantia de tempo real: spawn, gravação após `poll` em alguns tipos de descritor ou com outros escritores concorrentes, stderr bloqueado e limpeza dependem do SO e podem ultrapassar o prazo. Descendentes não são encerrados; gerenciá-los exige outro mecanismo. Sem prazo configurado, o stdout continua usando escritas bloqueantes. O timeout próprio ainda não é ativado nos jobs da CI.
