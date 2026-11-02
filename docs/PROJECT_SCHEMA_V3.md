# Contrato `.proj` v3 — Renderer explícito

V3 é uma extensão aditiva do envelope `.proj`, sem alterar a gramática ou os schemas V1/V2. Schema estrutural: [project-v3.schema.json](schemas/project-v3.schema.json). Exemplo aprovado: [EmptyGameV3.proj](examples/EmptyGameV3.proj).

## Mudança do contrato

V3 conserva os campos, tipos, defaults, limites e validações semânticas de V2 e adiciona um único campo obrigatório:

| Campo | Tipo | Valores | Significado |
| --- | --- | --- | --- |
| `renderer.profile` | string enum | `advanced`, `standard`, `lite` | Identidade explícita do Renderer solicitado |

`renderer.profile` não é `engine.graphics_backend`, `renderer.graphics_preset` nem `desktop-3d-canvas-v1`. O backend continua identificando a API gráfica solicitada (`vulkan`, `opengl`, `d3d11` ou `d3d12`); o preset continua a qualidade (`low`, `medium` ou `high`); `desktop-3d-canvas-v1` continua sendo o perfil de produto/plataforma. Não há inferência entre esses campos e nenhum preset de qualidade foi acrescentado.

V1 e V2 permanecem fechados e compatíveis. Ao carregar/serializar V1 ou V2, `renderer.profile` fica ausente; nenhum Renderer é selecionado automaticamente. Um objeto `.proj` V3 sem profile, ou com token não reconhecido, é inválido. O serializer conserva a versão e recusa objetos incoerentes (V3 sem profile, ou profile em V1/V2). Nenhuma migração, rewrite, troca de backend ou downgrade automático é realizada.

## Estado de suporte

O leitor compartilhado aceita schemas `[1,2,3]`. Editor/Runtime podem validar V3 com `--validate-only`, incluindo o profile escolhido no fingerprint; isso valida somente documento, compatibilidade de Engine e presets. Não constitui disponibilidade do Renderer, checagem de GPU, compilação de shader ou execução gráfica. O bootstrap ainda informa que o core gráfico não está implementado; não emite `runtime.ready` e não faz fallback. Os perfis `advanced`, `standard` e `lite` são identificadores de contrato, não declarações de implementações funcionais.

A versão do fingerprint é 4. Ele inclui separadamente o perfil de produto/plataforma (`application_profile`, `desktop-3d-canvas-v1`) e a identidade solicitada (`renderer_profile`), além do projeto normalizado, parâmetros e manifesto validados. O fingerprint não é atestado de execução nem autorização por si só.

## Schemas anteriores

V1 permanece o contrato histórico definido em [PROJECT_SCHEMA_V1.md](PROJECT_SCHEMA_V1.md); V2 permanece o contrato desktop 3D/Canvas definido em [PROJECT_SCHEMA_V2.md](PROJECT_SCHEMA_V2.md). V3 não retroage as suas mudanças para esses schemas nem altera os bytes dos seus arquivos JSON Schema ou exemplos aprovados.
