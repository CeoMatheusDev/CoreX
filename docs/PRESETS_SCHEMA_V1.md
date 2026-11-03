# Contrato de `presets.zon` v1 — aprovado (item 3)

**Estado:** aprovado pelo usuário em 2026-11-01, incluindo os valores da tabela. ADR-001 e schema `.proj` v1 também aprovados. A implementação incremental dos contratos iniciou em `shared/`; isso não implica renderer GPU ou executáveis já implementados.

## 1. Escopo, autoridade e justificativas

- Tabela completa: [examples/presets.zon](examples/presets.zon).
- Projeto consumidor: [PROJECT_SCHEMA_V1.md](PROJECT_SCHEMA_V1.md) e [schemas/project-v1.schema.json](schemas/project-v1.schema.json).
- Decisões gerais: [ADR-001](ADR-001-editor-runtime.md), especialmente seções 4, 7 e 13.

Este documento é o schema normativo ZON: campos, tipos, intervalos, invariantes, versões e aplicação. Não é JSON Schema disfarçado, nem código Zig executável. A tabela é dado estático de distribuição. Seu conteúdo será carregado pelo módulo compartilhado, sem avaliar código nem aceitar imports, chamadas, caminhos ou ponteiros.

O contrato define **todos os parâmetros de qualidade selecionáveis por preset nesta camada de aplicação v1**. Não pretende substituir configurações de materiais, luzes/câmeras da cena, budgets internos, shaders ou toda a implementação de um renderer AAA. Esses pertencem ao core e ao conteúdo. O renderer atual inspecionado usa backend null e não consome estes parâmetros; oferecer sua implementação real é dependência P05 do ADR, não trabalho ocultamente concluído nesta entrega.

Justificativas complementares:

1. **Dados completos, sem herança:** cada preset contém os mesmos 27 campos obrigatórios. Reduz duplicação lógica e elimina dependência de ordem/defaults. Duplicação de alguns números é aceita em troca de inspeção direta.
2. **Formato plano:** os 13 overrides aprovados do `.proj` mapeiam diretamente por nome/tipo. Os outros 14 parâmetros são internos à tabela de distribuição, sem ampliar o schema do projeto.
3. **Algoritmos estáveis no v1:** CSM/PCF, SSAO espacial e bloom em pirâmide; sem TAA, SSR, ray tracing, resolução dinâmica, autoexposure ou histórico temporal implícito. Isso reduz dependências e permite definir memória e trabalho a partir dos dados. Não se promete implementar algoritmos ausentes no core.
4. **Qualidade e custo previsíveis:** low desliga sombras e pós; medium habilita efeitos com budgets menores; high aumenta resolução/amostras/distância. São valores iniciais de produto, não afirmações de FPS ou budgets medidos.
5. **MSAA obrigatório quando solicitado:** sem fallback para outro antialiasing. O renderer deve suportar o número exato para os formatos de attachment usados, ou recusar a configuração.
6. **Sem novos controles do usuário nesta etapa:** mantém-se integralmente a allowlist e os limites aprovados de overrides. Novos parâmetros públicos exigirão revisão de schema, não abertura de um mapa arbitrário.

## 2. Estrutura e tipos

Raiz ZON anônima `.{ ... }`, UTF-8 sem BOM. Objetos fechados; desconhecidos, duplicatas, ausências e tipos errados são erros. Sem strings multilinha, `null`, arrays, comentários ou constantes especiais nesta tabela v1. Floats devem ser finitos. Nomes de campos e enums são ASCII, sensíveis a caixa. Reordenação dos campos não muda semântica; a distribuição mantém a ordem do exemplo para facilitar diffs.

| Campo raiz | Tipo | Regra |
| --- | --- | --- |
| `schema_version` | `u32` | exatamente 1; versão do envelope/gramática de dados |
| `renderer_contract_version` | `u32` | exatamente 1; identidade semântica dos parâmetros do renderer |
| `table_revision` | string SemVer | revisão da tabela, `1.0.0` nesta proposta; até 128 caracteres |
| `presets` | objeto fechado | exatamente `low`, `medium`, `high`, todos obrigatórios |

