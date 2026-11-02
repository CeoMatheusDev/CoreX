# ADR-004: integração da janela com Vulkan Surface

- **Status:** bloqueado; nenhuma integração Vulkan implementada.
- **Auditoria:** 2026-11-02.
- **Escopo de plataforma CoreX:** Windows e Linux.

## Diagnóstico do repositório

A árvore gráfica legada (`src/graphics/`) contém apenas `renderer/render.zig` e `backends/null.zig`. O Null Backend não cria device nem apresenta imagens. `shared/graphics_abi.{h,c,zig}` é um DTO/validador de parâmetros, não API de Engine nem fronteira Vulkan; sua ABI C23 permanece independente.

Editor e Runtime são executáveis separados que dependem de `shared`; seus `build.zig` não importam Zigway nem a árvore `src/` legada. O executável legado da raiz importa Zigway e usa Null Backend, mas `src/core/engine.zig` é apenas um ciclo de vida mínimo. Não há hoje um módulo privado comum de Engine/graphics consumido por Editor e Runtime. Portanto, adicionar um backend somente à árvore legada não o integraria às aplicações atuais.

`docs/ARCHITECTURE.md` descreve um pipeline gráfico conceitual. `docs/STATUS.md` também contém itens históricos que não comprovam GPU: a implementação verificável nesta auditoria continua sendo Null-only. A validação `.proj`/bootstrap compartilhado não abre janela nem inicializa gráficos.

## API real e ownership do Zigway fixado

O pin é `v0.1.0-alpha.4`, hash `zigway-0.1.0-alpha.4-J1VBH_6UDAB_K4K2qoaGf3VkKqRxg2T5tgKqJzWQsJ_P`, em `build.zig.zon`. `zigway.Window` público é um handle lógico `{ id, *Platform }`; `Window.deinit()` pede a destruição à `Platform`. `Platform.deinit()` destrói janelas ainda registradas e então encerra seu backend. Não existe API pública `nativeHandle`, `nativeWindowInfo`, lista de extensões Vulkan nem criação de Vulkan Surface.

Os recursos existem somente no estado privado dos backends:

| Plataforma/backend | Recursos internos observados | Extensão Vulkan de Surface correspondente |
| --- | --- | --- |
| Win32 | `Backend.instance` (`HINSTANCE`) e `Entry.hwnd` (`HWND`); o registro mantém ponteiro nativo internamente | `VK_KHR_surface` + `VK_KHR_win32_surface` |
| Linux/X11 | `Backend.display` (`Display*`) e janela X11 (`Window`/XID) no backend/registro | `VK_KHR_surface` + `VK_KHR_xlib_surface` |
| Linux/Wayland | conexão e `WindowEntry.surface` (`wl_surface*`) privados no backend | `VK_KHR_surface` + `VK_KHR_wayland_surface` |

A escolha automática Linux pode usar X11 ou Wayland. Um XID isolado não substitui `Display*`; um `wl_surface*` isolado não substitui a conexão `wl_display*`; e um handle lógico Zigway não é nenhum desses recursos. Ler campos privados/registro ou duplicar uma janela pela API nativa para contornar isso seria frágil, não suportado e violaria o ownership atual. A Surface Vulkan deve ser propriedade CoreX, referenciar uma janela Zigway emprestada e ser destruída antes da Instance; a Surface nunca destrói a janela. Zigway continuaria responsável por criar/destruir janela, conexão/instância de plataforma e handles nativos.

A documentação `zig-pkg/zigway-.../docs/GRAPHICS.md` atribui a uma futura integração da plataforma a exposição das extensões e criação/lifetime da Surface; o roadmap lista graphics integration em v0.4.x. A API fixada não implementa esse contrato.

A consulta à API do GitHub em 2026-11-02 encontrou somente releases/tags até `v0.1.0-alpha.4`; `main` está no commit `8068f95b60d349237b86574aa045b6db297100d7`, o próprio release alpha.4. Não há versão futura publicada para atualizar e auditar. Nenhum pin/hash foi alterado.

## Alternativas avaliadas

