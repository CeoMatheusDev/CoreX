# Contrato `.proj` v2 — perfil desktop 3D/Canvas

Decisão: [ADR-003](ADR-003-desktop-3d-canvas.md), conforme correção de escopo do usuário. Schema estrutural: [project-v2.schema.json](schemas/project-v2.schema.json). Exemplo: [EmptyGameV2.proj](examples/EmptyGameV2.proj).

## Compatibilidade e conteúdo

V2 mantém **todas** as propriedades, tipos, defaults, limites, invariantes, parsing estrito, paths, ownership e canonicalização definidos em [PROJECT_SCHEMA_V1.md](PROJECT_SCHEMA_V1.md), com exatamente estas mudanças:

| Campo | V1 histórico | V2 |
| --- | --- | --- |
| `schema_version` | `1` | `2` |
| `engine.graphics_backend` | `vulkan`, `webgpu`, `d3d12`, `metal` | `vulkan`, `opengl`, `d3d11`, `d3d12` |

Nenhum campo livre de extensões ou discriminador de cena foi acrescentado. O formato de cenas/Canvas depende dos serviços reais do core; não será inventado no documento de projeto. UI/Canvas pode usar imagens/retângulos/texto 2D, mas não constitui um modo de cena/gameplay 2D. Presets continuam v1, com os mesmos 27 parâmetros e 13 overrides aprovados.

O reader aceita v1/v2, verifica a versão antes de decodificar o corpo e retorna `supported_schema_versions: [1,2]` nos erros de projeto. V1 não aceita os tokens novos. V2 rejeita `metal`, `webgpu`, aliases como `dx11` e diferenças de caixa como `OpenGL`. O serializer conserva a versão escolhida e recusa backend que não pertença a ela. Não há migração, rewrite ou troca de backend automáticos; Runtime nunca grava `.proj`.

V1 com backend removido continua inspecionável em `--validate-only`, mas sua execução é recusada. Converter explicitamente exige escolher backend v2, alterar versão e validar a cópia; isso ainda não é um comando de migração/edição do Editor.

## Elegibilidade de produto, não capacidade GPU

| API | Windows | Linux |
| --- | --- | --- |
| Vulkan | prevista | prevista |
| OpenGL | prevista | prevista |
| D3D11 | prevista | recusada |
| D3D12 | prevista | recusada |
| Metal/WebGPU | fora do produto | fora do produto |

“Prevista” não significa renderer integrado. O core atual liga somente NullBackend, que não será usado para fingir sucesso gráfico. Nada aqui estabelece versão OpenGL, feature level DirectX, extensões Vulkan ou requisitos mínimos de GPU: dependem da implementação real e da consulta pré-device.

`--validate-only` é validação de documento/presets, não teste de executabilidade neste SO. Assim permite validar projeto D3D no Linux e registra `application.target_policy.decision=backend_not_on_platform`, com `gpu_created=false` e `renderer_linked=false`. Execução sem essa flag recusa a política inválida antes de criar recursos; política permitida ainda falha com core indisponível nesta fatia. Não há fallback.

O perfil `desktop-3d-canvas-v1` entrou no fingerprint v2, junto do projeto normalizado completo, parâmetros e manifesto. A versão atual do fingerprint é v3 porque o manifesto agora carrega a identidade de produto e o contrato explícito de compatibilidade. Nenhuma das versões do fingerprint altera este schema `.proj`. Fingerprints não incluem relógio/sessão/PID nem provam determinismo de simulação. Editor e Runtime confirmam a mesma configuração pelo módulo compartilhado.

Sufixos de gameplay suportados nesta entrega: `.dll` no Windows e `.so` no Linux. macOS/`.dylib` são apenas contexto histórico do contrato v1, não alvos de produto v2. Permanecem os limites anteriores: NFC/containment reais pendentes; caminhos não ASCII dentro do documento falham explicitamente até P14.
