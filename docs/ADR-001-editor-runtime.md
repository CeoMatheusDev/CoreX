> **Escopo atualizado:** ADR-003 prevalece: Windows/Linux, 3D + UI/Canvas, sem cena 2D; Vulkan/OpenGL e D3D11/D3D12 no Windows. Referências antigas a macOS/Metal/WebGPU são históricas.

# ADR-001 — Aplicações Editor e Runtime do CoreX

- **Data:** 2026-11-01
- **Status:** aprovado pelo usuário em 2026-11-01; schema `.proj` (item 2) também aprovado; `presets.zon` (item 3) ainda sujeito a aprovação.
- **Escopo:** camada de aplicação; não implementa Hub nem subsistemas do core.
- **Entrega original:** item 1. Portões dos itens 2 e 3 já cumpridos; progresso incremental em `APPLICATION_PROGRESS.md` e refinamentos do bootstrap em ADR-002.
- **Responsável pela proposta:** implementação das aplicações Editor/Runtime.

## 1. Contexto e evidências locais

O objetivo é oferecer dois executáveis nativos independentes: autoria no Editor e execução do jogo no Runtime. Ambos usam a mesma biblioteca core, Zigway para plataforma e os mesmos contratos de projeto. ZyntraUI é o toolkit oficial do Editor e pode ser disponibilizado ao jogo, sem UI de autoria no Runtime.

A inspeção deste checkout encontrou:

- `build.zig` produz atualmente um único `CoreXEngine`.
- `build.zig.zon` referencia Zigway `v0.1.0-alpha.4` e ZyntraUI `v1.44.1`; isso não comprova a compatibilidade dessas versões com o toolchain exigido.
- `src/project/loader.zig` ignora o caminho recebido e retorna valores fixos. Não é um parser de projeto funcional.
- `test_project/TestProject.proj` é JSON legado, sem `schema_version`, e não atende ao contrato solicitado.
- `src/graphics/renderer/render.zig` utiliza `NullBackend`. Não foi identificada ali implementação de renderer GPU real.
- `src/serialization/serializer.zig` possui serialização incompleta; `src/scene/scene.zig` não oferece o contrato de reflexão necessário à edição de componentes.
- `src/jobs/job_system.zig` contém execução sequencial e crescimento dinâmico da fila; não demonstra o contrato de jobs determinísticos e sem alocações por frame.
- Existem wrappers de plataforma, UI e scripting; sua presença não comprova as capacidades de produção exigidas.

O executável `zig` não foi encontrado no PATH durante esta inspeção. Não foram executados builds ou testes, nem validadas APIs upstream. As alegações históricas dos READMEs não substituem testes atuais. Zig 0.17.0 permanece requisito, mas sua distribuição, APIs e compatibilidade deverão ser verificadas antes da implementação; nenhuma versão alternativa será adotada silenciosamente.

**Consequência:** este ADR define interfaces requeridas e critérios de aceitação, não declara os subsistemas faltantes implementados. Backend null não será apresentado como renderer real.

## 2. Decisão: fronteiras e responsabilidades

```text
Editor (processo A)                      Runtime (processo B)
  autoria, inspeção, código                execução do jogo
  ZyntraUI + Zigway                        Zigway; UI do jogo opcional
         |                                         |
         +--- módulos compartilhados de aplicação -+
              projeto, presets, CLI, logs,
              paths e adaptadores do core
         |                                         |
         +--- mesma versão da biblioteca core -----+
              instâncias e memória independentes

A → B: criação de processo + argumentos
A ↔ B: arquivos versionados; saída JSON lines de B → A
```

“Mesma biblioteca” significa a mesma versão e ABI, não uma instância compartilhada. O core é ligado estaticamente por padrão, reduzindo problemas de implantação e resolução de bibliotecas. Linkagem dinâmica pode ser oferecida com verificação de ABI e identidade da versão. Cada aplicação tem seu `build.zig`, artefato, testes e ciclo de build independentes; um agregador na raiz poderá apenas coordená-los.

**Editor:** documentos de autoria, comandos de edição e undo/redo, seleção/gizmos, visualização ECS, inspetor orientado pela reflexão, content browser, edição textual simples, configuração do projeto, gravação e supervisão de Play. Alterações de cena são transações, não mutações improvisadas pelo toolkit.

