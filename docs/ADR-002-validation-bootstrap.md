# ADR-002 — Bootstrap executável e supervisão de validação

- **Data:** 2026-11-01.
- **Estado:** adotado na implementação incremental autorizada após aprovação do ADR-001 e dos schemas. Não altera os contratos `.proj`/presets nem declara conclusão das aplicações.
- **Responsável:** aplicações/build; serviços ausentes do core continuam com seus responsáveis no ADR-001.

## Contexto

O pacote de contratos compartilhados já é testável, mas o core inspecionado não oferece renderer GPU, reflexão/serialização completas nem ABI/host de gameplay prontos para os dois aplicativos. É necessário avançar com executáveis reais e testes entre processos sem apresentar simulação/UI falsa como entrega funcional.

## Decisões e trade-offs

### 1. Builds independentes e modo explícito de validação

`editor/build.zig` e `runtime/build.zig` produzem `CoreXEditor` e `CoreXRuntime`. Ambos dependem do pacote local `shared`, incluindo C23 com `-std=c23`. Não herdam os pacotes gráficos quebrados do build legado e não introduzem outra camada de janela. Nesta fatia não criam janela: integração Zigway/ZyntraUI é pendência, não uma implementação alternativa.

`--validate-only` autoriza apenas parsing/validação do documento e resolução dos presets. O retorno zero não significa cena/asset/script carregado, ABI do core negociada ou backend suportado. Sem essa opção, projeto válido termina com erro explícito de adaptador indisponível, inclusive com `--headless`. Nunca emitir `runtime.ready` ou simular ticks vazios para aparentar execução de jogo.

**Alternativa descartada:** chamar o backend null de Runtime funcional. Custaria menos código, mas produziria evidência falsa e violaria o ADR-001.

### 2. Recursos da distribuição e versão

Cada prefixo instalado contém `bin/<executable>` e `share/corex/{presets.zon,distribution.json}`. A busca parte do caminho real do executável, não de argv[0], CWD, PATH ou diretório do projeto. Os dois builds copiam a mesma tabela aprovada.

O manifesto registra a identidade da distribuição de Engine, versão própria do formato, token SemVer de requisito do `.proj`, allow-list explícita de compatibilidade, versão do contrato do renderer, revisão e SHA-256 da tabela. A identidade de produto é gerada do `VERSION` raiz no build; não é o SemVer de `build.zig.zon`. O binário fixa os bytes do manifesto gerado e exige correspondência exata do arquivo instalado. Depois verifica o hash da tabela. Não existe fallback embutido da tabela ou download em execução. `.gitattributes` fixa LF nos textos para estabilizar os hashes em checkouts Windows.

O bootstrap compartilhado classifica o requisito como `same_version`, `compatible` ou `incompatible`. Compatibilidade diferente da identidade atual só é aceita por versão exata listada no manifesto; hash válido não concede compatibilidade. O formato `.proj` aprovado permanece inalterado e seu `engine.version` permanece SemVer. A negociação de ABI continua adicional e ainda não implementada para o core público: o protocolo registra `core_linked=false` e `core_abi_checked=false`. Divergência de bytes do manifesto gera `distribution.manifest_corrupted`; tabela/hash/contratos ausentes ou inválidos geram `distribution.invalid`. Hashes protegem contra divergência acidental ou instalação inconsistente, não autenticam um binário/manifesto substituídos por atacante. Assinatura e updater ficam no Hub. O valor inicial `0.1.0a1` foi definido como identidade de desenvolvimento nesta adoção; não afirma release publicado anterior.

**Trade-off:** um manifesto semanticamente igual mas reformatado também é recusado. É dado interno de distribuição, não documento do usuário; identidade byte a byte simplifica auditoria e não modifica a liberdade de formatação do `.proj`.

### 3. CLI e logging de bootstrap

CLI estrita, sem shell, expansão de variáveis ou comandos de build. `--help` é uma chamada isolada e também responde em JSON lines. Flags repetidas, desconhecidas, valores ausentes e combinações inválidas causam saída não zero. Exit codes são documentados em `APPLICATION_CLI.md`.

O logger é síncrono, de escritor único/thread-affine, com encoder fixo de 64 KiB incluindo LF. Toda a linha é construída antes do primeiro write. Timestamps UTC têm milissegundos; sessão aleatória textual e sequência por processo permitem correlação. Debug/info vão para stdout, warn/error para stderr. Mensagem longa é cortada em fronteira UTF-8 e sinalizada pelo campo opcional `message_truncated` no envelope v1. O leitor aceita campos futuros do envelope sem tratá-los como comandos.

Se campos excederem o teto, o registro original não é enviado parcialmente: sai um aviso menor `log.record_too_large`, preservando sequência e identificador do evento original. Quebra de pipe retorna código 74, sem stack trace avulso. Isso não é a fila concorrente/sem bloqueio do futuro logger de frame do core: workers e frame ainda não usam esse sink.

**Trade-off:** I/O síncrono pode bloquear com consumidor lento. É aceito apenas no caminho de inicialização/controle desta fatia; não será inserido em hot path. O logger concorrente do core permanece P09/P15.

### 4. Processo filho de validação não é Play

`CoreXEditor --validate-only --check-runtime <executável-absoluto>` é ação explícita de execução de programa confiado pelo usuário, nunca efeito de abrir metadados. Passa ao filho `--project <absoluto> --headless --validate-only`, com argumentos separados e stdin ignorado. Não pesquisa PATH; no Windows aceita somente `.exe`, evitando interpretação de batch por shell.

