# Ferramentas Zig

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

**Fase de comparação:** a CI executa os verificadores Python e Zig, além dos testes Zig e do teste diferencial de CLI em diretórios temporários. O script Python permanece por enquanto; não presumir paridade total antes de validar e revisar os resultados. A instalação documentada da toolchain e outras ferramentas/testes da CI ainda usam Python/pip. Um compilador Zig já disponível permite executar esta ferramenta sem Python; isso não elimina as demais dependências do pipeline.

Os testes diferenciais cobrem arquivos ausentes/corrompidos, divergências, versões, backends, hash, interface da CLI e o limite de tamanho. Registram diferenças esperadas: Zig rejeita duplicatas JSON, versões não inteiras ou diferentes de 1/2 e arquivos acima de 4 MiB, enquanto o Python pode aceitá-los. Esses testes não demonstram equivalência para todas as entradas.

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

A verificação de alvos na CI usa apenas esta ferramenta Zig; o script Python correspondente foi removido após o teste em paralelo e a adição de regressões automatizadas. Python/pip permanecem necessários para outras ferramentas, testes e a instalação da toolchain na CI atual. O build dessas ferramentas usa o pacote `shared` e suas fontes C23; não foi introduzida uma nova dependência de janela/GPU ou uma distribuição alternativa de Zig. Windows foi apenas cross-compilado, sem execução nativa desta ferramenta.

## Capturador experimental de CI

`corex-ci-capture` é um protótipo Linux para substituir gradualmente o capturador Python, mas não é usado para executar as etapas da CI. Consulte `tools/CI_CAPTURE.md` para contrato, testes e limitações. Windows ainda não está implementado para este capturador; cross-compilar o stub não é suporte nativo.
