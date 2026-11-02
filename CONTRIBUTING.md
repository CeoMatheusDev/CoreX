# Guia de contribuição

Obrigado pelo interesse em contribuir com o CoreX. Este projeto está em desenvolvimento inicial; mudanças pequenas, reproduzíveis e alinhadas aos contratos existentes são preferíveis a grandes refatorações sem evidência.

## Antes de começar

1. Leia o [README](README.md), a [arquitetura](docs/ARCHITECTURE.md) e o [índice de documentação](docs/README.md).
2. Consulte os ADRs relevantes antes de alterar decisões de produto, schemas, ABI, dependências ou plataformas.
3. Verifique se a funcionalidade existe de fato. Não trate diretórios, stubs ou planos como APIs estáveis.
4. Para mudanças maiores, abra uma issue de proposta antes de implementar.

## Escopo e compatibilidade

- O perfil de produto é Windows/Linux, com autoria 3D e UI/Canvas; cena/gameplay 2D está fora do escopo atual.
- Não declare Vulkan, OpenGL, D3D11 ou D3D12 como funcionais enquanto o backend correspondente não estiver integrado e testado.
- Não transforme validação de documento em execução simulada de jogo.
- Preserve a compatibilidade dos schemas publicados. Mudanças incompatíveis exigem novo schema e ADR.
- Não altere versões, hashes ou licenças de dependências para contornar falhas de build.
- Não adicione fallback silencioso para recursos ausentes, configuração inválida ou APIs não suportadas.

## Ambiente de desenvolvimento

Toolchain de referência: Zig 0.17.0. Python 3 é necessário para os scripts de integração e verificação. Use o compilador C23 para a fronteira nativa.

Antes de submeter, execute os testes relevantes:

\`\`\`sh
# Contratos compartilhados
cd shared
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
cd ..

# Editor
cd editor
zig build
zig build test --summary all
cd ..

# Runtime
cd runtime
zig build
zig build test --summary all
cd ..

# Fixtures e integração Editor -> Runtime
python tools/check_contract_fixtures.py
python tools/test_bootstrap.py
\`\`\`

O teste de integração requer que Editor e Runtime tenham sido compilados. Para mudanças no core legado, consulte os comandos e requisitos descritos no README; o build legado tem dependências próprias.

Execute também o formatador nos arquivos Zig alterados:

\`\`\`sh
zig fmt --check caminho/do/arquivo.zig
\`\`\`

Se um comando não puder ser executado no seu ambiente, informe isso explicitamente. Cross-compilação não equivale a execução nativa na plataforma de destino.

## Padrões de implementação

### Zig e memória

- Prefira tipos e contratos explícitos a coerções implícitas.
- Documente o proprietário de cada buffer, arena, handle e recurso.
- Toda função que aloca deve deixar claro quem libera o resultado e em qual allocator.
- Evite alocações no caminho por frame; faça parsing e preparação na inicialização ou em operações de ferramenta.
- Trate OOM e overflow como resultados explícitos; não descarte erros para simplificar o fluxo.
- Não copie structs proprietárias quando isso puder causar double-free ou uso após liberação.
- Não introduza estado global mutável sem justificativa e contrato de concorrência.

### Concorrência e ciclo de vida

- Declare se uma estrutura é thread-safe, thread-affine ou exige serialização externa.
- Defina regras de reentrada, shutdown e ownership de callbacks.
- Não chame uma fila sequencial de job system paralelo.
- Não faça retry automático após callback parcialmente executado sem garantia de idempotência/rollback.

### APIs e dependências

- Mantenha dependências externas pequenas e justificadas.
- Fixe versão e hash de qualquer dependência baixada.
- Isole chamadas de SO e ABI em fronteiras estreitas.
- Não exponha tipos internos Zig diretamente em ABI C.
- Adicione testes para layout, alinhamento, larguras e tratamento de erros em fronteiras nativas.

### Documentação

- Atualize os READMEs, schemas, ADRs e documentos de progresso afetados pelo comportamento alterado.
- Identifique claramente o que está implementado, planejado, experimental ou fora de escopo.
- Não publique números de performance sem metodologia, ambiente e resultado reproduzível.
- Exemplos devem corresponder a arquivos e comandos existentes.

## Commits e pull requests

Use mensagens concisas e imperativas, preferencialmente no formato Conventional Commits:

- \`feat(renderer): add device capability query\`
- \`fix(shared): reject duplicate schema keys\`
- \`docs: clarify runtime validation scope\`
- \`test(ecs): cover entity generation overflow\`

Um pull request deve conter:

1. Contexto e problema que a mudança resolve.
2. Resumo da solução e decisões relevantes.
3. Arquivos/subsistemas afetados.
4. Testes executados e seus resultados.
5. Plataformas efetivamente testadas.
6. Limitações conhecidas, riscos e tarefas futuras.
7. Atualização da documentação aplicável.

Mantenha cada PR focado. Evite misturar refatoração ampla, mudança de contrato e implementação de funcionalidade sem relação.

## Revisão

Uma contribuição pode receber pedidos de alteração quando introduzir comportamento não documentado, quebrar compatibilidade, ocultar falhas, enfraquecer limites de memória/entrada ou declarar capacidade sem evidência. Discussões técnicas devem se concentrar no código e nas decisões, sempre com respeito.

Ao abrir um PR, confirme que você tem direito de enviar o código e que não está incluindo segredos, credenciais, arquivos de build ou conteúdo de terceiros sem licença compatível.