A captura drena stdout/stderr concorrentemente com limites de 256 KiB por stream, mais slack limitado de coleta da stdlib. O prazo é de 10 segundos, compartilhado entre coleta e término. O proprietário mantém o filho até reap/close. Linhas são enquadradas até 64 KiB, incluindo LF; aceita fragmentos, CRLF e EOF sem newline. Entrada inválida vira diagnóstico bruto limitado, sem derrubar o Editor. O leitor limita profundidade a 16 e membros/coleções a 512 por registro. Strings/escapes de mensagem podem conter NUL como dado, ao contrário do `.proj`.

Nesta fatia a apresentação dos logs do filho ocorre **após** coleta/término, não em console gráfico ao vivo. Parent records usam `runtime.output` e embutem o objeto do filho sem fingir a sessão/seq do Runtime como próprias. A ordem entre pipes não é prometida; verifica-se sequência crescente dentro de cada pipe, unicidade entre os dois pipes e sessão consistente. Um orçamento de 4096 frames (incluindo inválidos) limita amplificação de diagnósticos; ao excedê-lo, descarta-se o restante com aviso único e falha da verificação. A tabela de sequências tem capacidade reservada antes da análise, sem crescimento por linha.

Para sucesso, o processo deve retornar zero e emitir exatamente um `runtime.validation_complete` com escopo correto e fingerprint idêntico. Esse SHA-256 inclui a estrutura normalizada completa do projeto, os 27 parâmetros concretos e os metadados da distribuição, com versão própria do fingerprint. Relógio, sessão, PID e CWD não entram na identidade. O handshake detecta divergência de configuração, não autentica código hostil nem comprova determinismo da simulação.

**Alternativas descartadas:** sucesso baseado só no exit code; substring no texto de log; comparação só do nome de preset; chamar essa verificação de Play. Todas aceitariam resultados insuficientes.

### 5. Extensão nativa de supervisão e regressão encontrada

O primeiro experimento cancelava `std.process.run` numa corrida com timer. Um teste real encontrou filho órfão quando ele fechava ambos os pipes e permanecia vivo: o caminho de wait cancelado pode limpar o identificador antes de o proprietário terminar/recolher o filho. Além disso, cleanup por SIGTERM pode ficar preso em filho que ignora esse sinal.

A implementação final **não usa esse caminho**. `platform_ext/process_native.c` oferece apenas duas operações de ABI C privada: observar término sem reap (`waitid` com `WNOWAIT` em POSIX; handle sinalizado no Windows) e forçar término. O proprietário consulta a saída a cada 5 ms, enquanto um único coletor concorrente drena os dois pipes. Só chama wait protegido contra cancelamento depois de observar término e concluir a coleta. No timeout/overflow, cancela o coletor, solicita término forçado e recolhe o filho. Assim o PID não pode ser reutilizado entre observação e cleanup pelo próprio supervisor.

Toda diferença de SO está em `platform_ext`; não entra nos painéis ou loop de jogo. Esse C23 é justificado por interoperabilidade direta e pequena com as APIs de processo, sem implementar backend de janela paralelo.

**Trade-off:** polling de 5 ms é simples e auditável, mas não adequado para um scheduler geral de gameplay. É restrito à validação curta. Árvores de processos, shutdown cooperativo de Play, tratamento de fechamento abrupto/crash/SIGINT do Editor e isolamento de código hostil continuam P10/P15. Um processo em estado de kernel não interrompível ou falta de direito de término pode impedir garantias temporais absolutas; o prazo não é uma promessa de tempo real rígido.

## Evidência e aceite desta fatia

- Testes compartilhados: CLI, datas UTC, encoding/framing/leitura JSONL, limites e identidade de distribuição, além dos contratos anteriores.
- Integração real dos dois executáveis: fingerprints/27 parâmetros iguais, arquivos `.proj` sem alteração de bytes/mtime, recursos de distribuição movidos/ausentes/adulterados e falhas explícitas de execução não implementada.
- Probes POSIX temporários: dois pipes cheios, linha excessiva, EOF parcial, protocolo inválido, sessão/seq divergentes, exit não zero, quebra de pipe e registro que excede limite ao ser embrulhado pelo Editor.
- Regressão obrigatória: filho fecha stdout/stderr, ignora SIGTERM e dorme; supervisor retorna timeout e teste comprova que o PID foi eliminado/recolhido. Esses testes não comprovam o comportamento nativo Windows, ainda P16.

Resultados finais desta etapa ficam em `APPLICATION_PROGRESS.md`. Não foi alterado o schema aprovado, não foi adicionado IPC binário, e não foram inventados serviços do core para obter um teste verde.

### 6. Matriz de falhas de alocação portátil

A execução nativa macOS encontrou `NondeterministicMemoryUsage` em dois probes: a contagem de alocações da arena varia quando resize/remap do backing consegue crescer no lugar, dependendo do layout de VM. A matriz de injeção exige número estável de pontos de alloc. `testing_allocator.zig` recusa resize/remap **somente nos testes de OOM**, forçando o caminho de crescimento por nova alocação. O FailingAllocator continua verificando propagação de OutOfMemory e igualdade entre bytes alocados/liberados, e o allocator de teste continua detectando leaks. A aplicação e os testes normais/integrados mantêm o allocator real. Alternativas rejeitadas: ignorar esses testes no macOS ou engolir `NondeterministicMemoryUsage`, que perderiam cobertura silenciosamente.