**Runtime:** carrega projeto, cena, assets e gameplay; executa simulação e renderização; faz hot reload Lua de desenvolvimento; registra eventos. Nunca grava `.proj`, cenas de autoria ou assets. Saves do jogo e logs em disco, se necessários, usam diretórios próprios, não os arquivos-fonte.

**Core:** renderer/device, ECS, reflexão e serialização de componentes, assets, jobs, áudio e demais serviços da engine. As aplicações chamam esses serviços; não reimplementam renderer, ECS ou reflexão.

**Compartilhamento:** código-fonte de contratos e adaptadores, nunca processo, heap, ponteiros ou estado mutável. O Runtime não depende dos painéis do Editor. A biblioteca ZyntraUI é uma dependência comum disponível, não uma razão para compilar toda a UI de autoria no Player.

**Alternativas descartadas:** Play dentro do Editor (compartilha falhas e estado); Hub incorporado (fora do escopo); IPC binário, sockets e memória compartilhada (contrariam o contrato). A separação custa inicialização de outro processo, compensada por isolamento e fidelidade ao jogo distribuído.

## 3. Decisão: `.proj` em JSON estrito e módulo único

**Escolha:** JSON UTF-8, versionado por `schema_version` inteiro, com serialização canônica legível. JSON favorece ferramentas externas, validação independente da versão do compilador, interoperabilidade e diffs conhecidos. O formato legado já é JSON, mas não terá compatibilidade implícita. ZON permitiria tipos Zig mais naturais e comentários; foi descartado para projetos de usuário por acoplar tooling e sintaxe ao ecossistema Zig.

Um módulo Zig único fornece leitura limitada, validação estrutural/semântica, modelo tipado com ownership explícito e serialização. Editor e Runtime importam exatamente o mesmo módulo. O serializer existe no módulo compartilhado, mas somente o Editor o chama no fluxo de aplicação.

Regras arquiteturais a detalhar no item 2:

- Leitura primeiro verifica versão, depois valida o corpo contra a versão suportada. Versão ausente, incompatível ou futura causa erro claro, nunca defaults silenciosos.
- v1 será fechado: propriedades desconhecidas e chaves duplicadas são erros. Evoluções do contrato exigem versão e migração explícita; sem interpretar apenas parte de um projeto futuro.
- Campos obrigatórios não recebem defaults ocultos. Valores opcionais e limites terão defaults documentados e idênticos nos dois consumidores.
- Caminhos portáveis são relativos ao diretório do `.proj`, não ao diretório de trabalho. Serão normalizados, com verificação de contenção inclusive por links simbólicos; raízes externas não são aceitas em v1. O projeto é tratado como entrada não confiável para parsing, sem prometer sandbox de código nativo.
- Erros identificam arquivo, campo e causa, com localização quando o parser permitir. Limites de bytes, profundidade e coleções impedem consumo ilimitado.
- Migração do arquivo legado é ação explícita do Editor, com confirmação e backup; Runtime não migra nem regrava.

**Escrita do Editor:** validar o documento novo; verificar se o original mudou desde a leitura; criar temporário no mesmo diretório; gravar, sincronizar e fechar; preparar backup íntegro da versão anterior; substituir por operação atômica do SO; sincronizar diretório onde suportado. Falha não autoriza apagar o original nem simular sucesso. Implementação de substituição e durabilidade é isolada em `platform_ext`. Atomicidade e resistência a queda de energia são garantias diferentes; filesystems sem os recursos exigidos devem ser diagnosticados. Múltiplos escritores não são suportados: a aplicação controla uma sessão editora por projeto e conflitos externos exigem intervenção.

Preferências locais de layout, seleção e máquina ficam em armazenamento local não versionado, fora do `.proj`. Backend ou preset editado exige salvar e reiniciar o contexto gráfico de forma controlada; o primeiro incremento adotará reinício da aplicação/sessão, não troca improvisada durante um frame.

## 4. Decisão: presets declarativos antes da GPU

`presets.zon` é tabela de dados de distribuição da engine, carregada pelo mesmo módulo nas duas aplicações. ZON foi escolhido aqui porque é configuração interna controlada pela versão da engine, tipada e revisada com seu toolchain; não é o arquivo de intercâmbio do usuário. A tabela terá versão própria e compatibilidade explícita com o contrato de parâmetros do renderer.

