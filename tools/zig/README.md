# Ferramentas Zig

## Validação nativa do tooling

Com Zig 0.17.0 disponível, em `tools/zig` execute `zig build validate -j2 --summary all`. O passo roda os testes do tooling e valida fixtures e as seis recusas de alvos com executáveis nativos; não exige a preparação dos pacotes legados. `validate-fixtures` e `validate-targets` podem ser executados individualmente. Os passos de validação rejeitam `-Dtarget` e `-Dcpu` customizados; `zig build check -Dtarget=x86_64-windows-gnu` permanece compilação cruzada sem execução.

Os validadores de fixtures e alvos executam a cada chamada, sem reaproveitar sucesso anterior. Para testar uma cópia das fixtures, use `zig build validate-fixtures -Drepository-root=/caminho/para/CoreX` ou `zig build test-fixture-cli -Drepository-root=/caminho/para/CoreX`; a opção relativa é interpretada a partir de `tools/zig`. `sh tools/test_zig_validate.sh /caminho/absoluto/para/zig`, a partir da raiz, exercita validade, corrupção/restauração e rejeição de target cross tanto para a verificação quanto para os testes black-box.

## Preparação das dependências legadas

`corex-extract-legacy` aceita somente as releases Zigway e ZyntraUI cujos SHA-256 estão fixados no código; verifica os bytes antes de descompactar. Confira limites, regras de extração e dependências em `docs/PYTHON_REMOVAL.md`. Não é um extrator genérico nem protege contra modificação concorrente por quem controla o diretório pai. O passo `zig build install-extractor` instala apenas essa ferramenta; `tools/prepare_legacy_deps.sh` a compila via Zig Build, baixa ou usa arquivos offline e confirma os hashes de pacote com `zig fetch`. A referência Python permanece na CI durante a transição.

## Verificação das fixtures (migração em andamento)

Na raiz do repositório, com **Zig 0.17.0** já instalado:

```sh
zig run tools/zig/check_contract_fixtures.zig
zig test tools/zig/check_contract_fixtures.zig
zig test tools/zig/check_contract_fixtures.zig -O ReleaseSafe

# Compilar as ferramentas e testar a CLI com casos isolados:
(cd tools/zig && zig build)
python tools/test_fixture_checkers.py tools/zig/zig-out/bin/corex-check-fixtures
```

Para executar a ferramenta a partir de outro diretório, use `corex-check-fixtures --root /caminho/para/CoreX` com o executável compilado. `--help` mostra a sintaxe. Por padrão, a raiz é o diretório de trabalho atual; os arquivos são lidos em tempo de execução, não embutidos no binário. Cada arquivo tem limite de 4 MiB, e faltas ou violações retornam código não zero.

A ferramenta compara os três exemplos documentados com as fixtures empacotadas, confere versões `.proj` v1/v2, ordem dos backends v2 e SHA-256 dos presets contra o manifesto. Ela não importa os parsers do aplicativo. Essa é uma verificação de **consistência**, não de assinatura, segurança da distribuição, validação completa dos JSON Schemas ou funcionamento GPU. Além das verificações do script Python, rejeita JSON com chaves duplicadas e exige que os números dos schemas sejam 1 e 2.

**Migração gradual:** o workflow usa a ferramenta Zig para verificar as fixtures reais; o verificador Python permanece como referência no teste diferencial de CLI em diretórios temporários. Não presumir paridade total a partir dos casos cobertos. A instalação Linux do compilador já pode usar shell sem Python; outras ferramentas e testes da CI ainda usam Python. Um compilador Zig já disponível permite executar esta ferramenta sem Python; isso não elimina as demais dependências do pipeline.

