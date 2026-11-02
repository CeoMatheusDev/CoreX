# Marcos técnicos históricos

> Este arquivo registra um snapshot inicial da árvore legada, de 2026-11-01. Não é changelog de produto, registro de release nem declaração de que os subsistemas listados estejam prontos para produção. Para mudanças de produto, consulte [`../CHANGELOG.md`](../CHANGELOG.md); para o estado atual, consulte [`STATUS.md`](STATUS.md) e [`APPLICATION_PROGRESS.md`](APPLICATION_PROGRESS.md).

O protótipo inicial introduziu uma build Zig na raiz, uma demonstração com Null Renderer e arquivos de módulos preliminares para ECS, memória, jobs, eventos, scripting, áudio, animação, cenas, serialização, assets e profiling. Mais tarde, o protótipo recebeu as dependências fixadas Zigway e ZyntraUI e evoluiu separadamente das aplicações de validação Editor/Runtime.

A existência de um arquivo-fonte ou demonstração neste protótipo não comprova um subsistema completo, uma API pública do Engine ou um recurso integrado ao Editor/Runtime. Em particular, esse marco não entregou backend Vulkan, apresentação nativa em GPU ou loop de jogo funcional.
