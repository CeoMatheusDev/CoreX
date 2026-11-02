# Captura de saída da CI

`python tools/ci_capture.py <executável> [argumentos...]` executa o comando sem shell, transmite sua saída imediatamente e retorna seu código. stdout e stderr do filho compartilham um único pipe. Em execução no GitHub Actions (`GITHUB_ACTIONS=true`), uma falha também produz uma annotation com os últimos 16 KiB da saída: bytes UTF-8 inválidos são substituídos e `%`, CR e LF são escapados. Caso a saída não termine em LF, é acrescentada uma quebra de linha antes da annotation para que ela seja reconhecida.

Comando ausente retorna 2; falha ao iniciar retorna 127. Em POSIX, um filho encerrado por sinal `N` resulta no código `128 + N`. Se a saída do capturador falhar, ele tenta encerrar e recolher o filho imediato. O wrapper não impõe timeout próprio nem supervisiona descendentes; o prazo do job é a proteção externa. Ele não é sandbox.

A saída do filho é transmitida sem neutralizar comandos de workflow do GitHub; execute apenas ferramentas confiáveis e não imprima segredos. Não é o logger da aplicação nem um executor de hooks de projetos.

`python tools/test_ci_capture.py` exercita a interface, transmissão, status, limites e annotations. Os testes de streaming e limpeza de processos são específicos de Linux; o teste de sinal é POSIX. Esses testes são um contrato de regressão, não demonstram paridade exaustiva ou execução nativa Windows.

## Protótipo Zig (Linux)

`tools/zig/zig-out/bin/corex-ci-capture <executável> [argumentos...]` é experimental e ainda **não substitui** o wrapper Python na CI. Usa um único pipe para stdout/stderr, o mesmo limite de 16 KiB e a mesma política de annotation nos casos testados. Se um descritor padrão já estiver fechado, falha antes de iniciar o filho. Na falha de saída tenta forçar o encerramento e recolher o filho imediato, inclusive se ele ignorar SIGTERM; isso depende do SO. Não supervisiona descendentes, e a saída bruta continua podendo conter comandos de workflow.

Após `cd tools/zig && zig build`, o contrato comum pode ser exercitado na raiz com `COREX_CAPTURE_BIN="$PWD/tools/zig/zig-out/bin/corex-ci-capture" python tools/test_ci_capture.py`. A CI planejada testa Debug e ReleaseSafe, mas continua usando Python para os outros comandos. A implementação do pipe é Linux; a compilação para Windows produz uma CLI que informa plataforma não suportada. Não há execução nem suporte nativo Windows desta ferramenta nesta etapa.

### Prazo opcional do protótipo

No Linux, `COREX_CI_CAPTURE_TIMEOUT_MS` ativa um prazo, em milissegundos decimais de 1 a 86.400.000. Exemplo: `COREX_CI_CAPTURE_TIMEOUT_MS=60000 tools/zig/zig-out/bin/corex-ci-capture comando`. Sem a variável, não há prazo próprio, como no Python. Valor inválido falha antes de iniciar o comando. Ao esgotar o prazo, o protótipo tenta encerrar e recolher o filho imediato, retorna 124 e, no Actions, emite annotation com o tail. Um comando pode também retornar 124 por conta própria; a mensagem de timeout em stderr distingue os casos.

O prazo é verificado durante a leitura e após EOF enquanto aguarda o filho, inclusive se um descendente mantiver o pipe aberto. Não é uma garantia de tempo real: inicialização, escrita em um consumidor de stdout bloqueado e limpeza dependem do SO e podem ultrapassar o prazo. Descendentes não são encerrados; gerenciá-los exige outro mecanismo. O timeout ainda não é ativado nos jobs da CI, que continuam usando o wrapper Python.
