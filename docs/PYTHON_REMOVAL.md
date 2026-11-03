# Migração para uma cadeia de desenvolvimento sem Python

Objetivo: Python não ser ferramenta exigida pelo CoreX para preparar, compilar, testar ou validar o projeto. Isso não é uma garantia sobre implementações internas de actions ou componentes do sistema operacional. A migração está **em andamento**; remover um script ou desligar um teste antes de existir cobertura equivalente não satisfaz esse objetivo.

## Inventário atual

| Uso | Arquivos atuais | Migração necessária |
| --- | --- | --- |
| Toolchain | `tools/install_zig.sh`; `tools/zig-requirements.txt` mantido como fallback transitório | O instalador Linux usa sem Python as mesmas wheels fixadas por SHA-256 que a CI anterior usava com pip. A CI do PR #8 e a do merge em main passaram em Linux x86_64; falta validar uma distribuição Windows nativa de Zig 0.17.0; a disponibilidade na action `mlugg/setup-zig` não foi confirmada. |
| Dependências legadas | `tools/prepare_legacy_deps.sh`, `tools/zig/extract_legacy_deps.zig`; `tools/prepare_legacy_deps.py`, `tools/test_prepare_legacy_deps.py` mantidos em paralelo | A alternativa shell/Zig verifica SHA-256, limites, paths, tipos e hash Zig, com modo offline e testes adversariais. As CIs do PR #8 e do merge em main passaram; a referência Python permanece como comparação durante a transição. |
| Fixtures | `tools/zig/test_fixture_cli.zig`, `tools/check_contract_fixtures.py`, `tools/test_fixture_checkers.py` | A CLI principal e seus testes black-box já têm implementação Zig; a comparação diferencial com Python permanece para preservar as diferenças intencionais durante a transição. |
| Captura de CI | `tools/zig/ci_capture.zig`, `tools/zig/test_capture_cli.zig`, `tools/test_ci_capture_smoke.sh`, `tools/ci_capture.py`, `tools/test_ci_capture.py` | O workflow Linux nesta alteração usa o capturador Zig e o testa em Debug e ReleaseSafe, inclusive onze testes black-box Zig e smoke sem Python; a referência e os testes Python permanecem, pois a cobertura Zig ainda é parcial. Esta alteração ainda precisa de CI remota. A implementação é Linux-only; não declarar suporte nativo Windows. |
| Integração real | `tools/test_bootstrap.py`, `tools/zig/test_bootstrap_cli.zig`, `tools/zig/bootstrap_probe.zig` | O port Zig já executa os 33 casos de processo e probe com JSONL, identidade de produto, compatibilidade/fingerprint, protocolos, limites, timeouts e cleanup (`zig build test-bootstrap-cli`, POSIX). Sondas Python com shebang foram substituídas por um executável de teste Zig; a referência Python permanece até a CI remota aprovar o port e resolver as diferenças listadas abaixo. Não substituir por testes unitários. |
| YAML de workflow | `yamllint` fornecido pelo runner | Substituir ou retirar a ferramenta explicitamente usada após manter uma verificação adequada; validação sintática não valida a semântica do Actions. |

`tools/python-migration-allowlist.txt` lista os arquivos Python rastreados permitidos durante a transição. `sh tools/check_python_inventory.sh` falha se um arquivo `.py`/`.pyw` rastreado surgir ou se a lista ficar desatualizada; `sh tools/test_python_inventory.sh` testa esse guard em um índice Git isolado. Arquivos ainda não adicionados ao Git não são observados. Ao concluir a migração, a lista deve ficar vazia e o guard deve impedir qualquer novo arquivo Python rastreado.

## Instalação Linux sem Python

Em Linux x86_64/aarch64, `sh tools/install_zig.sh /caminho/absoluto/novo` baixa a wheel `ziglang` 0.17.0 fixada pelo mesmo SHA-256 anteriormente usado pelo pip e instala o executável, a biblioteca Zig e a licença, sem invocar Python. O diretório pai deve existir e o destino não pode existir. Para uso offline, passe a wheel local como segundo argumento; o hash e limite de tamanho também são exigidos. O download usa HTTPS; a extração ocorre **somente após** verificação dos bytes fixados, não se trata de extrator genérico seguro para arquivos arbitrários. A biblioteca Zig upstream inclui um helper Python opcional de LLDB, que não é executado pelo build. Requer `curl` (exceto offline), `unzip`, `sha256sum` e utilitários POSIX. Os testes negativos são `sh tools/test_install_zig.sh`; com uma wheel fixada como argumento, testam também instalação offline real.

O instalador foi testado localmente em Linux x86_64, inclusive download sem Python, caminhos com espaços/acentos e validação Zig com PATH vazio. O pin aarch64 é o mesmo já usado na CI anterior, mas não foi exercitado nativamente nesta sessão. Não há binário Windows incluído nem suporte Windows nativo comprovado. As CIs do PR #8 e do merge em main passaram; alterações posteriores nesta branch ainda precisam de CI remota.

## Entrada Zig disponível agora

Com Zig 0.17.0 disponível, prepare primeiro as dependências legadas e execute as validações:

```sh
sh tools/prepare_legacy_deps.sh --zig /caminho/absoluto/para/zig
zig build validate -j2 --summary all
zig build test --summary all
zig build check -Dtarget=x86_64-windows-gnu -j2 --summary all
```

A implementação foi exercitada nativamente em Linux; Windows aqui foi apenas compilado em cross e não há garantia de execução nativa. `validate` é nativo: executa os testes de tooling, Shared, Editor e Runtime, verifica fixtures e recusas reais de alvos, confere formatação e compila separadamente os dois headers privados como C++20 com warnings rigorosos. Ele **não é a CI inteira**: ainda não executa os testes legados de `zig build test` nem os testes Python de integração, arquivos e captura. `-Doptimize=ReleaseSafe` seleciona esse modo. Uma configuração customizada de alvo ou CPU é rejeitada para impedir que validação host seja confundida com execução cross.

