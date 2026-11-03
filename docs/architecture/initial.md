# Proposta inicial de arquitetura (histórica)

> Este documento preserva as primeiras notas gerais de projeto do CoreX. Não é o plano de implementação atual nem um relatório de status. A arquitetura e o escopo autoritativos estão em [`../ARCHITECTURE.md`](../ARCHITECTURE.md), nos ADRs numerados e em [`../STATUS.md`](../STATUS.md).

## Objetivos originais

A proposta inicial considerava um Engine baseado em Zig, com design orientado a dados, modelo ECS, fronteiras modulares, gestão explícita de memória e abstrações de baixo overhead.

## Conceitos registrados no primeiro esboço

A proposta listava áreas separadas para ciclo de vida do core, plataforma/janela/entrada, eventos e jobs, ECS, cenas/assets, gráficos/renderização, física, scripting, áudio/animação, serialização e depuração/profiling. Também considerava estratégias de allocator e uma sequência incremental de implementação.

Esses itens descrevem apenas conceitos pretendidos. A existência de um diretório ou arquivo-fonte correspondente não confirma uma implementação completa, API pública, subsistema de produção ou integração ao Editor/Runtime.

## Substituição por decisões atuais

O escopo atual do produto é Windows/Linux, autoria 3D e UI/Canvas; macOS e modo de cena 2D estão fora do escopo presente. Editor e Runtime são bootstraps independentes de validação. Vulkan, apresentação nativa em GPU, execução de jogos e ciclo de vida do Engine privado compartilhado continuam pendentes. Consulte [ADR-003](../ADR-003-desktop-3d-canvas.md), [ADR-001](../ADR-001-editor-runtime.md) e [ADR-005](../ADR-005-vulkan-surface-integration.md).
