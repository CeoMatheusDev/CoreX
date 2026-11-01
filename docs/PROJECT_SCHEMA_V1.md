# Contrato `.proj` v1 — aprovado (item 2)

**Estado:** aprovado pelo usuário em 2026-11-01. ADR-001 e `presets.zon` (item 3) também aprovados. Na etapa documental não houve código; a implementação incremental dos contratos iniciou depois em `shared/`.

## 1. Artefatos e autoridade

- Decisões arquiteturais: [ADR-001](ADR-001-editor-runtime.md).
- Validação estrutural: [project-v1.schema.json](schemas/project-v1.schema.json), JSON Schema Draft 2020-12, sem resolução de referências remotas durante execução.
- Exemplo completo sem gameplay: [EmptyGame.proj](examples/EmptyGame.proj).
- Este documento define validações semânticas e limites que JSON Schema não expressa. **As duas partes são normativas**. Passar em um validador JSON Schema isolado não significa que o projeto possa executar.

O exemplo é fixture documental: não inclui `Main.scene`, assets, pastas, módulos compilados nem uma engine instalada. A versão `0.1.0` ilustra sintaxe, não comprova disponibilidade de um core compatível.

### Justificativas complementares ao ADR

- Adicionar `simulation` permite seed e taxa fixa explícitas, em vez de defaults ocultos que prejudicariam replay.
- Separar raízes de scripts de entrypoints evita executar recursivamente qualquer arquivo encontrado. Descoberta de C++ é tarefa de build, não de carregamento de projeto.
- Raiz de cenas explícita permite validar contenção e alimentar o content browser sem inferir convenções de diretório.
- Overrides são mapa plano e fechado: merge por campo é previsível, não há deep merge ambíguo. Nomes e unidades abaixo são proposta de interface; valores low/medium/high e cobertura do renderer serão definidos no item 3. Qualquer revisão incompatível nessa etapa retorna para aprovação deste item antes de código.
- Versão exata da engine, em vez de intervalo SemVer, evita que uma atualização silenciosa altere presets, ABI e comportamento do jogo. É restritivo, mas auditável.
- Seed `u32`, em vez de `u64`, evita perda de precisão em ferramentas JSON baseadas em números IEEE-754. O contrato futuro do core deve fixar algoritmo de RNG e expansão da seed; o campo sozinho não garante replay entre versões.

## 2. Representação e parsing

Arquivo JSON estrito em UTF-8, sem BOM, comentários, trailing commas ou chaves repetidas em qualquer objeto. JSON válido com surrogates Unicode isolados é rejeitado pelo contrato textual. Strings e nomes de caminho não contêm NUL. Não aceitar NaN/Infinity ou valores numéricos fora do tipo de destino. A ordem de propriedades não altera o significado.

O módulo compartilhado lê em três etapas: parsing limitado com detecção de duplicatas; verificação de `schema_version`; validação estrutural e semântica v1. Para um documento sintaticamente válido de versão futura, retorna incompatibilidade antes de interpretar seu corpo como v1. Erros sintáticos/limites têm precedência sobre leitura de versão. Runtime nunca tenta inferir a versão pelo conteúdo.

### Limites de segurança comuns aos dois consumidores

| Limite | Valor |
| --- | --- |
| Tamanho bruto do `.proj` | 1 MiB (1.048.576 bytes) |
| Profundidade de containers | 16, contando objeto raiz como nível 1 |
| Quantidade total de membros de objetos | 256 |
| Tamanho de qualquer string decodificada | 4096 bytes UTF-8 |
| Caminho relativo | 1024 bytes UTF-8 no máximo |
| Nome de projeto | 1–128 valores escalares Unicode, respeitando teto global de bytes |
| SemVer | 128 caracteres ASCII no máximo |

JSON Schema mede `maxLength` em caracteres; portanto o parser deve aplicar também os limites em bytes acima. Arrays não fazem parte do modelo v1; o parser limita qualquer coleção a 256 elementos antes mesmo de descobrir que o campo não é válido. Profundidade, contagem e bytes são verificados antes de alocar sem limite.