Cada membro de `presets` é um `GraphicsParametersV1` completo, com os 27 campos abaixo. Enums ZON usam `.none`, `.reinhard`, `.aces`; o `.proj` usa strings equivalentes. A conversão explícita pertence ao módulo compartilhado, não à ABI nem ao renderer.

Tipos nesta documentação são tipos internos conceituais, não layout público C. Toda passagem para C23/core usará DTO com tradução e testes de layout conforme ADR. Inteiros não são lidos por cast truncante; floats são normalizados para `f32`, rejeitando overflow, não finito e underflow para zero em campos estritamente positivos.

### Limites do arquivo e carregamento

- Tamanho máximo 64 KiB; profundidade máxima 4 containers, contando raiz como 1.
- Até 128 membros totais de objetos; string decodificada de até 128 bytes.
- Literal numérico de até 64 bytes; inteiros não negativos em decimal; reais decimais com fração e/ou expoente. Sem hex, separadores `_`, `nan` ou `inf` neste perfil restrito.
- O formato final deve ser validado por parser ZON compatível com o toolchain fixado. Se as APIs Zig 0.17.0 não oferecerem detecção de duplicatas/perfil estrito, a camada de validação deve fazê-lo, não aceitar o arquivo silenciosamente.
- Nenhuma alocação/leitura/parsing da tabela acontece no frame. Carregar uma vez por sessão antes de GPU; mudanças exigem reinício controlado.

## 3. Parâmetros concretos

Todos são obrigatórios e sem defaults de leitura, mesmo se o efeito estiver desabilitado.

### 3.1 Sombras direcionais: CSM com PCF

| Campo | Tipo | Limite / semântica | Override `.proj` |
| --- | --- | --- | --- |
| `shadows_enabled` | bool | habilita sombras direcionais dinâmicas | sim |
| `shadow_map_size` | `u32` | 256, 512, 1024, 2048, 4096, 8192; lado do mapa em pixels por cascata | sim |
| `shadow_cascades` | `u8` | 1–4; quantidade de camadas de CSM | sim |
| `shadow_distance_m` | `f32` | `(0, 100000]` metros; alcance máximo a partir da câmera | sim |
| `shadow_depth_bias` | `f32` | `[0, 0.01]`; bias constante em profundidade normalizada | não |
| `shadow_slope_bias` | `f32` | `[0, 8]`; fator adimensional do termo de inclinação | não |
| `shadow_normal_offset_m` | `f32` | `[0, 1]` metros; deslocamento do receiver na direção da normal | não |
| `shadow_cascade_split_lambda` | `f32` | `[0, 1]`; interpolação entre partição uniforme (0) e logarítmica (1) | não |
| `shadow_pcf_kernel` | `u8` | 1, 3 ou 5; lado do kernel PCF em texels, respectivamente 1/9/25 comparações | não |

Um conjunto CSM é destinado à luz direcional primária declarada na cena. Sombras de múltiplas luzes, point/spot e seleção da luz primária não são implicitamente habilitadas por este contrato; pertencem ao contrato de iluminação do core. Sem luz elegível, não há passes de sombra, e os valores permanecem registrados.

O core traduz bias normalizado para suas convenções de depth/reversed-Z sem reinterpretá-lo como bias específico de API. Distância efetiva de cobertura é a interseção com o frustum da câmera, não modificação do parâmetro salvo. Câmera com near/far inválidos é erro da cena. O split log/uniform usa os near/far válidos dessa interseção. Ausência de interseção dispensa o passe. Filtragem não pode mudar o kernel solicitado por conta do nome do preset.

### 3.2 Antialiasing, visibilidade e texturas

| Campo | Tipo | Limite / semântica | Override |
| --- | --- | --- | --- |
| `msaa_samples` | `u8` | 1, 2, 4, 8; 1 significa sem MSAA | sim |
| `draw_distance_m` | `f32` | `(0, 100000]` metros; limite de culling da geometria de cena | sim |
| `texture_max_dimension` | `u32` | 256, 512, 1024, 2048, 4096, 8192, 16384; maior dimensão de mip residente de textura de asset | sim |
| `texture_mip_bias` | `f32` | `[-4, 4]`; bias adicional de LOD sobre mips residentes | sim |
| `texture_anisotropy` | `u8` | 1, 2, 4, 8, 16; 1 desabilita anisotropia | sim |

