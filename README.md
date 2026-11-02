# CoreX Engine

<p align="center"><strong>Uma engine desktop 3D e UI/Canvas, construída em Zig.</strong><br />Controle explícito de memória, contratos verificáveis e arquitetura modular.</p>

<p align="center">
<a href="https://github.com/CeoMatheusDev/CoreX/actions/workflows/shared-contracts.yml"><img src="https://github.com/CeoMatheusDev/CoreX/actions/workflows/shared-contracts.yml/badge.svg?branch=main" alt="Shared contracts CI" /></a>
<a href="https://github.com/CeoMatheusDev/CoreX/actions/workflows/legacy-core.yml"><img src="https://github.com/CeoMatheusDev/CoreX/actions/workflows/legacy-core.yml/badge.svg?branch=main" alt="Legacy core CI" /></a>
<img src="https://img.shields.io/badge/language-Zig-F7A41D?logo=zig&logoColor=white" alt="Zig" />
<img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-555" alt="Windows and Linux" />
<img src="https://img.shields.io/badge/status-early%20development-orange" alt="Early development" />
</p>

> **Estado do produto:** desenvolvimento inicial. O repositório contém contratos de projeto, presets, bootstraps de validação e componentes legados de demonstração. **Ainda não oferece um Editor gráfico, um Runtime de jogos ou renderização GPU funcional.** Consulte [o estado de implementação](docs/APPLICATION_PROGRESS.md) antes de assumir que um subsistema está pronto.

## Visão geral

CoreX é um projeto de engine desktop cujo escopo atual é:

- **Plataformas:** Windows e Linux.
- **Autoria:** cenas 3D e UI/Canvas. Não há modo de cena/gameplay 2D.
- **APIs gráficas planejadas:** Vulkan e OpenGL em Windows/Linux; Direct3D 11 e 12 somente em Windows.
- **Linguagem principal:** Zig 0.17.0; C23 é usado em uma pequena fronteira nativa de interoperabilidade.
- **Princípios:** ownership explícito, alocação previsível, interfaces pequenas, validação estrita e testes reproduzíveis.

A elegibilidade de uma API na matriz de produto não significa que seu renderer esteja implementado. No estado atual, o renderer legado usa NullBackend; nenhum backend GPU está integrado.

## Estado atual

| Área | Situação |
| --- | --- |
| Contratos .proj v1/v2 | Implementados; parsing e validação |
| Presets gráficos v1 | Parsing, validação e resolução dos 27 parâmetros |
| DTO Zig/C23 | Fronteira privada com layout e validações testados |
| Editor e Runtime | Executáveis independentes de validação |
| Protocolo de logs | JSON Lines limitado no bootstrap |
| Verificação Editor → Runtime | Supervisão de processo para validação, não execução de jogo |
| Modelo de ferramentas do Editor | Estado de domínio/ferramenta sem alocação; ainda sem UI |
| Contabilidade de timestep | Módulo isolado; ainda não integrado a um game loop |
| Renderer GPU | Não implementado |
| Editor gráfico / Play / gameplay | Não implementados |

Veja [APPLICATION_PROGRESS.md](docs/APPLICATION_PROGRESS.md) para evidências, limitações e resultados reportados por etapa.

## Começar

### Requisitos

- Zig **0.17.0**. Não use outra versão sem atualizar e validar o toolchain do projeto.
- Python 3 para os scripts de verificação e integração.
- Compilador C compatível com C23 e linker do alvo.
- No Linux, os pacotes de desenvolvimento exigidos pelo build legado (incluindo X11 quando aplicável).

### Compilar os pacotes independentes

Na raiz do repositório:

\`\`\`sh
cd shared
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all

cd ../editor
zig build
zig build test --summary all

cd ../runtime
zig build
zig build test --summary all
\`\`\`

Os diretórios editor/ e runtime/ produzem executáveis independentes e instalam os recursos de distribuição em zig-out/share/corex/. Preserve a árvore de instalação completa; copiar somente o binário não é suportado.

### Validar um projeto

Depois de compilar o Runtime e o Editor, execute a partir da raiz:

\`\`\`sh
runtime/zig-out/bin/CoreXRuntime \\
  --project docs/examples/EmptyGameV2.proj \\
  --headless --validate-only

editor/zig-out/bin/CoreXEditor \\
  --project docs/examples/EmptyGameV2.proj \\
  --headless --validate-only
\`\`\`

Para verificar o Runtime a partir do Editor, informe o caminho absoluto do executável:

\`\`\`sh
editor/zig-out/bin/CoreXEditor \\
  --project docs/examples/EmptyGameV2.proj \\
  --headless --validate-only \\
  --check-runtime "$PWD/runtime/zig-out/bin/CoreXRuntime"
\`\`\`

Esses comandos verificam documento, presets, distribuição e, no último caso, o handshake entre processos. **Não carregam cenas ou assets, não criam GPU, não executam scripts e não iniciam gameplay.** O modo normal de execução falha explicitamente enquanto o adaptador do core não estiver disponível.

Instruções detalhadas: [Guia de início](docs/GETTING_STARTED.md) e [contrato da CLI](docs/APPLICATION_CLI.md).

## Arquitetura e documentação

| Documento | Conteúdo |
| --- | --- |
| [Índice da documentação](docs/README.md) | Mapa dos documentos e ordem de leitura |
| [Arquitetura](docs/ARCHITECTURE.md) | Camadas, dependências e limites reais |
| [Layout das aplicações](docs/APPLICATION_LAYOUT.md) | Estrutura atual e planejada |
| [Progresso](docs/APPLICATION_PROGRESS.md) | Implementações, evidências e pendências |
| [ADR-003 — escopo desktop](docs/ADR-003-desktop-3d-canvas.md) | Plataformas, domínios e APIs |
| [Schema .proj v1](docs/PROJECT_SCHEMA_V1.md) | Contrato histórico |
| [Schema .proj v2](docs/PROJECT_SCHEMA_V2.md) | Contrato atual para novos projetos |
| [Presets gráficos](docs/PRESETS_SCHEMA_V1.md) | Parâmetros e invariantes |
| [CLI e logging](docs/APPLICATION_CLI.md) | Argumentos, códigos de saída e protocolo |
| [Contratos compartilhados](shared/README.md) | Parsing, ownership e ABI |
| [Editor](editor/README.md) / [Runtime](runtime/README.md) | Builds e limites de cada executável |

## Contribuir

Contribuições são bem-vindas. Antes de abrir uma alteração:

1. Leia [CONTRIBUTING.md](CONTRIBUTING.md).
2. Confira os ADRs e os contratos existentes antes de alterar comportamento.
3. Preserve os limites entre recursos implementados, planejados e experimentais.
4. Execute os testes relevantes e descreva exatamente o que foi validado.

Consulte também o [Código de Conduta](CODE_OF_CONDUCT.md), a [Política de Segurança](SECURITY.md) e os [canais de suporte](SUPPORT.md).

## Licença

Nenhum arquivo de licença foi identificado na raiz deste repositório. Até que uma licença seja adicionada pelo mantenedor, não presuma que o código esteja disponível sob uma licença open source ou que possa ser redistribuído/modificado livremente. Consulte o mantenedor antes de reutilizar o conteúdo.

---

<p align="center"><sub>CoreX Engine · documentação alinhada ao estado verificável do repositório.</sub></p>
