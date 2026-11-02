# Snapshot arquivado do protótipo — 2026-11-01

> **Registro histórico, não status atual.** Este documento preserva o contexto do primeiro protótipo da árvore legada. É superado por [`STATUS.md`](STATUS.md), [`APPLICATION_PROGRESS.md`](APPLICATION_PROGRESS.md) e pela [arquitetura atual](ARCHITECTURE.md). As notas originais usavam caminhos locais e descreviam módulos planejados ou placeholders de forma ampla; essas afirmações não são mantidas como evidência de funcionalidade atual.

## Escopo do protótipo

A árvore inicial estabeleceu uma build Zig 0.17.0 e uma pequena demonstração executável. Diretórios de código-fonte foram criados para ciclo de vida do core, memória, configuração de projeto, ECS, eventos/jobs, gráficos, scripting, áudio, animação, cenas, serialização, assets e profiling. A presença de diretórios ou arquivos não significava que cada subsistema tivesse implementação de produção ou estivesse conectado a um jogo em execução.

## Correções importantes ao registro inicial

- O `ProjectLoader` legado retornava configuração de exemplo/fallback; naquele momento, não era um parser completo de arquivos `.proj`.
- O caminho visível do renderer usava o Null Backend. Não submetia trabalho à GPU nem apresentava frames.
- O executável `CoreXEngine` legado demonstrava a ligação de módulos; não representava os bootstraps atuais de Editor/Runtime, o carregamento completo de projetos ou a execução de gameplay.
- As notas iniciais sobre allocators, scripting e plataforma descreviam protótipos, não garantias de API ou release.
- A expressão antiga “Fase 1 completa” não indicava um release de produto. A autoridade atual de versão e mudanças é [`../VERSION`](../VERSION) e [`../CHANGELOG.md`](../CHANGELOG.md).

## Fontes atuais

- Build do repositório e limites do produto: [`../README.md`](../README.md)
- Fronteiras atuais de aplicação e gráficos: [`STATUS.md`](STATUS.md) e [`ARCHITECTURE.md`](ARCHITECTURE.md)
- Evidências de implementação do Editor/Runtime: [`APPLICATION_PROGRESS.md`](APPLICATION_PROGRESS.md)
- Versionamento do produto: [`../VERSIONING.md`](../VERSIONING.md)