Texturas de asset maiores que o teto começam no primeiro mip cuja maior dimensão não exceda o teto; texturas menores não são ampliadas. O bias atua depois dessa escolha e é limitado ao intervalo de mips realmente residentes pelo sampler. Isso é regra do algoritmo, não downgrade negociado. Assets sem mips necessários devem ser preparados pelo pipeline de assets ou gerar erro de carregamento, não fabricar trabalho de importação no frame.

Esse teto não limita shadow maps, framebuffer, font atlas da UI ou render targets de pós; cada um tem contrato próprio. Culling considera bounds dos objetos e frustum, sem impor desaparecimento por distância ao sky/UI. Detalhamento de materiais/LOD geométrico não é escolhido pelo preset v1.

### 3.3 Pós-processamento, bloom, AO e tone mapping

| Campo | Tipo | Limite / semântica | Override |
| --- | --- | --- | --- |
| `post_processing_enabled` | bool | master dos efeitos deste grupo | sim |
| `bloom_enabled` | bool | habilita bloom se master ativo | sim |
| `bloom_threshold` | `f32` | `[0, 64]`; luminância linear exposta antes do tone mapping | não |
| `bloom_soft_knee` | `f32` | `[0, 1]`; fração do threshold para transição suave, 0 = corte duro | não |
| `bloom_intensity` | `f32` | `[0, 2]`; ganho adimensional da contribuição do bloom | não |
| `bloom_levels` | `u8` | 1–8; máximo de níveis da pirâmide | não |
| `ambient_occlusion_enabled` | bool | habilita SSAO se master ativo | sim |
| `ao_radius_m` | `f32` | `(0, 10]` metros; raio em espaço de visão | não |
| `ao_depth_bias_m` | `f32` | `[0, 0.5]` metros; evita auto-oclusão | não |
| `ao_intensity` | `f32` | `[0, 4]`; expoente aplicado ao fator de visibilidade `[0,1]` | não |
| `ao_samples` | `u8` | 8, 16, 32 ou 64; amostras por pixel | não |
| `tone_mapping` | enum | `none`, `reinhard`, `aces` | sim |
| `exposure_ev` | `f32` | `[-16, 16]`; ganho linear `2^EV` quando master ativo | não |

SSAO opera em meia resolução por eixo, arredondada para cima, usando depth/normais resolvidos e kernel espacial determinístico, sem acumulação temporal nem RNG de gameplay. O blur bilateral usa raio fixo de 2 texels (5 taps separáveis por eixo) definido pelo contrato v1. AO modula iluminação indireta, não o canal emissivo nem UI. O core deve permitir essa composição; aplicá-lo indiscriminadamente à cor final não satisfaz o contrato.

Bloom extrai threshold com soft knee, constrói pirâmide de downsample/upsample por fator 2 com filtro tent 3×3, e combina pelo ganho. O primeiro nível tem metade da resolução HDR por eixo (ceil). A cadeia termina ao atingir 1×1 ou `bloom_levels`, o que ocorrer primeiro; essa dependência da resolução faz parte do contrato, não fallback de capacidade. `threshold=0` ou `soft_knee=0` usa caminho definido sem divisão por zero.

Ordem lógica: visibilidade/geom → iluminação com AO na parcela indireta → resolve MSAA HDR → exposição → bloom → tone mapping → conversão de saída → UI. Depth/normais devem estar disponíveis para AO por resolve ou prepass com custo declarado pelo core. Não se pressupõe que resolve de depth seja recurso portátil obrigatório: prepass é uma estratégia de implementação válida, sem reduzir amostras solicitadas na cor.

Tone mapping em RGB linear não negativo, após exposição/bloom:

- `none`: identidade, sem compressão de highlights.
- `reinhard`: por canal, `x / (1 + x)`.
- `aces`: aproximação fitted por canal `clamp((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14), 0, 1)`; não é implementação completa de ACES/OCIO.