O `zig build check` já existente continua compilando o executável e testes legados **sem execução**, inclusive em cross. Mudá-lo para executar código quebraria o contrato usado pela CI. O pacote independente `tools/zig` oferece `zig build validate`, `validate-fixtures`, `validate-targets`, `test-fixture-cli`, `test-capture-cli` (Linux) e o seu próprio `check` somente de compilação. Seus testes black-box de CLI copiam as fixtures reais para um diretório temporário isolado e exigem esses arquivos de `docs/` e `shared/` no checkout. As verificações de fixtures e alvos sempre executam, evitando reutilizar um sucesso em cache após mudança de arquivos. Para testar fixtures em outra árvore, `zig build validate-fixtures` e `zig build test-fixture-cli` aceitam `-Drepository-root=/caminho/absoluto`; caminhos relativos são interpretados a partir de `tools/zig`.

A validação do pacote `tools/zig` não precisa das dependências legadas. Na raiz, o preparador shell/Zig precisa de `curl` quando online e de utilitários POSIX; opcionalmente aceita `--archive-dir /caminho` com os arquivos `zigway.tar.gz` e `zyntra_ui.tar.gz`. Uma cópia limpa em Linux x86_64, com caches Zig novos, executou o download e a preparação com PATH contendo apenas utilitários necessários e depois `zig build validate` com PATH vazio. Isso não cobre toda a CI. Os 33 testes de integração também existem agora em `tools/zig/test_bootstrap_cli.zig`; eles exigem os dois bootstraps compilados antes, não fazem parte de `tools/zig validate` e continuam em paralelo aos testes Python até a validação remota. Os testes de subprocessos usam `/bin/sh`, a compilação dos headers usa recursos C e o core legado precisa de bibliotecas de sistema. Os workflows ainda mantêm `actions/setup-python`, referência de preparação, testes e ferramentas Python. O PR #8 e seu merge em main passaram na CI remota; as alterações posteriores nesta branch ainda precisam dessa validação.

O extrator aceita somente os dois arquivos com SHA-256 fixado, verifica antes de descompactar, limita arquivos comprimidos a 16 MiB, dados tar descomprimidos a 80 MiB, soma dos membros a 64 MiB e número de entradas a 100.000. Verifica CRC/tamanho gzip, paths relativos dentro do prefixo esperado e rejeita links/tipos especiais e usa criação exclusiva. O preparador invoca o extrator dentro de um diretório temporário privado. O limite tar, alguns paths e gzip concatenado são mais estritos que o preparador Python. Não é um extrator genérico para dados arbitrários e pressupõe que o diretório pai do destino seja confiável. `sh tools/test_prepare_legacy_deps.sh /caminho/absoluto/zig [diretório-de-arquivos]` testa falhas, hashes Zig e limpeza além dos testes unitários Zig.

## Diferenças conhecidas do port Zig de integração

`tools/zig/test_bootstrap_cli.zig` reproduz os 33 casos de `tools/test_bootstrap.py` com processos reais, mas não é uma tradução linha a linha:

- As sondas que o Python criava com shebang são um executável Zig de teste (`bootstrap_probe.zig`). O Editor só aceita um executável absoluto explícito e não repassa argumentos extras, então o modo da sonda vem de um arquivo `<projeto>.probe` e o PID fica em `<projeto>.pid` para provar que o filho foi encerrado e colhido.
- O caso de orçamento de diagnóstico espera cerca de 2,4 MiB de saída do Editor. O supervisor de produto limita cada pipe a 256 KiB, e a captura do Python não tinha limite; o teste usa um coletor próprio com limite maior apenas nesse caso.
- O caso de pipe de saída fechado abre o Runtime diretamente, sem o supervisor compartilhado, para poder fechar a leitura antes da primeira escrita.
- O port é POSIX: `zig build check` compila os testes para alvos cruzados, mas não os executa, e execução nativa em Windows não foi verificada. O teste de symlink com nome não UTF-8 continua específico de Linux, como no Python.

## Critérios antes de concluir

1. CI Linux e Windows nativo com distribuição Zig 0.17.0 identificada, verificável e compatível; cross-compilação isoladamente não comprova execução Windows.
2. Substituir cada item do inventário preservando falhas, limites, segurança de arquivos e cobertura de integração; manter comparação durante a transição.
3. Executar os workflows completos sem `python`, `pip`, venv, requirements ou ferramentas Python explicitamente invocadas; documentar ferramentas externas de sistema ainda necessárias.
4. Remover arquivos Python e requirements somente após cobertura equivalente e CI remota aprovada. Esvaziar a allowlist e manter o guard para evitar reintrodução acidental.

## Revisão do main e da CI

O PR [#8](https://github.com/CeoMatheusDev/CoreX/pull/8) foi integrado e seus dois checks passaram. No merge `fd201fa4bc33f7f3c86f90b9387ec019befb56f7`, passaram as CIs de [contratos](https://github.com/CeoMatheusDev/CoreX/actions/runs/41388162671) e [legado](https://github.com/CeoMatheusDev/CoreX/actions/runs/41388162668). Ambas registraram aviso de depreciação de Node 20 para `actions/checkout` e `actions/setup-python`. Nesta alteração, elas foram atualizadas para v6 com SHA completo, verificadas como ações Node 24; checkout não persiste credenciais. Node 24 requer runner Actions 2.327.1 ou posterior. A nova configuração ainda não foi validada remotamente.
