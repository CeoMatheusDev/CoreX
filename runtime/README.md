> **Perfil de produto:** Windows/Linux, 3D e UI/Canvas, sem cena 2D. APIs previstas: Vulkan/OpenGL; D3D11/D3D12 somente Windows. Elegibilidade não comprova renderer implementado. ADR-003 detalha a política.

# CoreXRuntime — bootstrap de validação

Executável independente em Zig **0.17.0** + C23. **Ainda não executa jogos.** Não liga o core nem cria janela/device; Zigway continua sendo a stack obrigatória quando a integração gráfica for implementada.

## Build

```sh
cd runtime
zig build
zig build test
```

Importa `../shared`, compila C com `-std=c23` e instala `zig-out/bin/CoreXRuntime` (Windows: `.exe`) com `zig-out/share/corex/{distribution.json,presets.zon}`. Instalação incompleta/corrompida é erro, sem fallback em CWD/projeto.

## Uso (na raiz do repositório)

```sh
runtime/zig-out/bin/CoreXRuntime --project docs/examples/EmptyGame.proj --headless --validate-only
```

Esse comando lê o schema compartilhado, confere a identidade da distribuição, resolve o preset/overrides, valida o DTO C23 e emite logs JSON lines com os parâmetros concretos. Emite `runtime.validation_complete`, **nunca `runtime.ready`**. O modo não carrega cena/assets/scripts, negocia ABI do core, consulta GPU ou simula ticks. O sucesso vale apenas para documento/presets.

Sem `--validate-only`, inclusive com `--headless`, retorna erro de core indisponível (exit 4). Isso evita que uma simulação vazia seja apresentada como Player funcional. C++/Lua, loop fixed timestep, job system, hot reload e UI de jogo continuam pendentes; nenhuma UI de Editor é incorporada.

O Runtime nunca grava `.proj`. Códigos de saída, opções e protocolo: [APPLICATION_CLI.md](../docs/APPLICATION_CLI.md). Testes reais Editor→Runtime: `python tools/test_bootstrap.py` na raiz após compilar ambos. Testes nativos Windows ainda não estão disponíveis; cross-compilação não substitui execução nativa.