Cálculos intermediários devem evitar overflow/não finitos; cor de entrada não finita é diagnóstico do renderer/conteúdo, não valor de preset. A saída v1 é SDR sRGB: codificação sRGB acontece exatamente uma vez; targets sRGB podem fazê-la por hardware. `none` pode saturar highlights na saída SDR. UI do Editor é composta fora da exposição/tone mapping do jogo, para não alterar aparência dos painéis.

Com master desligado, todos esses efeitos e exposição ficam latentes; não geram passes/recursos de efeito. Conversão de saída necessária à apresentação permanece. Ativar master sem habilitar bloom/AO não os liga implicitamente. Flags inativas não apagam parâmetros nem invalidam valores que seriam válidos se ativados.

## 4. Tabela completa e valores de referência

O arquivo [presets.zon](examples/presets.zon) contém o envelope e **81 valores concretos** (27 por preset), sem herança. Resumo dos principais eixos:

| Parâmetro | low | medium | high |
| --- | --- | --- | --- |
| Sombras | desativadas | ativadas | ativadas |
| Mapa / cascatas | 512 / 1 (latente) | 2048 / 2 | 4096 / 4 |
| Distância de sombras | 40 m | 100 m | 200 m |
| PCF | 1×1 | 3×3 | 5×5 |
| MSAA | 1 | 2 | 4 |
| Draw distance | 250 m | 500 m | 1000 m |
| Teto de textura | 1024 | 2048 | 4096 |
| Mip bias / anisotropia | 1 / 1 | 0 / 4 | 0 / 16 |
| Master pós | desligado | ligado | ligado |
| Bloom / níveis | desligado / 3 | ligado / 4 | ligado / 5 |
| SSAO / amostras | desligado / 8 | ligado / 16 | ligado / 32 |
| Tone mapping / exposição | none / 0 EV | aces / 0 EV | aces / 0 EV |

Por exemplo, high aloca potencialmente 4 camadas de 4096² para CSM, antes de considerar câmera/luz; isso pode ter custo significativo. Nenhum nome promete desempenho numa classe de hardware. Responsável por renderer/performance deverá medir os custos antes de estabilizar a distribuição. Alterações de números posteriores exigem nova revisão e hash de tabela, nunca modificação silenciosa da mesma release.

## 5. Resolução, invariantes e capacidades antes do device

### 5.1 Sequência obrigatória

1. Validar `.proj` e compatibilidade da engine.
2. Abrir tabela única da distribuição e verificar envelope, limites e identidade.
3. Validar **todos** os presets completos, mesmo os não selecionados; tabela corrompida não é parcialmente utilizável.
4. Procurar pelo nome exato em `presets`; copiar os 27 valores para configuração resolvida.
5. Aplicar somente os overrides presentes do `.proj`; preservar `false`, zero e `.none`.
6. Revalidar tipos/intervalos e invariantes, incluindo após normalização `f32`.
7. Incorporar backend, vsync e resolução inicial do `.proj` à requisição de inicialização; eles não vêm da tabela.
8. Modo gráfico: consultar capacidades sem device/recursos GPU e aprovar o plano de recursos. Modo headless: pular GPU, mantendo a configuração resolvida observável.
9. Somente após aprovação, criar device, swapchain, pools e recursos. Se limites finais da surface exigirem ajuste imposto pela janela, registrar conforme contrato do projeto; nunca mudar preset por conta disso.

Não haverá `switch (preset)` no renderer. Ele recebe parâmetros concretos, sem precisar conhecer a string `low/medium/high`. O nome/revisão podem existir nos logs da aplicação, não como mecanismo de escolha de passes ocultos.

### 5.2 Invariantes de dados

- `shadow_distance_m <= draw_distance_m` em todo preset e após overrides, inclusive com sombras desabilitadas.
- `ao_depth_bias_m < ao_radius_m`, inclusive quando AO estiver latente.
- Tipos, ranges e enumerações das tabelas acima são obrigatórios sem defaults.
- Parâmetros inativos permanecem sintaticamente/semanticamente válidos; não são zeros sentinela.
- Dimensões de imagens e multiplicações de bytes são calculadas com aritmética checada em `u64`/tipo de tamanho validado. Overflow ou orçamento insuficiente gera erro explícito.

