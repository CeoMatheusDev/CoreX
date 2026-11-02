> **Perfil atual (ADR-003):** Windows/Linux, autoria 3D e UI/Canvas, sem cena 2D. Reader aceita schemas [1,2]; novos projetos usam `EmptyGameV2.proj`.

# CLI das aplicações — bootstrap de validação

Esta é uma interface executável **incremental**, não Editor gráfico nem Player de jogo completos. Decisões: [ADR-002](ADR-002-validation-bootstrap.md). Continua usando os schemas aprovados e não requer Hub.

## Build independente (Zig 0.17.0)

```sh
(cd editor && zig build)
(cd runtime && zig build)
```

Cada build compila Zig + C23 do módulo compartilhado e instala seu próprio prefixo:

```text
editor/zig-out/ ou runtime/zig-out/
├── bin/CoreXEditor[.exe] ou CoreXRuntime[.exe]
└── share/corex/
    ├── distribution.json
    └── presets.zon
```

É possível instalar os dois num prefixo comum com `zig build --prefix <diretório>`, desde que ambos usem exatamente a mesma versão de código/manifesto/tabela. Copiar somente o binário sem `share/corex` causa erro; não há busca de fallback no projeto/CWD. Pode-se mover a árvore instalada inteira.

Sem `zig` no PATH, usar `python -m ziglang` após instalar `tools/zig-requirements.txt` em venv externo ao checkout. A versão 0.17.0 é exigida; não substituir por outra versão.

## Argumentos

| Argumento | Editor | Runtime | Regra |
| --- | --- | --- | --- |
| `--project <arquivo>` | sim | sim | obrigatório exceto em `--help`; caminho relativo ao CWD ou absoluto, UTF-8, até 4096 bytes |
| `--headless` | sim | sim | declara intenção de não usar janela/GPU; nesta fatia não executa simulação |
| `--validate-only` | sim | sim | valida somente documento/presets/distribuição; autoriza retorno zero nesse escopo |
| `--check-runtime <executável-absoluto>` | sim | não | exige `--validate-only`; lança filho em validação, não Play |
| `--help` | sim | sim | deve ser o único argumento; responde com um registro JSON lines e exit 0 |

Até 32 argumentos após argv[0]. Flags repetidas/desconhecidas, valores ausentes e combinações inválidas são erros. Não há sintaxe `--flag=value`, shell expansion, variáveis de ambiente ou comandos de build. Se um nome relativo começa com `--`, usar prefixo `./` para não ser confundido com uma flag. Valores de CLI não regravam o projeto.

`--check-runtime` é ação explícita de confiança no binário indicado. Caminho relativo é recusado na supervisão, sem pesquisa de PATH. No Windows o executável deve ter sufixo `.exe`; scripts `.cmd`/`.bat` não são aceitos. Em POSIX, o SO pode interpretar um executável com shebang; a aplicação não o transforma em comando de shell. Não executar programas não confiáveis.

## Exemplos na raiz do repositório

```sh
runtime/zig-out/bin/CoreXRuntime --project docs/examples/EmptyGame.proj --headless --validate-only
editor/zig-out/bin/CoreXEditor --project docs/examples/EmptyGame.proj --headless --validate-only

# O caminho do Runtime deve ser absoluto (substituir /caminho/real/CoreX):
editor/zig-out/bin/CoreXEditor \
  --project docs/examples/EmptyGame.proj --headless --validate-only \
  --check-runtime /caminho/real/CoreX/runtime/zig-out/bin/CoreXRuntime
```

O exemplo não fornece cena/assets/scripts e **mesmo assim** é válido para `--validate-only`, pois esse modo não tenta carregar recursos. Sem `--validate-only`, inclusive com `--headless`, o mesmo exemplo falha com `application.core_unavailable` e exit 4. Não há fallback para cena/simulação vazia.

## Códigos de saída

| Código | Significado |
| --- | --- |
| 0 | ajuda ou validação solicitada concluída; não significa jogo executado |
| 2 | CLI inválida |
| 3 | leitura do projeto, schema, campo ou configuração de presets inválida |
| 4 | distribuição/versão incompatível ou execução core/gráfica/simulação indisponível |
| 5 | falha ao criar/capturar/aguardar filho, timeout, exit não zero ou handshake divergente |
| 70 | erro interno não classificado, incluindo falha de bootstrap/alocação não tratada no contexto específico |
| 74 | falha de saída do logger; pode não haver registro quando o pipe está quebrado |

Nenhum caminho de erro normal imprime stack trace ou texto de diagnóstico avulso. Kill/crash externo ainda pode produzir status de sinal/encerramento do SO, não estes códigos controlados.

## Protocolo e garantias observáveis