Campos inteiros aceitam apenas valores matematicamente inteiros e dentro do intervalo exato, inclusive se escritos como `60.0` ou `6e1`; serialização canônica escreve `60`. Conversão não pode arredondar um decimal fracionário para fazê-lo parecer inteiro. Números reais de renderer são convertidos uma única vez para `f32`, com rejeição de overflow, underflow para zero em campos estritamente positivos e não finitos. A configuração normalizada é a referência dos testes de round-trip. Não se exige identidade textual do arquivo.

## 3. Estrutura raiz e tipos

Todos os objetos são fechados (`additionalProperties: false`); objetos opcionais também. Não há campo livre `extensions` em v1. `null` só é permitido nos três campos opcionais de scripts descritos abaixo.

| Campo raiz | Tipo Zig conceitual | Obrigatório | Regra |
| --- | --- | --- | --- |
| `schema_version` | `u32` | sim | exatamente `1` |
| `project` | `ProjectMetadata` | sim | identidade do projeto |
| `engine` | `EngineRequirement` | sim | versão e backend pretendido |
| `renderer` | `RendererRequest` | sim | intenção gráfica, não device criado |
| `scenes` | `ScenePaths` | sim | diretório e cena inicial |
| `scripts` | `ScriptPaths` | sim | fontes e modos de gameplay |
| `assets` | `AssetPaths` | sim | diretório de assets |
| `simulation` | `SimulationConfig` | sim | taxa lógica e seed |

Os nomes Zig são descritivos, não código nem ABI. Strings do modelo carregado pertencem ao documento; a implementação futura documentará destruição e invalidação. Não serão emprestadas de buffers temporários.

### 3.1 `project`

Todos os campos são obrigatórios.

| Campo | Tipo | Validação / significado |
| --- | --- | --- |
| `name` | string UTF-8 | 1–128 escalares, ao menos um caractere não whitespace; sem controles U+0000–001F/U+007F, sem whitespace inicial/final |
| `uuid` | string | UUID v4 canônico minúsculo, variante RFC; identidade permanece após renomear/mover |
| `version` | string | SemVer 2.0.0 do jogo, incluindo prerelease/build metadata opcionais |
| `created_at` | string | data real UTC `YYYY-MM-DDTHH:mm:ssZ`, sem frações, offset alternativo ou leap second; anos 0001–9999 |

Não reutilizar UUID ao criar um novo projeto por cópia explícita/template. Fazer checkout ou mover o mesmo projeto não gera novo UUID. Abrir/salvar não modifica `created_at` nem incrementa a versão do jogo.

### 3.2 `engine`

| Campo | Tipo | Obrigatório | Regra |
| --- | --- | --- | --- |
| `version` | string SemVer | sim | identidade exata da distribuição exigida; sem intervalos, `latest` ou curingas |
| `graphics_backend` | enum | sim | `vulkan`, `webgpu`, `d3d12`, `metal` |

Comparação de versão da engine é identidade exata, inclusive prerelease/build metadata; não apenas precedência SemVer. ABI é negociada adicionalmente em runtime, não inferida do número. A distribuição fixa versões/hashes de core, presets e dependências em seu manifesto; o `.proj` não permite trocar isoladamente sua tabela de presets.

Aceitar um nome de backend no schema não afirma que existe implementação na engine/SO atual. Falta de versão, ABI ou backend é erro explícito de compatibilidade/capacidade. Headless exige versão/core de simulação compatíveis, mas não exige GPU nem disponibilidade do backend gráfico pretendido.

### 3.3 `renderer`

| Campo | Tipo | Obrigatório | Regra / default |
| --- | --- | --- | --- |
| `graphics_preset` | enum | sim | `low`, `medium`, `high`; sem default |
| `vsync` | boolean | sim | sem default; não aceita 0/1/string |
| `initial_resolution.width` | `u32` | sim | 64–16384 pixels de framebuffer |
| `initial_resolution.height` | `u32` | sim | 64–16384 pixels de framebuffer |
| `overrides` | objeto parcial | não | ausente equivale a `{}`; `null` inválido |

Resolução é intenção inicial do conteúdo/framebuffer do Runtime; o Editor tem layout de janela próprio e aplica a intenção ao viewport de jogo. Escala de UI/DPI não altera os parâmetros de qualidade. Surface menor que a solicitada pode exigir resize imposto pela plataforma, registrado como evento; limite de GPU incompatível é erro, não clamp silencioso.

