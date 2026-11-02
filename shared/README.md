# CoreX — contratos compartilhados de aplicação

**Implementado nesta etapa:** módulo Zig 0.17.0 reutilizável de documentos `.proj` v1/v2, presets e DTO interno Zig↔C23. Agora é consumido pelos bootstraps independentes em `editor/` e `runtime/`, que validam documentos e não executam o jogo/UI. Não depende de janela, GPU, Lua ou dos builds legados.

## Build e testes

Com Zig 0.17.0 instalado:

```sh
cd shared
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build check -Dtarget=x86_64-windows-gnu -j2 --summary all
```

`check` compila os testes para outro alvo sem executá-los. **Não equivale a teste nativo Windows.** O primeiro cross-link pode demorar por compilar o CRT.

Sem Zig no PATH, no Linux é possível instalar o mesmo wheel fixado por SHA-256 sem Python:

```sh
# Na raiz; o diretório de destino ainda não deve existir.
mkdir -p .cache
sh tools/install_zig.sh "$PWD/.cache/zig-0.17.0"
ZIG_EXE="$PWD/.cache/zig-0.17.0/ziglang/zig"
cd shared
"$ZIG_EXE" build test --summary all
```

O instalador requer `curl`, `unzip`, `sha256sum` e utilitários POSIX; também aceita um wheel local já baixado. Ele não é necessário se Zig 0.17.0 já estiver disponível.

O toolchain de build suportado usa wheels Linux; macOS foi removido do produto (ADR-003). Não foi encontrada wheel Windows para 0.17.0; suporte nativo de CI Windows continua pendente (P16). Não adotar outra versão de Zig silenciosamente.

Para invocar o runner diretamente, incluindo C23:

```sh
cd shared
zig test -I . -lc root.zig -cflags -std=c23 -Wall -Wextra -Werror -- graphics_abi.c platform_ext/process_native.c
```

Na raiz:

```sh
(cd tools/zig && zig build validate-fixtures)
zig fmt --check shared
c++ -std=c++20 -fno-rtti -fno-exceptions -Wall -Wextra -Werror -fsyntax-only -x c++ shared/graphics_abi.h
```

O workflow `shared-contracts.yml` configura Debug/ReleaseSafe em Linux e cross-compilação Windows. Resultados confirmados por commit e links de CI estão em `docs/APPLICATION_PROGRESS.md`. Não é a matriz final de CI das duas aplicações.

## API Zig e ownership

```zig
const app = @import("corex_app");
var diagnostic: app.project.Diagnostic = .{};
var document = try app.project.parse(allocator, project_bytes, &diagnostic);
defer document.deinit();
var table = try app.presets.parse(allocator, table_bytes);
defer table.deinit();
const resolved = try table.value.resolve(
    document.value.renderer.graphics_preset,
    document.value.renderer.overrides,
);
const dto = try app.graphics_abi.translate(resolved);
_ = dto; // entregue ao adaptador do core quando sua interface real estiver disponível
```

O pacote exporta `corex_app` via `build.zig`. Consumidores devem usar o módulo do build, que inclui o fonte C23 e libc. A camada C é compilada com `-std=c23 -Wall -Wextra -Werror`.

- `project.parse`: preflight limitado; parsing estrito com duplicatas recusadas; versão antes do corpo; conversão tipada sem coerção de strings/números; metadados, caminhos lexicais e dependências de campos.
- `Document`: arena própria; strings são independentes dos bytes de entrada; válido até `deinit`. Não copiar para depois destruir duas vezes; não guardar referências após destruir.
- `project.serialize`: aloca bytes canônicos com dois espaços, LF, newline final e omissão de opcionais equivalentes; caller libera com o mesmo allocator. Revalida documento. **Não grava em disco nem oferece backup/replace atômico.**
- `Diagnostic.pointer()`: JSON Pointer RFC6901 em buffer próprio limitado, preservado após erro. Erros estruturais/semânticos apontam para o campo; sintaxe/duplicatas ainda reportam categoria na raiz, sem localização de byte. O chamador adicionará arquivo e mensagem humana no logger.
- `presets.parse`: valida perfil restrito, envelope, todos os presets completos e invariantes. A arena contém strings e diagnóstico temporário do parser ZON.
- `Table.resolve`: lookup por nome no módulo de configuração, merge por presença e validação da configuração concreta. Não há lookup de qualidade no renderer.
- `graphics_abi.translate`: valida e traduz cada campo para DTO C explícito; flags e enums não atravessam como tipos internos Zig.

Os parsers alocam na inicialização/documento, não no frame. Resolução e tradução de configuração não alocam. Isso **não comprova** ausência de alocações nos subsistemas core/Lua/GPU ainda não integrados.

### DTO C23 privado