A distribuição fixa uma única cópia da tabela. Ambos os executáveis verificam sua identidade; não procuram uma tabela arbitrária no CWD. O nome `low`, `medium` ou `high` vem do `.proj` e faz lookup na tabela. O resultado é combinado com overrides permitidos e validado para gerar uma configuração concreta imutável.

Ordem obrigatória:

1. Ler CLI e `.proj`; validar versão, campos e caminhos.
2. Ler/validar a tabela de presets; resolver preset e overrides.
3. Preparar plataforma e consultar capacidades do backend sem criar device/recursos GPU.
4. Validar a configuração concreta contra capacidades disponíveis.
5. Criar device, swapchain e recursos **somente** com a configuração aprovada.
6. Carregar cena e iniciar os sistemas do jogo.

A tabela cobrirá sombras, MSAA, draw distance, texturas e pós-processamento, com unidades, limites e parâmetros consumíveis pelo renderer especificados no item 3. Não haverá `switch` de qualidade no renderer. Mapeamento de enumeração de backend não é seleção hardcoded de preset.

**Política:** parâmetro obrigatório sem suporte ou backend indisponível é erro de inicialização. Não há downgrade silencioso ou promessa de Vulkan/WebGPU/D3D12/Metal já implementados. O core deve separar consulta de capacidades e criação de device; se o backend não conseguir consultar uma capacidade antes, deve falhar com diagnóstico, não criar recursos antecipadamente. Headless valida os dados, mas pula plataforma gráfica, consulta de GPU e device; o backend declarado continua registrado como intenção, não como GPU em uso.

**Trade-off:** falhar explicitamente reduz conveniência em máquinas fracas, mas evita discrepância oculta entre autoria e execução. Negociação opcional futura exigirá contrato novo, não alteração implícita dos presets.

## 5. Decisão: cena própria como envelope da reflexão do core

**Escolha:** arquivo `.scene` JSON versionado, com envelope de aplicação para versão de cena, UUID da cena, IDs persistentes de entidades, hierarquia e referências de assets. Conteúdo dos componentes é serializado pelo sistema de reflexão do core, usando IDs estáveis de tipo/propriedade e versões de componente.

Não se gravam handles de memória, ponteiros, padding de structs ou layout ABI. UUID persistente de entidade é convertido para handle geracional local ao carregar. Ordenação estável de entidades/propriedades permite diffs reproduzíveis. Componentes desconhecidos são preservados como dados opacos no Editor, que os indica como não editáveis; Runtime recusa execução se não puder materializar um componente requerido. Migrações de componentes pertencem ao registro de reflexão do core, não aos painéis.

**Alternativas descartadas:** dump binário de memória (não portátil); serializer de componentes paralelo no Editor (divergência do core); formato sem envelope de versão (migração ambígua). Dados binários de assets cozidos podem existir depois, sem substituir a cena de autoria nesta entrega.

**Dependência bloqueante:** o core precisa oferecer enumeração e metadados de propriedades, leitura/escrita validada, serialização, migração e remapeamento de referências. O código atual inspecionado não demonstra esse contrato. Sem ele, não se declarará entrega de inspetor genérico ou salvamento completo. O schema detalhado de cena será documentado antes de sua implementação, sem antecipar os schemas dos itens 2 e 3.

## 6. Decisão: Editor, viewport e headless

ZyntraUI constrói hierarquia, inspetor, content browser, console e editor textual. O editor de código limita-se a abrir/salvar C++/Lua, edição de texto e destaque léxico mínimo: sem linguagem de análise, debugger ou IDE completa.

O viewport apresenta textura produzida pelo renderer **real do core**, com câmera de autoria e mundo próprios. Draw commands da UI são traduzidos pelo adaptador gráfico; não se confunde o viewport de demonstração/software do toolkit com renderização do jogo. Picking, transformações e edição de componentes usam interfaces do core e transações da aplicação. Ausência de backend real é um bloqueio visível, nunca sucesso falso com null backend.