#### Overrides permitidos (todos opcionais)

| Campo | Tipo normalizado | Valores / unidade |
| --- | --- | --- |
| `shadows_enabled` | bool | habilita avaliação de sombras |
| `shadow_map_size` | `u32` | 256, 512, 1024, 2048, 4096, 8192; pixels por mapa/cascata |
| `shadow_cascades` | `u8` | 1–4; cascatas direcionais |
| `shadow_distance_m` | `f32` | `0 < x <= 100000`; metros |
| `msaa_samples` | `u8` | 1, 2, 4, 8; 1 = sem MSAA |
| `draw_distance_m` | `f32` | `0 < x <= 100000`; metros |
| `texture_max_dimension` | `u32` | 256, 512, 1024, 2048, 4096, 8192, 16384; pixels, teto de mip de assets de textura |
| `texture_mip_bias` | `f32` | -4 a 4; deslocamento de LOD, não bytes |
| `texture_anisotropy` | `u8` | 1, 2, 4, 8, 16; 1 = desabilitado |
| `post_processing_enabled` | bool | master de pós-processamento |
| `bloom_enabled` | bool | habilita bloom quando master ativo |
| `ambient_occlusion_enabled` | bool | habilita AO quando master ativo |
| `tone_mapping` | enum | `none`, `reinhard`, `aces` |

Override não permite backend, versão de tabela ou nomes de presets personalizados. `vsync` e resolução ficam nos campos próprios. Regras do merge:

1. Carregar a tabela da distribuição e procurar o preset pelo nome do projeto.
2. Copiar os parâmetros concretos do preset.
3. Substituir somente os campos presentes em `overrides`; nunca fazer truthiness de `false`, `0` ou `none`.
4. Validar intervalos e invariantes da configuração resultante.
5. Validar capacidades antes de criar device/recursos GPU, exceto em headless.

Invariantes semânticas já propostas: `shadow_distance_m <= draw_distance_m`, mesmo quando sombras estão desativadas, para que reativação não herde configuração inválida. Parâmetros de sombra continuam armazenados quando sombras estão desativadas, sem alocação de mapas. Com pós-processamento desabilitado, bloom/AO/tone mapping ficam latentes e não geram passes; não são apagados ou reescritos. Buffers de apresentação/conversão de cor obrigatórios do backend não são efeitos de pós-processamento.

O item 3 deverá fixar algoritmo, recursos, demais parâmetros concretos e dependências de cada efeito. Até sua aprovação, esta interface de overrides não constitui promessa de suporte do renderer atual.

### 3.4 `scenes`

| Campo | Tipo | Obrigatório | Regra |
| --- | --- | --- | --- |
| `root` | caminho relativo de diretório | sim | diretório de cenas da autoria |
| `startup` | caminho relativo de arquivo | sim | extensão `.scene`, sensível a caixa; deve estar contido em `root` |

Ambos são relativos ao diretório do `.proj`: `root: "scenes"` e `startup: "scenes/Main.scene"`, **não** `startup: "Main.scene"`. Comparação de contenção é por segmentos e caminho real, nunca apenas prefixo textual. Formato interno da cena será especificado separadamente sobre o serializer do core.

### 3.5 `scripts`

| Campo | Tipo | Obrigatório | Regra / default |
| --- | --- | --- | --- |
| `cpp_root` | caminho de diretório | sim | fontes C++ do usuário, não código compilado automaticamente |
| `lua_root` | caminho de diretório | sim | scripts Lua; sem varredura para execução automática |
| `cpp_module` | `null` / `static` / `dynamic` | não | default `null` = sem gameplay C++ |
| `cpp_library` | caminho-base de artefato / `null` | não | default `null`; só permitido como string com `dynamic` |
| `lua_entry` | caminho de arquivo `.lua` / `null` | não | default `null` = sem orquestração Lua; contido em `lua_root` |

`cpp_module: "static"` exige gameplay correspondente previamente ligado ao Player, cuja identidade e ABI serão verificadas pelo contrato de build/módulo. `cpp_library` deve estar ausente ou `null`; o Runtime não compila fontes.

