# Documentação CoreX

Este diretório reúne decisões arquiteturais, contratos de dados, guias operacionais e evidências de implementação. Leia os documentos na ordem sugerida e confira sempre o estado de implementação antes de depender de uma funcionalidade.

## Começar

1. [Visão geral e build](../README.md)
2. [Guia de início](GETTING_STARTED.md)
3. [Arquitetura](ARCHITECTURE.md)
4. [Estado e evidências](APPLICATION_PROGRESS.md)
5. [Contribuição](../CONTRIBUTING.md)

## Arquitetura e decisões

| Documento | Descrição |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Camadas atuais, ownership e fronteiras |
| [APPLICATION_LAYOUT.md](APPLICATION_LAYOUT.md) | Estrutura atual e planejada dos pacotes |
| [ADR-002](ADR-002-validation-bootstrap.md) | Bootstrap e supervisão de validação |
| [ADR-003](ADR-003-desktop-3d-canvas.md) | Perfil Windows/Linux, 3D e UI/Canvas |

## Contratos e formatos

| Documento | Descrição |
| --- | --- |
| [PROJECT_SCHEMA_V1.md](PROJECT_SCHEMA_V1.md) | Contrato histórico de projeto v1 |
| [PROJECT_SCHEMA_V2.md](PROJECT_SCHEMA_V2.md) | Contrato de projeto v2 |
| [PRESETS_SCHEMA_V1.md](PRESETS_SCHEMA_V1.md) | Tabela e parâmetros gráficos |
| [APPLICATION_CLI.md](APPLICATION_CLI.md) | CLI, JSON Lines, códigos de saída e limites |
| [../shared/README.md](../shared/README.md) | Parsing, ownership, presets e DTO Zig/C23 |
| [EVENT_BUS.md](EVENT_BUS.md) | Event Bus síncrono do core legado |

## Implementação e evidências

| Documento | Descrição |
| --- | --- |
| [APPLICATION_PROGRESS.md](APPLICATION_PROGRESS.md) | Progresso por etapa, testes reportados e limitações |
| [APPLICATION_LAYOUT.md](APPLICATION_LAYOUT.md) | Responsabilidades existentes e planejadas |
| [../editor/README.md](../editor/README.md) | Build e escopo do executável Editor |
| [../runtime/README.md](../runtime/README.md) | Build, validação e modelo de timing do Runtime |

## Convenções documentais

- **Implementado:** existe no código e possui evidência verificável.
- **Parcial:** existe uma parte funcional, mas a integração ou garantias ainda estão incompletas.
- **Planejado:** ainda não deve ser usado como funcionalidade disponível.
- **Fora de escopo:** não faz parte do perfil de produto atual.

Os ADRs registram decisões e trade-offs. Não os reescreva para refletir uma preferência nova: proponha um ADR sucessor quando uma decisão precisar mudar. Atualize este índice sempre que adicionar ou remover documentação de referência.
