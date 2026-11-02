> **Perfil de produto:** Windows/Linux, 3D e UI/Canvas, sem cena 2D. APIs previstas: Vulkan/OpenGL; D3D11/D3D12 somente Windows. Elegibilidade não comprova renderer implementado. ADR-003 detalha a política.

# CoreXEditor — bootstrap de validação

Executável independente em Zig **0.17.0** + C23. **Ainda não é o Editor gráfico.** Nesta fatia não liga core, Zigway ou ZyntraUI; não introduz outra stack de janela/UI. Essas integrações continuam pendentes.

## Build

```sh
cd editor
zig build
zig build test
```

Os testes de abertura copiam `../exemploproject/Example.proj` em diretório temporário e compilam o Editor real. Para usar outra árvore de exemplos, passe `-Drepository-root=/caminho/para/CoreX` a `zig build test`. O teste não reutiliza resultado antigo quando o exemplo muda; `zig build check` apenas compila, inclusive em cross.

O build importa `../shared`, compila seus módulos C com `-std=c23` e instala `zig-out/bin/CoreXEditor` (Windows: `.exe`) com tabela/manifesto em `zig-out/share/corex/`. O manifesto e a identidade embutida no binário são gerados a partir de `VERSION`; manter essa árvore ao mover a instalação.

## Uso (na raiz do repositório)

```sh
editor/zig-out/bin/CoreXEditor --version
editor/zig-out/bin/CoreXEditor --project docs/examples/EmptyGame.proj --headless --validate-only
editor/zig-out/bin/CoreXEditor exemploproject/Example.proj --headless --validate-only
```

Validar também com um Runtime separado, previamente compilado:

```sh
editor/zig-out/bin/CoreXEditor --project docs/examples/EmptyGame.proj --validate-only \
  --check-runtime /caminho/absoluto/CoreX/runtime/zig-out/bin/CoreXRuntime
```

Essa opção executa o binário indicado: use apenas executável confiável. Não é Play; o filho também usa `--headless --validate-only`. O Editor captura os dois pipes, valida o protocolo e exige fingerprint igual da configuração inteira. Deadline de 10 segundos, limites de captura e reap do filho imediato. Não supervisiona árvores de processos nem o fechamento abrupto do Editor.

Stdout/stderr contêm JSON lines. O `.proj` é somente lido nesta fase. Não há UI, viewport, inspetor, edição/salvamento de cena, backup/replace atômico ou snapshots ZyntraUI. Solicitar execução normal sem `--validate-only` falha explicitamente (exit 4), inclusive com `--headless`.

Contrato completo, códigos de saída e limites: [APPLICATION_CLI.md](../docs/APPLICATION_CLI.md). Testes entre executáveis: `python tools/test_bootstrap.py` a partir da raiz após compilar **ambos** os pacotes. O build legado da raiz é separado e ainda tem pendências de dependências.

`src/workspace.zig` implementa o modelo sem alocação de domínio/ferramenta: transformações 3D ou layout de Canvas. Trocar domínio reinicia ferramenta; operação incompatível retorna erro sem mutação. Ainda não está ligado a painéis ZyntraUI nem altera cenas reais.

O Editor aceita o `.proj` como argumento posicional para futura associação com o SO e rejeita abertura sem projeto. A associação, a splash 800×600 e o Editor gráfico ainda não estão implementados; execução normal falha explicitamente. `src/project_preflight.zig` contém uma tarefa concorrente testada para ler e validar apenas o documento, ainda não ligada ao bootstrap ou à UI. `src/resource_discovery.zig` acrescenta descoberta real das quatro raízes obrigatórias, verificando existência, tipo e contenção após resolução de symlinks. Também indexa metadata ordenada e limitada dos arquivos regulares e subdiretórios em `assets.root` (sem ler ou carregar conteúdo, fora dos tickets de progresso), percorre a árvore com handles sem seguir symlinks, recusa links de arquivo/diretório e checa containment/tipo de arquivos-alvo já existentes; arquivos ausentes continuam tickets lógicos até haver loaders. `src/project_opening.zig` liga a descoberta concorrente ao coordenador por `Opening.startDiscovery()`/`pollDiscovery()`; o snapshot expõe o estágio de descoberta, e `Opening.assetInventory()`/`assetDirectoryInventory()` fornecem views somente leitura; `Opening.assetChildren()` itera filhos imediatos em ordem sem alocar; `Discovery.findAsset()`/`findAssetDirectory()` fazem lookup exato, e `Opening.verifyAssetSnapshot()`/`verifyAssetDirectorySnapshot()` verificam invalidação observável; isso não substitui validação segura do futuro loader. A descoberta não lê, decodifica nem executa conteúdo; `Opening.openAsset()` abre um asset indexado e `Opening.openResourceFile()` abre cena/script/biblioteca existente read-only por handles sem seguir symlinks, e `Opening.readAssetAlloc()`/`readResourceAlloc()` copiam bytes opacos sob limite explícito do chamador, sem interpretação do formato; `resource_discovery.AssetReadTask` executa a leitura em worker; `Opening.startAssetRead()`/`takeAssetRead()` integram um trabalho por vez, publicam estágio/erro coletado e o recolhem antes de liberar o inventário (uso direto exige Discovery e allocator thread-safe vivos). Os testes de conclusão dos tickets e de prontidão continuam sintéticos; não são evidência de loader de cena/assets, UI ou serviços reais. A integração de abertura continua fora do bootstrap e da UI. Detalhes e pendências em [ADR-004](../docs/ADR-004-project-opening-splash.md).
