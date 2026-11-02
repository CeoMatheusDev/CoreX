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

O build importa `../shared`, compila seus módulos C com `-std=c23` e instala `zig-out/bin/CoreXEditor` (Windows: `.exe`) com tabela/manifesto em `zig-out/share/corex/`. Manter essa árvore ao mover a instalação.

## Uso (na raiz do repositório)

```sh
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

O Editor aceita o `.proj` como argumento posicional para futura associação com o SO e rejeita abertura sem projeto. A associação, a splash 800×600 e o Editor gráfico ainda não estão implementados; execução normal falha explicitamente. `src/project_preflight.zig` contém uma tarefa concorrente testada para ler e validar apenas o documento, ainda não ligada ao bootstrap ou à UI. Cena/assets/scripts não são carregados por ela. `src/project_opening.zig` adiciona um coordenador experimental de fases e tickets, também não integrado; os eventos de carga e prontidão dos seus testes são sintéticos, não evidência de carregamento real. Detalhes e dependências em [ADR-004](../docs/ADR-004-project-opening-splash.md).