A suíte black-box Zig (`zig build test-fixture-cli` em `tools/zig`) compila e executa a CLI real em diretórios isolados contendo cópias das nove fixtures, schemas e manifesto do checkout. Os 11 testes agrupam os casos de arquivos faltantes, pares divergentes, JSON inválido, versões, backends, hash, formato, chaves duplicadas/escapadas, argumentos, privacidade dos diagnósticos e limite de 4 MiB. Usam supervisor com prazo de 20 segundos e captura limitada de stdout/stderr. As cópias temporárias são removidas; os dados reais não são alterados. Os testes também rodam em `zig build test` e `zig build validate`, nos modos escolhidos; o passo dedicado recusa cross-targets. Testes copiam arquivos em tempo de execução e não reutilizam sucesso anterior em cache. Essa cobertura não executa a referência Python nem substitui a comparação diferencial enquanto ela for necessária.

Os testes diferenciais cobrem arquivos ausentes/corrompidos, divergências, versões, backends, hash, interface da CLI e o limite de tamanho. Registram diferenças esperadas: Zig rejeita duplicatas JSON, versões não inteiras ou diferentes de 1/2 e arquivos acima de 4 MiB, enquanto o Python pode aceitá-los. Esses testes não demonstram equivalência para todas as entradas. Nas falhas, a CLI Zig identifica a etapa e os arquivos envolvidos, sem imprimir o conteúdo dos dados de entrada.

O PR #4 foi fechado sem merge; sua reorganização não está na base atual. Uma futura remoção do verificador Python deve ocorrer após revisão da paridade e da cobertura, não implicitamente.

## Verificação de alvos das aplicações (migração em andamento)

Com o executável **Zig 0.17.0** em caminho absoluto:

```sh
cd tools/zig
zig build test --summary all
zig build --summary all
./zig-out/bin/corex-check-targets --root ../.. --zig /caminho/absoluto/para/zig
```

No Windows os executáveis instalados usam sufixo `.exe`. A ferramenta verifica a versão exata do compilador e roda os `build check` reais de Editor e Runtime para os três alvos fora do produto. Exige que cada processo termine normalmente com código não zero **e** a mensagem específica de política no stderr; erro de compilação genérico ou saída zero não são considerados sucesso. Não executa nenhum binário cross-compilado.

Os testes automatizados incluem processos sintéticos no Linux: versão incorreta, argumentos/cwd, seis chamadas esperadas, saída zero com diagnóstico, diagnóstico errado e mensagem apenas em stdout. A execução com o compilador real continua separada.

Ela reutiliza o supervisor de subprocessos de `shared/`, sem shell para os comandos de produto: caminho explícito, captura simultânea limitada a 256 KiB por pipe e prazo de 120 segundos por build (10 segundos para consultar a versão); a limpeza após timeout depende do SO. O supervisor termina e recolhe o **filho imediato**, não garante encerramento de descendentes e não é sandbox; use somente compiladores confiáveis. Os testes Linux do supervisor usam `/bin/sh` para simular falhas e encerramento, não para invocar o Zig no produto.

A verificação de alvos na CI usa apenas esta ferramenta Zig; o script Python correspondente foi removido após o teste em paralelo e a adição de regressões automatizadas. Python permanece necessário para outras ferramentas e testes na CI atual. O build dessas ferramentas usa o pacote `shared` e suas fontes C23; não foi introduzida uma nova dependência de janela/GPU ou uma distribuição alternativa de Zig. Windows foi apenas cross-compilado, sem execução nativa desta ferramenta.

## Capturador de CI (Linux)

`corex-ci-capture` é uma implementação Linux usada pelo workflow de contratos nesta alteração para substituir gradualmente o capturador Python. O workflow alterado ainda precisa de validação remota. Consulte `tools/CI_CAPTURE.md` para contrato, testes e limitações. Windows ainda não está implementado para este capturador; cross-compilar o stub não é suporte nativo.

`zig build test-capture-cli` compila o capturador e executa nove testes black-box nativos Linux, sem Python; também fazem parte de `zig build test` e `zig build validate` e são executados novamente em cada invocação. O passo dedicado rejeita cross-targets e hosts não Linux; `check` apenas compila os testes em cross. Usam `/bin/sh`, `/bin/sleep` e `/proc` Linux para os probes e verificação de cleanup. A suíte cobre somente parte dos casos da referência Python, que continua obrigatória na CI durante a transição.