Todos os registros oficiais seguem o envelope JSON lines v1 do ADR-001. Timestamps `YYYY-MM-DDTHH:mm:ss.sssZ`, `session_id`, `seq` por processo, nível, origem, evento, mensagem, `tick` (null nesta fatia), `fields` objeto e indicador opcional `message_truncated`.

Eventos principais:

- `application.starting`: intenção/mode, com `core_linked=false`.
- `project.document_validated`: schema/metadados validados; **não** resolução segura de recursos.
- `graphics.config_resolved`: 27 valores concretos, overrides e identidade de tabela; `gpu_created=false`, `capabilities_checked=false`.
- `editor.validation_complete` / `runtime.validation_complete`: escopo `document_and_presets`, fingerprint e flags explícitas de serviços ainda não carregados.
- `runtime.check_starting` / `runtime.output` / `runtime.output_invalid` / `runtime.check_complete` / `runtime.check_failed`: supervisão pelo Editor. Os registros do filho ficam aninhados em `fields.record`, preservando origem/sessão/seq originais.
- `application.core_unavailable`: erro em execução real solicitada antes da integração do core.

O fingerprint v2 inclui o perfil `desktop-3d-canvas-v1`, além de o modelo normalizado completo do `.proj`, parâmetros gráficos resolvidos e manifesto empacotado. Não inclui relógio, PID, sessão ou CWD. Não é assinatura/autenticação, hash de assets ou comprovação de determinismo da simulação. Um `.proj` equivalente em defaults opcionais produz a mesma identidade; um projeto com configuração/seed diferente não deve confirmá-la.

### Limites da captura

- 256 KiB por stream, com slack limitado de buffers da stdlib.
- Deadline monotônico de 10 s para coleta + saída do filho.
- Linha com até 64 KiB incluindo LF; overflow descartado até próximo LF. EOF sem LF é aceito.
- Profundidade JSON 16; membros/coleções 512; strings limitadas ao teto da linha. UTF-8 é validado; duplicatas são recusadas. Mensagens/campos podem carregar NUL escapado como dado.
- Entrada inválida vira diagnóstico com prefixo bruto de até 1024 bytes (string ou array de bytes conforme UTF-8), sem ser aceita como handshake.
- Logs do filho são publicados após o término/coleta, não ao vivo num console gráfico.
- A saída entre stdout/stderr não tem ordem global garantida. O Editor verifica ordem crescente por pipe, unicidade entre pipes e sessão consistente.
- Máximo de 4096 frames por execução capturada, contando inválidos. Excesso gera um aviso `RecordBudgetExceeded`, descarta o restante e reprova a verificação; impede amplificação por milhares de linhas vazias/inválidas.

Teto do encoder: 64 KiB incluindo LF. Mensagens acima de 4096 bytes são truncadas em fronteira UTF-8 e sinalizadas. Se os campos de um registro excederem o teto, substitui-se o registro por aviso `log.record_too_large`, não por JSON parcial. Esse sink é síncrono de bootstrap, não a fila de logs de workers/frame.

## Política do alvo

`application.target_policy` publica `host_platform`, `backend_requested`, `decision`, `authoring_domains=["scene_3d","ui_canvas"]`, `scene_2d_supported=false`, `renderer_linked=false` e `gpu_created=false`. Não é lista de GPUs/backends implementados.

Em validação de documento, é permitido inspecionar projeto D3D no Linux; a decisão será `backend_not_on_platform`. Em execução normal, essa decisão e `backend_out_of_scope` (Metal/WebGPU v1) causam `application.backend_unsupported`/exit 4, antes de qualquer device. Uma API elegível também não funciona sem o adaptador real: continua exit 4 / `application.core_unavailable`. Sem fallback ou alteração do projeto.

Os builds de aplicações rejeitam macOS, FreeBSD, WASI e demais alvos explicitamente. CI roda no Linux e cross-compila Windows; execução Windows nativa continua P16.

## Limitações deliberadas

Sem Zigway/ZyntraUI ligados nesta fatia, janela, viewport, cenas/ECS, assets, gameplay, sol2/Lua, fixed timestep, hot reload, gravação atômica ou UI headless. Os adaptadores reais continuam nas pendências do core/aplicações.

NFC completa e validação de recursos por filesystem ainda pendentes. Caminhos não ASCII **dentro do `.proj`** continuam recusados explicitamente; o caminho de CLI até o próprio `.proj` pode conter Unicode/espaços e é testado. Se um symlink UTF-8 resolver para nome real com bytes não UTF-8, falha explicitamente com `UnsupportedProjectPathEncoding`/exit 3, sem emitir JSON inválido. Abrir em `--validate-only` nunca grava `.proj` nem instala dependências.

Supervisão cobre apenas o filho imediato. Árvores de subprocessos, fechamento abrupto/SIGINT/crash do Editor e lifecycle cooperativo de Play não são cobertos. Não usar `--check-runtime` como sandbox de executável hostil.