`graphics_abi.h` é contrato **interno das aplicações**, não substitui o futuro `engine_api.h` único da API pública do core. A validação C não cria renderer nem dispositivo. Usa tamanho/versão, larguras fixas, flags 0/1, enumeração numérica explícita, status `i32` e nenhuma retenção de ponteiro/alocação.

O DTO usa membros de 4 bytes e tem 116 bytes no v1, sem packing. A escolha custa alguns bytes na inicialização, mas evita structs packed e flags dependentes de linguagem. `static_assert` em C e testes Zig verificam todos os offsets, alinhamento natural e tamanho; os tipos Zig internos nunca são passados diretamente para C. A duplicação de checks em C é defesa da fronteira, não nova tabela de presets.

## Cobertura e limites atuais

49 testes compartilhados em Linux; resultados por modo em `docs/APPLICATION_PROGRESS.md`. Incluem round-trip em memória com os papéis de Editor/Runtime, todos os presets, campos inválidos, duplicatas escapadas, erros de versão, exatidão decimal, ownership, limites, 256 mutações determinísticas e falhas de alocação injetadas. Também exercitam a ABI C23 real.

Os testes Zig Editor→Runtime continuam sendo round-trip em memória. Adicionalmente, `tools/test_bootstrap.py` testa os **dois executáveis em processos reais**, apenas no escopo de validação. São 29 testes de integração locais, incluindo supervisão e JSON lines. Play de jogo, snapshots ZyntraUI e GPU real continuam não implementados.

Limitações explícitas:

- **P14:** NFC completa indisponível: caminhos não ASCII retornam `UnicodePathNormalizationUnavailable` (fail-closed). Metadados/nome de projeto UTF-8 são aceitos. Não é implementação completa do conjunto de caminhos admitido pelo schema.
- **P14:** caminhos só são validados lexicalmente. Links, caixa real, permissões, existência, contenção no filesystem e segurança contra corrida de substituição exigem `platform_ext`. Resultado de parse não autoriza leitura/escrita/execução de recursos.
- **P15 parcial:** manifesto/hash da distribuição, CLI, logs síncronos e bootstraps binários de validação foram integrados. ABI do core, capacidades gráficas, recursos reais, logger concorrente/frame, Play, persistência atômica e UI continuam pendentes.
- **P04/P05/P06/P07/P09:** builds legados/dependências de plataforma, GPU/reflexão/jobs/VM e API pública continuam com bloqueios registrados.
- **P16:** execução nativa Windows e CI completa das aplicações não foram obtidas; cross-compilação não substitui essas verificações.

Contratos aprovados: `docs/PROJECT_SCHEMA_V1.md`, `docs/PRESETS_SCHEMA_V1.md`. Estrutura-alvo e tarefas com responsáveis: `docs/APPLICATION_LAYOUT.md` e `docs/ADR-001-editor-runtime.md`.

## Bootstrap e protocolo (segunda fatia)

- `cli.zig`: argumentos estritos compartilhados e modos explícitos.
- `logging.zig`: encoder fixo de JSON lines e sink síncrono de bootstrap, não logger de frame.
- `jsonl.zig`: enquadramento incremental, limites e validação do envelope recebido.
- `distribution.zig`: recursos instalados relativos ao executável; manifesto fixado no build e SHA-256 da tabela.
- `fingerprint.zig`: identidade dos valores normalizados completos, sem sessão/relógio/CWD.
- `bootstrap.zig`: orquestração comum para duas entradas separadas, sem core/renderer fictícios.
- `platform_ext/process.zig` + `process_native.c/.h`: captura simultânea limitada dos pipes, prazo e propriedade/reap do filho imediato. `runCommand` também atende tooling com executável absoluto, argv e cwd explícitos; não usa shell nem supervisiona descendentes. Diferenças POSIX/Windows isoladas. Esse módulo C privado também é compilado com `-std=c23`.

CLI, códigos de saída, exemplos e restrições: `docs/APPLICATION_CLI.md`. Decisões e regressão de cancelamento resolvida: `docs/ADR-002-validation-bootstrap.md`. Não executar programas não confiáveis com `--check-runtime`; não há sandbox ou supervisão de árvores de subprocessos.

## Perfil desktop e schema v2

`scope.zig` centraliza a elegibilidade por SO, distinta de capacidade/implementação GPU. `project.zig` mantém compatibilidade v1 e valida v2 (Vulkan/OpenGL/D3D11/D3D12). `fingerprint.zig` agora usa versão 2 e inclui `desktop-3d-canvas-v1`. Não há modo de cena 2D, Metal/WebGPU executáveis ou suporte de produto macOS. Decisões e matriz: ADR-003; contrato: PROJECT_SCHEMA_V2.md.