Headless Editor não cria janela nem GPU. Constrói a mesma árvore de UI com dimensões, fonte/atlas, escala, relógio, seed e eventos sintéticos fixos. Snapshots serializam draw commands normalizados e, quando disponível, a árvore semântica; não incluem ponteiros, handles voláteis ou timestamps de parede. Identidades de recursos são remapeadas para IDs estáveis. O golden fica versionado e sua atualização exige revisão. Isso testa UI e comportamento, não a correção visual do backend GPU.

**Trade-off:** comandos determinísticos são mais portáveis que comparação de pixels, mas não detectam erros de shaders/driver; testes gráficos reais são uma camada separada.

## 7. Decisão: loop, memória e determinismo

Runtime usa fixed timestep, contador inteiro de ticks e acumulador temporal; render interpola estados anterior/atual com `alpha`. Input é carimbado por tick e aplicado em ordem estável. Seed e configuração de simulação serão explícitas no contrato do projeto, não derivadas do relógio.

Jobs usam dependências explícitas, ordenação estável de aplicação de resultados e barreira antes de publicar o estado. Threads não alteram diretamente estado compartilhado de gameplay em ordem de chegada. O core deve prover isso; o scheduler sequencial atual não comprova a futura execução paralela determinística.

Em execução interativa há limite de catch-up por iteração para manter responsividade, sem descartar ticks de simulação; ao atrasar, reduz-se render e registra-se o atraso. Em CI/replay, avança-se por quantidade explícita de ticks, sem depender do tempo de parede. O contrato de CLI posterior incluirá um limite de ticks para testes finitos.

**Garantia delimitada:** determinismo de estado lógico para mesmo projeto, conteúdo, build, configuração, input por tick e seed. Relógio de logs, duração de jobs e pixels de GPU não fazem parte do hash lógico. Identidade bit a bit entre arquiteturas/SOs não será prometida sem contrato numérico determinístico do core e restrições a gameplay C++/Lua. Jobs, iteração de coleções, RNG, I/O e hot reload precisam respeitar essas restrições. Rede, arquivos externos e APIs de relógio não são entradas determinísticas implícitas.

Hot paths de aplicação usam arenas/pools pré-alocados e buffers de capacidade fixa. Reservas, carregamento e compilação ocorrem na inicialização ou em pontos explícitos de manutenção fora do frame. Overflow é erro recuperável, backpressure ou descarte contabilizado, conforme o subsistema; nunca crescimento automático invisível. Undo, indexação de assets e documentos têm budgets próprios. A política será verificada por instrumentação de alocação.

Lua, sol2, driver e gameplay arbitrário podem alocar internamente. Proibir alocações globais no frame exige perfil restrito de scripts, pools/allocator de Lua e contratos do core; não é garantido apenas pela aplicação. Carregamento/reload e GC devem ser agendados em manutenção; workloads incompatíveis serão diagnosticados. Desempenho AAA depende de medições futuras, não do nome da arquitetura.

## 8. Decisão: fronteiras Zig, C23, C++ e Lua

- Zig 0.17.0 é linguagem principal das aplicações e adaptadores. C23 complementa somente rotinas justificadas de baixo nível/interoperabilidade, compiladas com `addCSourceFiles` e `-std=c23`. Não serão criados módulos C artificiais para duplicar a lógica Zig.
- Um único `engine_api.h` é a autoridade da ABI C consumida por C++. Ele documentará **todas** as exportações públicas: negociação de versão/capacidades, contexto, entidades/componentes, serviços de gameplay, logs e contrato de módulo.
- Na ABI: inteiros de largura fixa, handles opacos/geracionais, buffers com tamanho explícito, resultados de erro e ownership documentados. Structs de transferência são C simples, com tamanho/versão, tradução explícita e testes de offsets/alinhamento; nunca structs Zig internas expostas por conveniência. Não usar `bool`, `long`, STL ou exceções como contrato de transporte.
- Memória é liberada pelo mesmo lado que a alocou, ou por callback de allocator documentado. Strings têm encoding, lifetime e tamanho explícitos. Thread affinity e validade após destroy/reload são parte do contrato.
- `gameplay_api` é o módulo C++20 dedicado às classes expostas via sol2 e Lua 5.4; C++23 pode ser perfil futuro explícito. Exemplos previstos: `Entity`, `Transform` e `Input`, apoiados exclusivamente na API C; nenhum desses serviços será fingido se o core não os fornecer.
- Uma única VM Lua por mundo de jogo é criada por uma integração proprietária explícita; sol2 usa a mesma instância e versão Lua. Não haverá uma segunda VM desconectada criada por conveniência no wrapper Zig.