`cpp_module: "dynamic"` exige `cpp_library` não nulo. É caminho-base sem sufixo de SO: `build/gameplay` resolve para `build/gameplay.dll` (Windows), `build/gameplay.so` (Linux) ou `build/gameplay.dylib` (macOS), sem prefixo `lib` automático. O build deve produzir esses nomes. Somente `platform_ext` resolve sufixo/carrega biblioteca; nenhum caminho alternativo é procurado no PATH. O nome-base não termina em `.dll`, `.so` ou `.dylib`. A biblioteca deve permanecer contida na raiz do projeto, mas não necessariamente em `cpp_root`, que contém fontes.

A opção dinâmica define o modo de carga, **não** garante hot reload C++. Se faltarem migração e unload seguros, mudanças exigem reiniciar Play. Não há comandos de shell/build no `.proj` v1.

`lua_entry` é o único ponto inicial de Lua; dependências são carregadas pelos módulos permitidos sob `lua_root`. Políticas de API, chamadas protegidas e sandbox serão definidas com `gameplay_api`; gameplay não ganha acesso irrestrito por causa deste campo. Hot reload não é configurado pelo `.proj` v1: é recurso do modo de desenvolvimento, não obrigação de executar Lua em projeto sem entrypoint.

### 3.6 `assets` e `simulation`

| Campo | Tipo | Obrigatório | Regra |
| --- | --- | --- | --- |
| `assets.root` | caminho de diretório | sim | assets da autoria, relativo ao projeto |
| `simulation.fixed_tick_hz` | `u32` | sim | 1–1000 Hz; intervalo racional `1 / Hz`, não `f32` acumulado |
| `simulation.seed` | `u32` | sim | 0–4294967295; zero é seed válida, não sentinel |

Valores obrigatórios não têm default no parser. A UI de criação pode propor 60 Hz e seed 42, mas deve gravá-los no arquivo. Atraso/catch-up não muda essa taxa. Headless aplica a mesma simulação sem janela/GPU. Futuros overrides por CLI serão identificados no log de sessão e não regravam o projeto; não estão definidos por este schema.

## 4. Caminhos portáveis, acesso e fases de abertura

Todos os caminhos são strings relativas ao **diretório que contém o `.proj`**, com `/`, sem `/` inicial/final, segmentos vazios, `.` ou `..`. Não aceitam `\\`, `:`, controles, NUL, variáveis de ambiente, `~` como expansão, URL, drive ou UNC. São nomes literais, não comandos.

Para portabilidade Windows, segmentos também não contêm `< > " | ? *`, não terminam em ponto/espaço e não usam nomes de device reservados, sem distinção de caixa e inclusive antes de extensão: `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`, `COM¹/²/³`, `LPT¹/²/³`, `CONIN$`, `CONOUT$`. Nomes precisam estar em NFC; não se faz normalização silenciosa ao ler. Ferramentas de autoria evitam colisões de nomes Unicode/case e verificam caixa exata dos arquivos existentes mesmo em FS case-insensitive. Portabilidade plena depende também dos limites do filesystem/OS; erros são propagados.

Raízes são relativas e não podem ser o diretório `.`. Não precisam ter nomes convencionais nem ser mutuamente disjuntas. Referências externas, inclusive via symlink/junction, são recusadas. Para criação de arquivo inexistente, verificar o ancestral existente e a contenção do destino; operações de escrita devem impedir redirecionamento por links durante abertura/substituição onde a plataforma permitir. Isso protege os arquivos do projeto, não cria sandbox para código nativo arbitrário.

Há três fases diferentes:

1. **Documento válido:** parsing/tipos/versão, sem depender de existência de arquivos. Permite ao Editor apresentar configuração e diagnósticos de projeto incompleto.
2. **Projeto resolvido:** versão da engine/ABI, raízes existentes como diretórios, cena inicial existente, entrypoint Lua e biblioteca dinâmica existentes quando habilitados, contenção e leitura autorizada. Editor pode abrir documento válido com recursos ausentes em modo degradado, exibindo falhas; não declara a cena carregada e bloqueia Play até resolver. Não cria pastas automaticamente só por abrir.
3. **Execução pronta:** presets e capacidades aprovados, cena/assets/scripts efetivamente carregados e serviços do core inicializados. Só então `runtime.ready`. Runtime falha e retorna código não zero em qualquer erro; não continua com cena vazia de fallback.