### 5.3 Plano de recursos e suporte

O contrato v1 usa cor HDR linear `RGBA16F`, depth de cena `D32F`, sombras `D32F` e AO `R8_UNORM`. Bloom usa `RGBA16F`. O core pode trocar representação interna por equivalente comprovada sem perda de precisão/semântica, mas não negociar MSAA, resolução ou efeitos para baixo. Formato indisponível sem equivalente validado gera erro. Formato de normais e mecanismo de preservação de iluminação indireta são escolhas internas do core, documentadas no plano de recursos.

Verificar antes de device, quando o efeito estiver ativo/for necessário:

- Limites de dimensões de attachments, shadow map layers e textura; contagem de amostras exata nos formatos de cor/profundidade em uso.
- Anisotropia solicitada e filtragem/sampling dos formatos; comparação PCF pode ser shader manual se hardware não oferecer comparação filtrada equivalente.
- Attachments de leitura/escrita, resolves e estratégias necessárias a HDR/MSAA/AO/bloom.
- Modo de apresentação compatível com vsync pretendido e resolução de surface; ausência é diagnóstico, não mudança de backend.
- Budgets de memória/pools e capacidades de features dos shaders efetivamente escolhidos.

Valores latentes não exigem suporte GPU até serem ativados. Exemplo: low mantém `shadow_map_size=512` válido sem exigir ou alocar um mapa de sombras quando o efeito está desligado. Limite de textura de assets é um teto: não obriga carregar texturas desse tamanho se não existem no jogo; o plano deve verificar os recursos reais solicitados. Não se chama essa ausência de alocação de downgrade.

Se o backend só consegue obter uma informação indispensável criando device, a integração não satisfaz a sequência aprovada: deve reportar limitação de capacidade pré-device, a resolver pelo responsável do core. Não criar device provisório para contornar o portão.

## 6. Distribuição, compatibilidade e logging

O build/distribuição fixa uma única tabela de presets para a mesma versão de engine dos dois executáveis. Destino proposto: `share/corex/presets.zon` relativo à raiz da distribuição, resolvida por manifesto/executable path, nunca CWD ou pasta do projeto. Cada binário poderá ser instalado separadamente, mas deve levar a mesma tabela validada.

Manifesto de distribuição inclui versão exata da engine, `renderer_contract_version`, `table_revision` e SHA-256 dos bytes do arquivo. Esse manifesto é dependência de empacotamento das aplicações, não funcionalidade existente do core. O build verifica e empacota sua cópia; instalação incompleta, divergência de hash ou ausência da tabela é erro. Não baixar tabela pela rede nem gerar fallback embutido no renderer. Hash garante identidade contra o manifesto, não autenticidade se um atacante substituir ambos; assinatura/updater pertencem ao Hub e ficam fora do escopo.

Compatibilidade tem três eixos:

- `schema_version`: mudar formato, campos obrigatórios ou gramática exige nova versão.
- `renderer_contract_version`: mudar unidade, algoritmo, significado ou regra de composição exige nova versão, mesmo se os campos parecerem iguais.
- `table_revision`: mudar somente valores dentro do contrato exige nova revisão SemVer e novo hash; a política de release da engine associa exatamente essa tabela à versão exigida pelo projeto.

No v1 os dois inteiros devem ser 1; não há tentativa automática de downgrade. A compatibilidade exata da distribuição é verificada adicionalmente, inclusive em headless. Tabela em formato futuro ou com revisão/hash não empacotados é erro. Editor não edita essa tabela por projeto: escreve somente overrides autorizados no `.proj`.

A aplicação registra `graphics.config_resolved`, usando o envelope JSON lines do ADR, com nome do preset, revisão/hash da tabela, versão do contrato, modo headless, overrides e os parâmetros concretos normalizados. Isso permite auditar igualdade entre Editor/Runtime sem inspecionar GPU. Em gráfico, `graphics.device_created` só é emitido após resolução e aprovação de capacidades. O log não é prova suficiente sozinho: testes devem observar hooks de inicialização e contadores de criação de recursos.