A ponte é compilada sem RTTI e sem exceções C++ e usa chamadas Lua protegidas e resultados explícitos. Configuração de sol2/Lua deve provar que falhas não atravessam frames Zig/C nem fazem `longjmp` sobre objetos C++ com destrutores. Erro Lua vira resultado e log. Gameplay do usuário pode usar exceções internamente, mas seu adaptador C++ deve capturá-las antes da ABI; módulos sem essa garantia são incompatíveis.

**Alternativas descartadas:** classes C++ e STL na ABI, bindings diretos ao layout Zig e múltiplas VMs com estado implicitamente sincronizado. A ABI C custa wrappers, mas desacopla compiladores e permite testes de contrato independentes. A API Lua completa e o header serão entregues em sua fase, não inventados neste ADR.

## 9. Decisão: hot reload Lua obrigatório; C++ opcional e restrito

### Lua

Em modo de desenvolvimento, detecção por hash/mtime usa polling limitado fora do hot path; não exige watcher específico de SO. Alterações são agrupadas e aplicadas numa barreira entre ticks, sem jobs ou callbacks executando aquele módulo.

O script deve manter estado persistente em tabelas de dados explícitas. A nova versão é compilada/carregada em ambiente isolado; migração recebe cópia de dados serializáveis e bindings sem efeitos de mundo durante staging. Validação ou migração falhou: descartar candidato, preservar versão ativa e emitir erro. Sucesso: substituir callbacks e estado no commit, invalidando os antigos. Não há rollback prometido de efeitos externos: código de staging não pode produzi-los. Closures, userdata e recursos nativos não são migrados automaticamente.

Reload invalida uma sessão de replay determinístico, a menos que conteúdo novo e tick do commit sejam registrados como entrada. Distribuição final desabilita reload por padrão; a capacidade obrigatória existe no modo de desenvolvimento.

### C++

Build estático de gameplay é o caminho confiável inicial. Hot reload desejável usa DLL/shared library com entrada C versionada e tabela de funções. A biblioteca é construída externamente ou por comando de build configurado e autorizado, nunca a cada frame nem automaticamente ao abrir projeto não confiável.

Carrega-se uma cópia com nome único, verifica-se ABI/build, serializa-se estado por contrato estável e espera-se a barreira de jobs. O candidato inicializa sobre dados de staging, sem registrar callbacks ativos nem efeitos irreversíveis. Só após sucesso ocorre commit, troca de callbacks e descarte da versão antiga, quando não restarem referências. Falha mantém o módulo antigo. DLL em uso no Windows não é sobrescrita; liberação e limpeza ocorrem depois do unload seguro.

**Limitações declaradas:** não preservar vtables, ponteiros para código, estáticos, threads privadas, TLS, closures ou objetos alocados pela biblioteca antiga. Mudanças de layout exigem migração ou reinício. Callbacks pendentes impedem unload. Incompatibilidade de compilador/CRT, ABI ou estado exige reinício do Player. Não haverá patching de código ou promessa de reload de C++ arbitrário. Reload que exija executar as duas versões simultaneamente sobre o mundo vivo não é suportado.

**Trade-off:** migração explícita é menos transparente que live coding, mas evita ponteiros pendentes e mantém a fronteira C auditável.

## 10. Decisão: Play por processo filho e protocolo textual

Editor salva arquivos modificados mediante confirmação antes de Play, para o filho ler um snapshot coerente em disco. Cenas não salvas não viajam em memória. Editar durante Play afeta a autoria; mudanças só entram no jogo por reload documentado ou novo Play.

Runtime é localizado pela distribuição/manifesto da engine, não por busca insegura no PATH. Editor lança o binário com vetor de argumentos — sem shell — e `--project` com caminho absoluto. Nunca envia endereço de memória. `--headless` é propagado em testes; argumentos de seed/ticks serão definidos com a CLI.