Runtime não escreve `.proj` em nenhuma fase, nem em headless. O Editor só escreve por ação de usuário ou migração explicitamente confirmada; recursos ausentes não autorizam alterar caminhos.

## 5. Exemplos de variações válidas

O exemplo completo está em `docs/examples/EmptyGame.proj`. Os fragmentos seguintes substituem seções inteiras desse documento; não são arquivos `.proj` completos.

### Lua e gameplay C++ estático

```json
{
  "cpp_root": "scripts/cpp",
  "lua_root": "scripts/lua",
  "cpp_module": "static",
  "lua_entry": "scripts/lua/main.lua"
}
```

### Biblioteca dinâmica, sem Lua

```json
{
  "cpp_root": "scripts/cpp",
  "lua_root": "scripts/lua",
  "cpp_module": "dynamic",
  "cpp_library": "build/gameplay",
  "lua_entry": null
}
```

### Preset com overrides parciais

```json
{
  "graphics_preset": "high",
  "vsync": true,
  "initial_resolution": {"width": 1920, "height": 1080},
  "overrides": {
    "msaa_samples": 1,
    "shadows_enabled": false,
    "draw_distance_m": 1000
  }
}
```

Os exemplos só comprovam intenção estrutural. Compatibilidade com os parâmetros restantes de `high` será verificada quando a tabela do item 3 existir. Nenhuma configuração força criação de recursos antes da validação completa.

## 6. Compatibilidade, migração e gravação

- v1 aceita exclusivamente `schema_version: 1`. Valor ausente, negativo, fracionário, string ou futuro é recusado; tipos inválidos são diferenciados de versão inteira não suportada.
- Schema do projeto, versão do jogo, versão da engine, ABI C e versão da cena são eixos distintos. Atualizar um não migra automaticamente os outros.
- Mesmo campos novos opcionais exigem nova versão de schema, pois v1 rejeita propriedades desconhecidas. Correções editoriais que não alteram aceitação/semântica não mudam versão.
- Editor pode oferecer migração explícita com preview, backup e gravação atômica; Runtime nunca migra. O projeto legado em `test_project/TestProject.proj` permanece intacto nesta entrega.
- Migração legada não inventará UUID, data original, seed, raízes ou mapping de presets sem decisão explícita. Metadados novos devem ser gerados/confirmados no fluxo de migração; qualidade legada só pode ser mapeada após validar a tabela. A migração não será implementada como “carregar defaults”.
- Serializer ordena campos como neste documento/exemplo e overrides como na tabela, usa dois espaços, LF e newline final. Mantém Unicode válido sem ASCII escaping obrigatório. Inteiros sem fração; floats usam representação decimal de round-trip do `f32` normalizado, com `-0` canônico como `0`. Não reordena nem altera caminhos silenciosamente.
- Opcionais de scripts em `null` são omitidos; `overrides` vazio é omitido. Portanto ler→escrever preserva valores normalizados, não bytes/whitespace ou presença de defaults equivalentes.
- Salvamento mantém `uuid` e `created_at`, verifica conflito com o arquivo lido e usa backup `<arquivo.proj>.bak` com a última versão anterior íntegra. Atualização de backup e substituição seguem o protocolo/falhas do ADR; salvar sem mudanças semânticas não precisa regravar. Dois escritores concorrentes não são suportados.
- SemVer é validado semanticamente, não apenas por pattern; `format: date-time` exige validador habilitado e checagem estrita do perfil UTC acima. Normalizações não autorizam aceitar metadados inválidos.

## 7. Diagnósticos esperados

Os identificadores seguintes são proposta de categorias estáveis para `fields.code` no log, não números finais de exit code. Incluem arquivo, JSON Pointer quando aplicável e mensagem humana; não registram conteúdo ilimitado do arquivo.

