> **Perfil de produto:** Windows/Linux, 3D e UI/Canvas, sem cena 2D. APIs previstas: Vulkan/OpenGL; D3D11/D3D12 somente Windows. Elegibilidade não comprova renderer implementado. ADR-003 detalha a política.

# CoreXEditor — bootstrap de validação

Executável independente em Zig **0.17.0** + C23. **Ainda não é o Editor gráfico.** Nesta fatia não liga core, Zigway ou ZyntraUI; não introduz outra stack de janela/UI. Essas integrações continuam pendentes.

## Build

```sh
cd editor
zig build
zig build test
```

O build importa `../shared`, compila seus módulos C com `-std=c23` e instala `zig-out/bin/CoreXEditor` (Windows: `.exe`) com tabela/manifesto em `zig-out/share/corex/`. Manter essa árvore ao mover a instalação.

## Uso (na raiz do repositório)

```sh
editor/zig-out/bin/CoreXEditor --project docs/examples/EmptyGame.proj --headless --validate-only
```

Validar também com um Runtime separado, previamente compilado:

```sh
editor/zig-out/bin/CoreXEditor --project docs/examples/EmptyGame.proj --validate-only \
  --check-runtime /caminho/absoluto/CoreX/runtime/zig-out/bin/CoreXRuntime
```

Essa opção executa o binário indicado: use apenas executável confiável. Não é Play; o filho também usa `--headless --validate-only`. O Editor captura os dois pipes, valida o protocolo e exige fingerprint igual da configuração inteira. Deadline de 10 segundos, limites de captura e reap do filho imediato. Não supervisiona árvores de processos nem o fechamento abrupto do Editor.

Stdout/stderr contêm JSON lines. O `.proj` é somente lido nesta fase. Não há UI, viewport, inspetor, edição/salvamento de cena, backup/replace atômico ou snapshots ZyntraUI. Solicitar execução normal sem `--validate-only` falha explicitamente (exit 4), inclusive com `--headless`.

Contrato completo, códigos de saída e limites: [APPLICATION_CLI.md](../docs/APPLICATION_CLI.md). Testes entre executáveis: `tools/.venv/bin/python tools/python/test_bootstrap.py` a partir da raiz após compilar **ambos** os pacotes. O build legado da raiz é separado e ainda tem pendências de dependências.

`src/workspace.zig` implementa o modelo sem alocação de domínio/ferramenta: transformações 3D ou layout de Canvas. Trocar domínio reinicia ferramenta; operação incompatível retorna erro sem mutação. Ainda não está ligado a painéis ZyntraUI nem altera cenas reais.