Stdout e stderr são drenados concorrentemente em buffers limitados para evitar deadlock. Parsing respeita fragmentação de leitura, UTF-8, limite de linha e EOF sem newline. Linhas inválidas, inclusive saída de bibliotecas de terceiros, aparecem como diagnóstico bruto com origem e não derrubam o Editor. O filho não emite mensagens humanas livres pelo logger oficial.

Play tem estados `stopped`, `starting`, `running`, `stopping`, `failed`. Um evento estruturado `runtime.ready` confirma inicialização, não apenas existência do PID. Timeout, falha de criação, erro de projeto e exit inesperado são mostrados no console. Stop usa pedido de encerramento suportado pelo SO e prazo limitado; escalonamento para término forçado é isolado em `platform_ext`. Não existe canal binário nem console remoto de comandos. O Runtime deve tratar encerramento cooperativo e liberar recursos quando receber a notificação disponível na plataforma.

**Trade-off:** arquivos e linhas de log são fáceis de inspecionar e testar, mas não oferecem edição ao vivo de entidades entre processos. Isso fica fora desta entrega.

## 11. Decisão: logging JSON lines v1

Uma linha UTF-8 contém um objeto JSON completo terminado por LF. Strings são escapadas; mensagens multilinha permanecem um único registro. Os dois executáveis e as pontes core/C++/Lua usam o mesmo envelope:

| Campo | Tipo e regra |
| --- | --- |
| `log_version` | inteiro, `1` |
| `timestamp` | string UTC RFC 3339; relógio de parede, não tempo de simulação |
| `level` | `debug`, `info`, `warn` ou `error` |
| `source` | string estável: por exemplo `runtime`, `core`, `gameplay.cpp`, `gameplay.lua` |
| `event` | identificador estável legível por máquina, por exemplo `runtime.ready` |
| `message` | descrição UTF-8 para usuário; não usada como chave de protocolo |
| `session_id` | identificador textual da sessão do processo |
| `seq` | inteiro crescente atribuído pelo único consumidor/escritor do processo |
| `tick` | inteiro de simulação, ou `null` quando não aplicável |
| `fields` | objeto de dados adicionais tipados; sem ponteiros ou segredos |

Exemplo ilustrativo de protocolo de log, não de schema de projeto:

```json
{"log_version":1,"timestamp":"2026-11-01T12:00:00.000Z","level":"info","source":"runtime","event":"runtime.ready","message":"Runtime iniciado","session_id":"ci-session-1","seq":1,"tick":0,"fields":{"headless":true}}
```

`debug/info` seguem para stdout; `warn/error`, para stderr. Um escritor serializa registros completos para evitar interleaving. A ordem entre pipes não é garantida; `seq` auxilia correlação, com janela limitada no console e sem bloquear indefinidamente por registros ausentes. `seq` representa emissão, não causalidade determinística entre threads. Snapshots removem tempo/session e comparam campos semânticos.

Fila e registros são limitados: proposta de teto de 64 KiB por linha, incluindo LF; campos excedentes são truncados de forma válida e sinalizados. Saturação descarta primeiro debug/info e contabiliza perdas; eventos fatais têm reserva ou caminho síncrono fora do frame. Se até a reserva se esgotar, a perda é contabilizada, não há promessa irreal de entrega sem limite. Pipes quebrados e consumidor lento não causam alocação ilimitada ou panic. Saída de terceiros não aderente é tratada como tal.

Falhas fatais anteriores à inicialização também usam um caminho mínimo de JSON estruturado. O processo retorna código não zero; o código de saída não é substituído pelo texto do log. A tabela definitiva de exit codes fará parte da documentação de CLI.

## 12. Decisão: plataforma e builds independentes

Zigway é o único backend de janela/input. APIs do SO para processo, substituição atômica, sincronização, carregamento dinâmico e encerramento ficam em `platform_ext`, com implementação por plataforma e interface única; não são uma camada de janela concorrente. Não serão espalhados condicionais de SO pelos painéis ou loop.