| Código | Exemplo |
| --- | --- |
| `project.invalid_json` | trailing comma, UTF-8 inválido, duplicata (`/renderer/vsync`) |
| `project.limit_exceeded` | arquivo > 1 MiB ou profundidade > 16 |
| `project.schema_version_missing` | campo ausente; informar versões suportadas: `[1]` |
| `project.schema_version_unsupported` | recebida `2`, suportadas `[1]`; instrução para engine compatível |
| `project.invalid_field` | tipo, campo obrigatório, chave desconhecida, enum ou intervalo inválido |
| `project.invalid_path` | `../assets`, caminho absoluto, caixa errada ou symlink externo |
| `project.invalid_configuration` | sombra além da distância de draw após merge |
| `project.resource_missing` | cena, raiz, entrypoint ou módulo ausente |
| `project.engine_mismatch` | distribuição/ABI diferente da exigida |
| `project.graphics_unsupported` | backend ou configuração indisponível no modo gráfico |
| `project.write_conflict` | arquivo alterado externamente desde a leitura |
| `project.write_failed` | permissão, sync ou replace falhou; original não é descartado |

Erro humano ilustrativo: `Projeto incompatível: schema_version=2; este executável suporta [1]. Abra com uma versão compatível da engine. Arquivo: /jogo/Game.proj; campo: /schema_version.` No protocolo, a mensagem é uma string JSON escapada do envelope ADR-001, não saída de texto avulso.

## 8. Matriz de contrato para a implementação futura

| Caso | Resultado exigido |
| --- | --- |
| Editor escreve documento com todos os campos → Runtime lê | igualdade de todos os valores normalizados, inclusive overrides e metadados |
| Opcionais ausentes / explicitamente `null`; overrides ausente / `{}` | modelos equivalentes e serialização canônica idêntica |
| `false`, seed zero, MSAA 1, bias zero | preservar valores, sem substituir por defaults |
| Unicode, caminho com espaço, execução em outro CWD | leitura idêntica, resolução relativa ao `.proj` |
| Limites mínimo/máximo e reais normalizados | aceitar limites; rejeitar overflow, não finito e underflow inválido |
| Versão ausente/futura, desconhecidos, duplicatas, JSON inválido | erro explícito; não executar core/GPU |
| Static/dynamic/disabled e combinações inválidas | aplicar dependências de campos sem carregar módulo no parsing |
| Traversal, symlink/junction, device name e caixa incorreta | rejeitar com diagnóstico de caminho |
| Runtime gráfico e headless | mesmo modelo/projeto e simulação; só gráfico exige capacidades GPU |
| Mudança externa antes de salvar e falhas de escrita | conflito/erro; original ou backup íntegro recuperável |
| Runtime executa projeto válido ou inválido | hash e mtime do `.proj` permanecem inalterados |
| Projetos legados | recusar sem migração explícita; não sobrescrever |

Testes do parser serão Zig; validação JSON Schema será oráculo auxiliar de contrato, não dependência de execução dos binários. O conjunto de strings/paths semanticamente inválidos inclui casos que passam na validação estrutural: isso é esperado e será testado explicitamente.

## 9. Limite desta entrega e próximo portão

Foram definidos schema v1, exemplo e contrato semântico. Não foram implementados parser Zig, migração, serializer, engine API, build, renderer, gameplay ou CI. Validações documentais executadas nesta etapa não equivalem a testes Editor→Runtime.

### Verificação documental executada em 2026-11-01

JSON Schema validado contra o metaschema Draft 2020-12 com Python `jsonschema[format]`, em ambiente virtual isolado, sem dependência adicionada ao projeto. Foram exercitados **26 casos estruturais**, todos com resultado esperado: exemplo completo, scripts opcionais e modos C++, versões, UUID, SemVer, data impossível, limites de seed/tick, overrides e caminhos lexicamente inválidos. O format-checker de datas foi explicitamente habilitado; sem seu pacote opcional, alguns validadores podem ignorar `format`. As restrições semânticas deste documento permanecem a implementar/testar no módulo Zig.

Após aprovação deste item, o próximo passo é o **item 3: schema completo de `presets.zon`**, incluindo tabela low/medium/high e todos os parâmetros concretos consumidos pelo renderer. Somente após aprovação dos dois schemas serão iniciados código e testes dos executáveis. P02/P03 foram concluídas com a aprovação dos dois schemas; código incremental dos contratos está em `shared/`. As evidências desta seção documental não substituem o relatório de implementação em `APPLICATION_PROGRESS.md`.
