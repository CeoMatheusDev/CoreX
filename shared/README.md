# CoreX — contratos compartilhados de aplicação

**Implementado nesta etapa:** módulo Zig 0.17.0 reutilizável de documentos `.proj` v1, presets e DTO interno Zig↔C23. **Não são ainda os executáveis Editor/Runtime.** Não depende de janela, GPU, Lua ou dos builds legados.

## Build e testes

Com Zig 0.17.0 instalado:

```sh
cd shared
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build check -Dtarget=x86_64-windows-gnu -j2 --summary all
```

`check` compila os testes para outro alvo sem executá-los. **Não equivale a teste nativo Windows.** O primeiro cross-link pode demorar por compilar o CRT.

Sem Zig no PATH, use um ambiente virtual Python fora do repositório e instale a distribuição exata, com hashes das wheels:

```sh
# Na raiz do repositório, com um ambiente virtual já ativado:
python -m pip install --require-hashes --only-binary=:all: -r tools/zig-requirements.txt
python -m ziglang version
cd shared
python -m ziglang build test --summary all
```

A distribuição fixada oferece wheels Linux/macOS. Não foi encontrada wheel Windows para 0.17.0; suporte nativo de CI Windows continua pendente (P16). Não adotar outra versão de Zig silenciosamente.

Para invocar o runner diretamente, incluindo C23:

```sh
cd shared
zig test -I . -lc root.zig -cflags -std=c23 -Wall -Wextra -Werror -- graphics_abi.c
```

Na raiz:

```sh
python tools/check_contract_fixtures.py
zig fmt --check shared
c++ -std=c++20 -fno-rtti -fno-exceptions -Wall -Wextra -Werror -fsyntax-only -x c++ shared/graphics_abi.h
```

O workflow `shared-contracts.yml` configura Debug/ReleaseSafe em Linux/macOS e cross-compilação Windows. Ainda não foi executado no GitHub nesta sessão. Não é a matriz final de CI das duas aplicações.

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

27 testes locais passam em Linux, Debug e ReleaseSafe (ver relatório de progresso para a execução final). Incluem round-trip em memória com os papéis de Editor/Runtime, todos os presets, campos inválidos, duplicatas escapadas, erros de versão, exatidão decimal, ownership, limites, 256 mutações determinísticas e falhas de alocação injetadas. Também exercitam a ABI C23 real.

O teste denominado Editor→Runtime nesta fase usa dois consumidores do mesmo módulo **no mesmo processo de teste**. Integração entre executáveis/processo filho, stdout/stderr JSON lines, snapshots ZyntraUI e GPU real continuam não implementados.

Limitações explícitas:

- **P14:** NFC completa indisponível: caminhos não ASCII retornam `UnicodePathNormalizationUnavailable` (fail-closed). Metadados/nome de projeto UTF-8 são aceitos. Não é implementação completa do conjunto de caminhos admitido pelo schema.
- **P14:** caminhos só são validados lexicalmente. Links, caixa real, permissões, existência, contenção no filesystem e segurança contra corrida de substituição exigem `platform_ext`. Resultado de parse não autoriza leitura/escrita/execução de recursos.
- **P15:** manifesto/hash da distribuição, versão/ABI do core, capacidades gráficas, resolução de recursos, logs, CLI, persistência atômica e binários ainda não foram integrados.
- **P04/P05/P06/P07/P09:** builds legados/dependências de plataforma, GPU/reflexão/jobs/VM e API pública continuam com bloqueios registrados.
- **P16:** execução nativa Windows e CI completa das aplicações não foram obtidas; cross-compilação não substitui essas verificações.

Contratos aprovados: `docs/PROJECT_SCHEMA_V1.md`, `docs/PRESETS_SCHEMA_V1.md`. Estrutura-alvo e tarefas com responsáveis: `docs/APPLICATION_LAYOUT.md` e `docs/ADR-001-editor-runtime.md`.