Windows e Linux são os únicos alvos de produto/build/CI conforme ADR-003. macOS foi retirado do escopo por decisão do usuário. Limitações de Zigway/ZyntraUI podem ser corrigidas nas próprias bibliotecas com testes e versão/hash fixados, sem introduzir GLFW/SDL ou fingir gráficos com headless. Recursos ausentes são detectados e comunicados. A matriz de backends gráficos depende do core e não implica que todos os nomes aceitos pelo schema funcionem em todo SO.

Dependências e toolchain são fixados por versão/commit e hash verificável, incluindo Lua e sol2; sem downloads flutuantes durante a execução. CI nativa de cada SO compila as duas aplicações, C23 e a ponte C++ e executa testes headless. Gráficos reais exigem smoke tests em runners com backend/GPU apropriados, separados dos testes null. Ausência de toolchain requerido faz a etapa falhar explicitamente, sem substituí-lo por outra versão para obter um selo verde.

**Alternativas descartadas:** um único build obrigatório para os dois binários (acoplamento de entrega); backend de janela alternativo (viola a stack); declarar CI headless como comprovação de renderização nativa (cobertura falsa).

## 13. Interfaces requeridas do core — dependências, não implementações

| Contrato esperado | Uso pela aplicação | Evidência/condição de aceite |
| --- | --- | --- |
| Versão, ABI e capacidades | recusar combinação incompatível | negociação testada antes de criar contexto |
| Renderer configurável antes de device | preset, viewport, apresentação de UI | GPU real e configuração resolvida observável |
| ECS com handles geracionais | criar/remover entidades e componentes | handles inválidos produzem erro, não acesso indevido |
| Reflexão e serializer versionados | inspetor, `.scene`, migrações | round-trip e referências estáveis |
| Jobs e barreiras com budgets | fixed update, reload seguro | execução sem realloc no frame e ordem reproduzível |
| Asset loader e referências estáveis | cena inicial e content browser | erros explícitos, cancelamento e lifetime definidos |
| Host de gameplay/VM Lua 5.4 | callbacks C++, sol2 e hot reload | uma VM, chamadas protegidas e ownership verificados |
| Sink de logs limitado | console e JSON lines | nenhum logger paralelo não estruturado na API oficial |
| API de input por tick e tempo explícito | determinismo de gameplay | replay e hashes lógicos reproduzíveis |

Nomes e assinaturas exatos só serão fixados no header/adaptadores após conferência com o responsável pelo core. Não serão expostas funções fictícias como se já existissem.

## 14. Estratégia de validação e aceite

1. **Projeto:** Editor serializa; Runtime lê em módulo real e em processo separado; compara valores tipados, incluindo opcionais, Unicode e caminhos. Negativos: versão ausente/futura, duplicatas, campo desconhecido, bounds, truncamento e path escape. Runtime não modifica bytes nem mtime do `.proj`.
2. **Presets:** fixtures low/medium/high, overrides e erros; instrumentação comprova resolução antes de qualquer criação GPU. Configuração concreta é igual nos dois consumidores, sem seleção de qualidade no renderer.
3. **Persistência:** falhas injetadas em cada etapa, backup íntegro, conflito externo e original recuperável. Testes por SO para operações atômicas reais.
4. **Fronteiras:** compilar header como C23 e C++20; testar sizes/offsets, ABI, handles obsoletos, ownership, erro e callbacks. Testes C++ → C → core e Lua → sol2 → C++ → C, incluindo erro Lua protegido e incompatibilidade de versão.
5. **Editor headless:** input sintético aciona criar/editar/remover entidade e Play; draw commands determinísticos comparados a golden versionado.
6. **Play:** filho real, caminhos com espaços/Unicode, captura simultânea dos pipes, `runtime.ready`, erro de schema, crash/exit inesperado, linha parcial/inválida, volume alto, timeout e Stop; nenhum filho órfão ao encerrar testes.
7. **Simulação:** mesmo seed/input/ticks gera hash de estado lógico idêntico em repetições suportadas; medir alocações após aquecimento. Divergência entre SOs é investigada e não mascarada por snapshots frouxos.
8. **Reload:** Lua válido, sintaxe inválida, migração inválida e commit seguro; C++ opcional testa falha preservando módulo antigo e unload sem callbacks vivos.
9. **Plataforma/renderer:** matriz explícita separa compile, headless e gráfico real; um teste null não aprova uma funcionalidade GPU.

Esses são critérios futuros, não resultados de testes já executados.