Categorias propostas de erro: `presets.invalid_syntax`, `presets.limit_exceeded`, `presets.version_unsupported`, `presets.identity_mismatch`, `presets.invalid_parameter`, `presets.invalid_configuration`, `presets.not_found`. Falhas de capacidade gráfica usam `project.graphics_unsupported` ou categoria equivalente do core com contexto; logs distinguem dados inválidos de hardware incompatível.

## 7. Contratos automatizados planejados

| Teste | Resultado esperado |
| --- | --- |
| Tabela completa low/medium/high | 27 campos cada, tipos e valores exatos da fixture; 81 valores no total |
| Editor/Runtime resolvem mesmo `.proj`/tabela | configuração normalizada idêntica, incluindo valores latentes e metadados |
| Override parcial/falso/zero/none | apenas os campos presentes substituídos; sem truthiness |
| Shadow distance menor/igual/maior que draw | dois primeiros aceitos, último recusado |
| AO bias igual/maior que raio | erro mesmo com efeito desabilitado |
| Versão futura, campo extra, duplicado/ausente | erro, sem criar device |
| Enum, NaN/Inf, overflow e real positivo virando zero | rejeição explícita |
| Mapa/preset corrompido não selecionado | tabela inteira recusada |
| Hash/revisão divergente, arquivo ausente | não procurar fallback em CWD/projeto |
| Backend fake com contador de criação | resolução e consulta antes do primeiro device/attachment; falha mantém contador zero |
| Headless | resolve tabela e overrides; zero device, janela, swapchain e attachments |
| Low com pós/sombras desligados | zero recursos desses efeitos, valores latentes preservados |
| Master desligado, bloom/AO flags verdadeiras | nenhum passe de efeito/exposição; não apagar flags |
| MSAA/anisotropia sem suporte | falha explícita, nunca troca de preset ou clamp silencioso |
| Snapshot de configuração/log | remover relógio/session; comparar todos os 27 parâmetros concretos |
| Renderer GPU real | valida ordem dos passes, recursos e aparência; teste null não substitui isso |

Testes de ZON, contratos de inicialização e resolução serão implementados em Zig após aprovação. Testes de GPU dependem P05/P13. Números de custo e qualidade visual ainda precisam ser medidos; não são inferidos do arquivo.

## 8. Verificação documental executada

Em 2026-11-01 foi realizada auditoria dos literais da fixture: três presets com 27 campos cada (81 valores), sem repetição de campo, com tipos, enumerações, intervalos, conversão finita para `f32` e invariantes atendidos. Os 13 overrides do JSON Schema aprovado continuam presentes e são subconjunto exato permitido do contrato. Todos os 27 nomes têm entrada nas tabelas normativas deste documento.

A auditoria também verificou merge preservando `false`/zero/`none` e 15 mutações inválidas (limites, amostras, tipos, não finito, campo ausente e campo desconhecido). Os resultados foram os esperados. Essa verificação usou leitura restrita de literais da fixture, **não um parser ZON de produção**. Sintaxe pela ferramenta Zig, consumo pelo renderer, criação de GPU, processo filho e testes Editor→Runtime não foram executados.

## 9. Portão de aprovação (cumprido)

O contrato documental e seus dados foram aprovados. A implementação incremental dos contratos está em `shared/`, sem alterações no core/executáveis ou no schema público `.proj`. Ficaram liberados: item 4 (árvore proposta completa) e implementação progressiva dos itens 5–8, preservando bloqueios de toolchain, renderer/reflexão e plataforma já declarados no ADR.

O primeiro passo de código será verificar toolchain/dependências e implementar contratos compartilhados testáveis antes de apresentar janela/viewport como funcionais. Se Zig 0.17.0 ou alguma capacidade requerida não estiver disponível, a limitação será relatada com evidência, sem substituição silenciosa de stack ou simulação de recurso ausente.
