# Ferramentas Zig

## Verificação das fixtures (migração em andamento)

Na raiz do repositório, com **Zig 0.17.0** já instalado:

```sh
zig run tools/zig/check_contract_fixtures.zig
zig test tools/zig/check_contract_fixtures.zig
zig test tools/zig/check_contract_fixtures.zig -O ReleaseSafe
```

Para executar a ferramenta a partir de outro diretório, use um executável compilado com `--root /caminho/para/CoreX`. `--help` mostra a sintaxe. Por padrão, a raiz é o diretório de trabalho atual; os arquivos são lidos em tempo de execução, não embutidos no binário. Cada arquivo tem limite de 4 MiB, e faltas ou violações retornam código não zero.

A ferramenta compara os três exemplos documentados com as fixtures empacotadas, confere versões `.proj` v1/v2, ordem dos backends v2 e SHA-256 dos presets contra o manifesto. Ela não importa os parsers do aplicativo. Essa é uma verificação de **consistência**, não de assinatura, segurança da distribuição, validação completa dos JSON Schemas ou funcionamento GPU. Além das verificações do script Python, rejeita JSON com chaves duplicadas e exige que os números dos schemas sejam 1 e 2.

**Fase de comparação:** a CI executa os verificadores Python e Zig, além dos testes Zig. O script Python permanece por enquanto; não presumir paridade total antes de validar e revisar os resultados. A instalação documentada da toolchain e outras ferramentas/testes da CI ainda usam Python/pip. Um compilador Zig já disponível permite executar esta ferramenta sem Python; isso não elimina as demais dependências do pipeline.

O PR #4, ainda separado, reorganiza o tooling Python; ao integrá-lo, preservar ambas as verificações durante a transição e reconciliar os caminhos e o workflow. Uma futura remoção do verificador Python deve ocorrer após revisão da paridade e integração desse PR, não implicitamente.

## Verificação de alvos das aplicações (migração em andamento)

Com o executável **Zig 0.17.0** em caminho absoluto:

```sh
cd tools/zig
zig build test --summary all
zig build --summary all
./zig-out/bin/corex-check-targets --root ../.. --zig /caminho/absoluto/para/zig
```

No Windows o nome instalado é `corex-check-targets.exe`. A ferramenta verifica a versão exata do compilador e roda os `build check` reais de Editor e Runtime para os três alvos fora do produto. Exige que cada processo termine normalmente com código não zero **e** a mensagem específica de política no stderr; erro de compilação genérico ou saída zero não são considerados sucesso. Não executa nenhum binário cross-compilado.

Ela reutiliza o supervisor de subprocessos de `shared/`, sem shell para os comandos de produto: caminho explícito, captura simultânea limitada a 256 KiB por pipe e prazo de 120 segundos por build (10 segundos para consultar a versão); a limpeza após timeout depende do SO. O supervisor termina e recolhe o **filho imediato**, não garante encerramento de descendentes e não é sandbox; use somente compiladores confiáveis. Os testes Linux do supervisor usam `/bin/sh` para simular falhas e encerramento, não para invocar o Zig no produto.

A CI continua rodando o verificador Python anterior e o Zig em paralelo (shadow); Python/pip permanecem necessários para outros testes e a instalação da toolchain na CI atual. O build dessas ferramentas usa o pacote `shared` e suas fontes C23; não foi introduzida uma nova dependência de janela/GPU ou uma distribuição alternativa de Zig. Windows foi apenas cross-compilado, sem execução nativa desta ferramenta.
