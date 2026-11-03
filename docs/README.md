# CoreX Documentation

![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white) ![C23](https://img.shields.io/badge/C-C23-00599C?logo=c) ![Platforms](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-555)

The technical documentation hub for CoreX: implementation status, architecture, project contracts, engineering decisions, and validation evidence.

> [!NOTE]
> Use STATUS.md for current implementation claims. Design proposals and historical test results must not be treated as proof of current functionality.

---

Use este índice para localizar contratos, evidências de implementação, decisões arquiteturais e registros históricos. Para a visão geral e os comandos de build, comece pelo [README da raiz](../README.md).

## Estado atual e aplicações

- [Status do projeto](STATUS.md) — fronteiras implementadas e limites explícitos.
- [Arquitetura](ARCHITECTURE.md) — aplicações, árvore legada e fronteira gráfica pretendida.
- [Progresso de implementação](APPLICATION_PROGRESS.md) — etapas e evidências de validação por fatia.
- [Estrutura das aplicações](APPLICATION_LAYOUT.md) — responsabilidades e organização dos módulos.
- [CLI das aplicações](APPLICATION_CLI.md) — comandos, JSON Lines, códigos de saída e validação cruzada do Runtime.

## Contratos e schemas

- [Schema de projeto v1](PROJECT_SCHEMA_V1.md)
- [Schema de projeto v2](PROJECT_SCHEMA_V2.md)
- [Schema de projeto v3](PROJECT_SCHEMA_V3.md)
- [Schema de presets v1](PRESETS_SCHEMA_V1.md)
- [Contrato do Event Bus](EVENT_BUS.md) — bus síncrono legado; não é o protocolo Editor/Runtime.
- Schemas JSON legíveis por máquina: [`schemas/`](schemas/)

## Registros de decisão (ADR)

| ADR | Decisão |
| --- | --- |
| [ADR-001](ADR-001-editor-runtime.md) | Responsabilidades do Editor/Runtime e contratos compartilhados |
| [ADR-002](ADR-002-validation-bootstrap.md) | Bootstraps de validação e supervisão de processos-filhos |
| [ADR-003](ADR-003-desktop-3d-canvas.md) | Escopo Windows/Linux e autoria 3D/Canvas |
| [ADR-004](ADR-004-project-opening-splash.md) | Abertura de projetos, splash e limites de implementação |
| [ADR-005](ADR-005-vulkan-surface-integration.md) | Contrato de janela nativa Zigway necessário à futura integração Vulkan |

## Desenvolvimento, ferramentas e versão

- [Guia de contribuição](../CONTRIBUTING.md) — toolchain, contratos e expectativas de validação.
- [Política de versionamento](../VERSIONING.md)
- [Procedimentos de validação de versão](VERSIONING_VALIDATION.md)
- [Plano de remoção gradual de Python](PYTHON_REMOVAL.md)
- [Captura da saída da CI](../tools/CI_CAPTURE.md)

## Exemplos e registros históricos

- [Projeto de exemplo](../exemploproject/README.md)
- [Proposta arquitetural inicial](architecture/initial.md) — registro histórico, superado pelos ADRs numerados e pela arquitetura atual.
- [Resultados do protótipo inicial](results.md) — snapshot arquivado; não prova o comportamento atual.
- [Marcos técnicos legados](CHANGES.md) — remete ao changelog canônico de produto.
- [Integrações legadas](integrations.md) — versões fixadas e limites das dependências de janela/UI.

Descrição planejada ou histórica não comprova recurso implementado. O status atual e os limites de validação estão registrados em `STATUS.md` e `APPLICATION_PROGRESS.md`.