## 15. Pendências numeradas, com responsável e motivo

Não há tarefas anônimas implícitas. “Responsável” abaixo identifica o papel que deve resolver a dependência, não compromisso já assumido por terceiros.

| ID | Responsável | Pendência e justificativa | Bloqueia |
| --- | --- | --- | --- |
| P01 (concluída) | Usuário / arquitetura das aplicações | ADR aprovado pelo usuário em 2026-11-01 | item 2 liberado |
| P02 (concluída) | Aplicações + usuário | `.proj` v1 aprovado pelo usuário em 2026-11-01; contrato em `docs/PROJECT_SCHEMA_V1.md` | aprovação do item 2 concluída; código ainda depende de P03 |
| P03 (concluída) | Aplicações + usuário | Contrato de `presets.zon` aprovado pelo usuário em 2026-11-01; `docs/PRESETS_SCHEMA_V1.md` | código de aplicação liberado; suporte GPU segue P05 |
| P04 | Build/CI das aplicações | Verificar disponibilidade e APIs de Zig 0.17.0 e compatibilidade real de Zigway/ZyntraUI/Lua/sol2; fixar hashes | qualquer alegação de build suportado |
| P05 | Responsável pelo core | Disponibilizar renderer GPU real, consulta pré-device e integração de draw commands/viewport | Editor/Runtime gráficos reais |
| P06 | Responsável pelo core | Oferecer ECS/reflexão/serializer e migrações com os contratos da seção 13 | inspetor e cenas completas |
| P07 | Responsável pelo core + aplicações | Garantir budgets de jobs, barreiras, input e determinismo numérico documentado | garantias de frame/replay |
| P08 | Responsável por plataforma / Zigway | Validar superfícies/input/DPI Windows/Linux e corrigir limitações upstream | viewport 3D e Canvas reais |
| P09 | Aplicações + responsável pelo core | Formalizar `engine_api.h`, VM única e configuração sem exceções/RTTI da ponte | gameplay e testes de fronteira |
| P10 | Aplicações | Implementar persistência atômica, supervisão de filho e extensões por SO com fault injection | salvar/Play de produção |
| P11 | Aplicações + responsável pelo gameplay | Definir dados migráveis, lifecycle de scripts e reload Lua transacional | reload Lua obrigatório |
| P12 | Aplicações + responsável pelo gameplay | Avaliar biblioteca C++ recarregável após caminho estático; manter reinício quando incompatível | apenas reload C++ desejável |
| P13 | Build/CI + aplicações | Prover runners gráficos e medir budgets/performance reais | comprovação gráfica e desempenho |

## 16. Fora do escopo e consequências finais

Ficam fora: Hub/updater, implementação de subsistemas do core ausentes, IDE completa, live editing de mundo entre processos, import pipeline AAA novo, networking, sandbox de código nativo, patching arbitrário de C++, determinismo universal de shaders e suporte gráfico fictício a backends não implementados.

Projetos executam código nativo e Lua: abrir metadados não autoriza build/execução de scripts. Play e comandos de build exigem ação explícita de confiança do usuário; isso reduz execução acidental, mas não isola código malicioso.

A arquitetura privilegia contratos auditáveis, arquivos legíveis e falhas explícitas em vez de compatibilidade silenciosa. Existem custos: wrappers C, migrações, separação entre autoria e estado em Play, reinício para mudanças gráficas e dependências bloqueantes do core. Esses custos são aceitos para evitar divergência de configuração, corrupção de projetos e promessas falsas sobre capacidades existentes.

## 17. Portões de aprovação (histórico)

1. ADR aprovado pelo usuário em 2026-11-01.
2. Schema `.proj` v1 aprovado pelo usuário antes de código.
3. Schema e valores de `presets.zon` aprovados pelo usuário antes de código.
4. Estrutura e implementação incremental liberadas: contratos em `shared/` e bootstraps CLI em `editor/` e `runtime/`. Não houve autorização implícita para inventar capacidades do core. GUI, execução de jogo, API pública de gameplay e persistência permanecem pendentes.

CLI/logging/supervisão curta de validação têm decisões complementares em `ADR-002-validation-bootstrap.md`, dentro das fronteiras aqui aprovadas.
