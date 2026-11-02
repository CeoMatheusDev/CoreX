# Arquitetura

Este documento descreve a arquitetura observável do CoreX e distingue componentes implementados de responsabilidades planejadas. A estrutura do diretório, por si só, não é evidência de que um subsistema esteja funcional.

## 1. Princípios

- **Ownership explícito:** cada alocação deve ter um proprietário e uma regra de liberação identificáveis.
- **Alocação fora do frame:** parsing, validação e preparação de configuração pertencem à inicialização ou a operações de ferramenta, não ao caminho crítico de renderização.
- **Contratos fechados:** schemas versionados, enums explícitos, limites de entrada e rejeição de campos desconhecidos.
- **Fronteiras verificáveis:** interoperabilidade C recebe DTOs com larguras, alinhamento e validações explícitas; tipos internos Zig não atravessam a ABI diretamente.
- **Falha explícita:** backend elegível não equivale a backend disponível; recurso ausente não deve ser substituído por sucesso simulado.
- **Separação de produto:** Editor, Runtime e pacote compartilhado têm builds e responsabilidades distintos.

## 2. Estado arquitetural

\`\`\`text
                    ┌───────────────────────────┐
                    │       CoreX Project       │
                    └─────────────┬─────────────┘
                                  │
              ┌───────────────────┴───────────────────┐
              │                                       │
      ┌───────▼────────┐                     ┌────────▼───────┐
      │     Editor     │                     │    Runtime     │
      │  CLI/Bootstrap │                     │  CLI/Bootstrap │
      └───────┬────────┘                     └────────┬───────┘
              │                                       │
              └───────────────────┬───────────────────┘
                                  │
                       ┌──────────▼──────────┐
                       │       shared       │
                       │ schemas / presets  │
                       │ CLI / JSONL / ABI  │
                       └─────────────────────┘
\`\`\`

O diagrama representa o fluxo de contratos e validação atualmente implementado. Não representa um pipeline gráfico ou um game loop.

### Pacotes presentes

| Pacote | Responsabilidade atual | Limite |
| --- | --- | --- |
| shared/ | Parsing .proj, presets, validação, fingerprint, CLI, JSONL, distribuição e DTO C23 | Não carrega recursos do jogo nem cria GPU |
| editor/ | Executável de bootstrap, validação e supervisão opcional do Runtime | Não possui interface gráfica, viewport ou edição de cena |
| runtime/ | Executável de bootstrap e validação de projeto | Não executa gameplay, scripts, jobs ou game loop |
| src/ | Core legado e componentes iniciais | Inclui backend null e subsistemas incompletos/stubs |
| docs/ | ADRs, schemas, contratos, progresso e guias | A documentação deve acompanhar o código e evidências |

## 3. Fluxo de validação atual

1. A CLI valida argumentos e combinações de modos.
2. O bootstrap localiza os recursos instalados junto ao executável.
3. O documento .proj é lido e validado contra o schema suportado.
4. A tabela de presets é validada e os overrides são resolvidos.
5. A configuração concreta é traduzida para o DTO C23 privado.
6. O processo emite eventos JSON Lines com limites definidos.
7. Opcionalmente, o Editor inicia um Runtime confiável em modo --validate-only e compara o fingerprint resultante.

Esse fluxo comprova consistência de documento/configuração entre os executáveis. Não comprova carregamento de cenas, integridade/autenticidade de executáveis, compatibilidade de drivers ou execução determinística de gameplay.

## 4. Domínios e plataformas

O perfil de produto atual é definido em [ADR-003](ADR-003-desktop-3d-canvas.md):

- Sistemas operacionais: Windows e Linux.
- Domínios de autoria: scene_3d e ui_canvas.
- Cena/gameplay 2D: fora do escopo atual.
- APIs gráficas previstas: Vulkan/OpenGL em ambos os sistemas; D3D11/D3D12 somente Windows.
- Metal e WebGPU: fora do perfil atual.

A matriz indica intenção/eligibilidade de produto. A implementação do renderer, consulta de capacidades, criação de device e apresentação ainda são pendências.

## 5. Fronteiras e ownership

### Documentos e configuração

O parser compartilhado cria um documento com arena própria. As strings pertencem ao documento e deixam de ser válidas após deinit. O chamador não deve copiar o proprietário e liberar a mesma arena mais de uma vez.

A serialização canônica produz bytes em memória; ela não grava arquivos e não implementa substituição atômica, backup ou resolução segura de recursos no filesystem.

### ABI

O DTO Zig/C23 é privado ao bootstrap/aplicações. Ele usa campos de largura explícita e verificações de tamanho/alinhamento/offset. Não é a API pública futura do core e não significa que o core esteja ligado.

### Processos

A verificação Editor → Runtime executa somente o caminho explicitamente solicitado pelo usuário. O executável precisa ser confiável. O supervisor limita captura e duração e gerencia o processo filho imediato; não é sandbox e não controla árvores de subprocessos.

## 6. Sistemas legados

O core em src/ contém implementações iniciais e exemplos de subsistemas como ECS, memória, jobs, eventos, renderer e UI. O renderer observado usa NullBackend; portanto, submissão de comandos não produz imagem em GPU. O Event Bus legado é síncrono, sequencial e não thread-safe. A fila legada de jobs também não deve ser interpretada como scheduler paralelo integrado ao Runtime.

Antes de depender de qualquer módulo legado, consulte seus testes e documentação local. Não inferir maturidade a partir do nome do diretório.

## 7. Evolução planejada

As próximas integrações devem preservar a ordem das dependências:

1. API pública do core e lifecycle de plataforma.
2. Abstração gráfica real: device, recursos, comandos, sincronização e apresentação.
3. Renderer e render graph com testes por backend.
4. Cena 3D, ECS e asset pipeline integrados.
5. Runtime loop com input, timestep, jobs e lifecycle de falhas.
6. Editor UI, transações, undo/redo e persistência segura.
7. Scripting e gameplay host atrás de uma ABI estável.

A sequência é uma orientação arquitetural, não uma promessa de entrega ou declaração de suporte.

## 8. ADRs relacionados

- [ADR-003 — Windows/Linux, autoria 3D e UI/Canvas](ADR-003-desktop-3d-canvas.md)
- [ADR-002 — Bootstrap e supervisão de validação](ADR-002-validation-bootstrap.md)
- [Schemas e contratos](README.md)