| Alternativa | Viabilidade técnica | Decisão nesta etapa |
| --- | --- | --- |
| Consumir uma versão futura de Zigway com integração Vulkan real | É a rota de menor duplicação se a versão expuser handles/extensões e lifecycle por janela; tal release/API não existe no upstream consultado. | Não implementável agora; aguardar API publicada e auditar API, licença, changelog, lifecycle e testes antes de atualizar pin. |
| Alteração upstream mínima e auditada | Viável: propor API pública de informação nativa emprestada por janela, discriminada por backend (`HINSTANCE/HWND`, `Display*/XID`, `wl_display*/wl_surface*`) e extensão requerida; sem dependência Vulkan nem propriedade de Surface dentro de Zigway. Handles válidos somente enquanto janela/Platform vivem e usados na thread proprietária. CoreX cria/destrói Surface. | Alternativa recomendada para preservar Zigway como dono da janela sem acoplar o Renderer ao Zigway. Requer revisão/aceite upstream, release/versionamento e aprovação explícita de novo pin/hash. Ainda não há patch nem aprovação. |
| Integração complementar nativa CoreX reutilizando a janela Zigway atual | Não é viável pela API pública atual: CoreX não consegue obter os handles corretos. Inspecionar os campos privados ou inferir a janela pelo sistema operacional é inseguro. | Rejeitada enquanto a janela for criada por Zigway sem accessor público. |
| Backend de janela nativo próprio CoreX (Win32/X11/Wayland) | Tecnicamente viável, mas substitui/bypassa Zigway e duplica criação, eventos, resize, minimização e lifecycle; X11 e Wayland exigem adaptadores distintos. | Não escolhida: maior superfície de código e divergência de janela sem necessidade demonstrada. Poderá ser reavaliada se upstream recusar a extensão mínima. |

A proposta upstream deve manter a infraestrutura gráfica interna CoreX sem tipos Zigway: um adaptador de janela converte a informação nativa emprestada para um contrato privado do Engine; Vulkan Backend recebe esse contrato, coleta/valida as extensões e cria Surface. Nenhum backend Vulkan deve acessar internals Zigway.

## Ownership proposto (não implementado)

1. O adaptador de plataforma cria `Zigway.Platform` e a janela; Zigway é dono da conexão nativa, da janela e de seus handles.
2. O Engine/Graphics Backend cria e possui `VkInstance` e, quando habilitado, Debug Messenger.
3. O Backend cria `VkSurfaceKHR` a partir do descritor nativo emprestado; CoreX possui e destrói a Surface. A Surface não destrói a janela nem fecha conexão/display.
4. O Backend escolhe e possui `VkDevice`, filas, Swapchain, Image Views, semaphores, fences, command pools/buffers.
5. Encerramento: parar submissões e recolher trabalho pendente; destruir recursos da Swapchain; destruir `VkDevice`; destruir `VkSurfaceKHR`; destruir Debug Messenger; destruir `VkInstance`; só então destruir a janela e `Zigway.Platform`. Falhas parciais desfazem na ordem inversa dos recursos efetivamente criados.

Esse lifecycle é orientação para a implementação futura, não uma interface ou implementação existente.

## Bloqueio de validação Vulkan neste ambiente

Auditoria local em 2026-11-02, Zig `0.17.0`:

- Não foi encontrado Vulkan Loader (`libvulkan.so`/`vulkan-1.dll`), header Vulkan (`vulkan.h`/`vulkan_core.h`), configuração ICD ou `vulkaninfo`.
- Não estão disponíveis `pkg-config`/`pkgconf`, `glslangValidator`, `glslc`, `spirv-val`, `spirv-opt` ou `dxc`.
- `/dev/dri` está ausente; não há dispositivos GPU visíveis. `DISPLAY`, `WAYLAND_DISPLAY` e `XDG_RUNTIME_DIR` não estão configurados e não há socket X11 ativo. `ldd` nos binários Editor/Runtime mostra apenas libc/libm, sem loader Vulkan.
- A compilação/execução nativa Windows não está disponível neste host Linux; cross-compilation não seria teste de janela/Surface.

Assim não é possível validar a Instance com loader real, Surface, seleção de dispositivo/capacidades, Device/filas, Swapchain, aquisição/apresentação, resize ou liberação contra driver. **Não houve smoke test gráfico e nenhum frame Vulkan foi apresentado.** Nenhum stub, declaração Vulkan fictícia ou backend dito funcional foi criado.

## Próximos bloqueios a remover

1. Acordar com Zigway a API mínima acima (ou escolher formalmente um backend de janela próprio); só atualizar pin/hash depois da aprovação, revisão de licença/compatibilidade e testes Windows + Linux X11/Wayland.
2. Disponibilizar ambiente nativo de integração com Zig 0.17.0, Vulkan Loader/SDK, ICD/driver e GPU, janela/sessão X11 ou Wayland; preparar também execução real em Windows para o caminho Win32.
3. Criar módulo privado comum do Engine usado por Editor/Runtime e só então integrar ciclo de vida Vulkan sem colocar dependências gráficas em `shared`.
4. Validar Instance → Surface → Physical Device → Logical Device/queues → Swapchain → acquire/submit/present → resize/recreate → teardown e executar smoke test de frames apresentados antes de declarar backend funcional.

Até esses bloqueios serem resolvidos, esta etapa de integração Vulkan permanece **não concluída**. O Null Backend segue exclusivamente headless; nenhuma qualidade/pipeline dos Renderers Advanced, Standard ou Lite foi antecipada.
