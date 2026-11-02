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
| Alteração upstream mínima e auditada | Viável: propor API pública de informação nativa emprestada por janela, discriminada por backend (`HINSTANCE/HWND`, `Display*/XID`, `wl_display*/wl_surface*`) e extensão requerida; sem dependência Vulkan nem propriedade de Surface dentro de Zigway. Handles válidos somente enquanto janela/Platform vivem e usados na thread proprietária. CoreX cria/destrói Surface. | **Rota escolhida pelo usuário em 2026-11-02.** Preservar como proposta upstream; requer revisão/aceite e release/versionamento antes de atualizar o pin/hash. Ainda não há patch aceito nem alteração de dependência. O ambiente Linux com GPU solicitado para validação ainda não está disponível neste workspace. |
| Integração complementar nativa CoreX reutilizando a janela Zigway atual | Não é viável pela API pública atual: CoreX não consegue obter os handles corretos. Inspecionar os campos privados ou inferir a janela pelo sistema operacional é inseguro. | Rejeitada enquanto a janela for criada por Zigway sem accessor público. |
| Backend de janela nativo próprio CoreX (Win32/X11/Wayland) | Tecnicamente viável, mas substitui/bypassa Zigway e duplica criação, eventos, resize, minimização e lifecycle; X11 e Wayland exigem adaptadores distintos. | Não escolhida: maior superfície de código e divergência de janela sem necessidade demonstrada. Poderá ser reavaliada se upstream recusar a extensão mínima. |

A proposta upstream deve manter a infraestrutura gráfica interna CoreX sem tipos Zigway: um adaptador de janela converte a informação nativa emprestada para um contrato privado do Engine; Vulkan Backend recebe esse contrato, coleta/valida as extensões e cria Surface. Nenhum backend Vulkan deve acessar internals Zigway.

### Auditoria do PR Zigway #8 (2026-11-02)

Foi encontrado `https://github.com/CeoMatheusDev/Zigway/pull/8`, aberto, branch `arena/5951ccdd-zigway`, HEAD `29b9c1482376ab725745af25b4ac27c972ec464e`, intitulado “feat(graphics): Vulkan surface integration (v0.4.x) + Wayland docs fix”. O PR declara criação de Surface para X11, Win32 e Wayland e consulta de extensões, mas agrupa ainda OpenGL/EGL, fora do escopo mínimo escolhido. A API de release/tag não mudou: a versão publicada continua `v0.1.0-alpha.4`; o PR não tem status checks reportados e não foi aceito/mesclado. Não atualizar o pin para o branch aberto. Tentei publicar uma revisão com os diagnósticos reproduzíveis; o GitHub respondeu `Resource not accessible by integration`, então nenhum comentário/review foi publicado.

Validação estática e pontual com Zig 0.17.0 encontrou falhas adicionais ao forçar análise dos métodos de criação de Surface (não cobertos pela suíte habitual): `VulkanSurface.native: *anyopaque` é não opcional, mas `isNull()` e caminhos de destroy comparam a `null`; `VkSurfaceKHR = opaque {}` é usado como parâmetro por valor em `DestroySurfaceKHRFn`, inválido em Zig; X11 aplica `orelse` ao campo `native_id: u64`; e Wayland aplica `orelse` ao campo `WindowEntry.surface: *wl_proxy`, também não opcional. Um teste mínimo que instancia `VulkanSurface.isNull()` falha em compilação (“comparison of '*anyopaque' with null”).

A análise sob instanciação também expôs incompatibilidades adicionais na camada ABI: `procAddr` recebe `?*VkInstance`, mas a função carregada está tipada para receber `*VkInstance`; `procAddr` repassa `[]const u8` onde o ponteiro Vulkan exige `[*]const u8`; os métodos de backend recebem `*anyopaque` e encaminham esse tipo sem conversão para a API tipada; e o criador Wayland lê `st.display`, embora `display` pertença a `Backend`, não a `State`. São diagnósticos de compilação/análise de código, não suposições sobre a execução Vulkan.

A suíte não contém testes diretos de criação/destruição de `VkSurfaceKHR`, e nenhuma execução live Vulkan foi realizada. Além disso, o caminho Wayland OpenGL/EGL está incompleto (`makeOpenGLCurrent`/`swapOpenGLBuffers` retornam erro e o handle não conserva a EGLSurface); excluir esse escopo é necessário para uma proposta Vulkan mínima.

### Resultado da validação estática com Zig 0.17.0

O executável Zig 0.17.0 foi obtido temporariamente via pacote `ziglang==0.17.0` em `/tmp`; nenhuma dependência nem arquivo do repositório foi alterado por isso. `zig test src/platform/vulkan.zig` passou (2/2), e `zig build test-win32-compile` passou (compilação cruzada somente; não é teste nativo Windows). O build oficial Zigway `zig build test -Dplatform=null_backend` não chegou aos testes: `linkNative` liga `X11` incondicionalmente e o host não tem o symlink de desenvolvimento `libX11.so` (há apenas `libX11.so.6`). Para separar o problema do linker, a suíte manual em `auto` passou **119/119**; com `null_backend`, **118/119** passaram porque `resolve auto on host` ainda espera `.x11`. A execução manual não validou runtime de janela/display nem Vulkan real.

### Correções locais dos adaptadores CoreX ↔ Zigway

Sem alterar o pin nem inferir handles nativos, tornei explícita a configuração headless na camada de integração: `Platform.init` mantém a seleção normal do Zigway, enquanto `initWithOptions` encaminha opções sem fallback implícito; o adaptador encaminha `backendKind`, `capabilities`, `createWindow`, polling/espera de eventos, consumo da fila e leitura de input/diagnóstico; e `Window.init` recebe o wrapper CoreX `Platform`, não a plataforma Zigway diretamente. Substituí `tests/test_zigway.zig`, que usava nomes/API inexistentes, por testes válidos e conectei-os como artifact separado ao passo `zig build test`. Os quatro testes cobrem seleção explícita null, preservação da validação de configuração, entrega de eventos/estado de input e ciclo de vida/double-deinit da janela lógica.

Validação contra Zigway `v0.1.0-alpha.4` e ZyntraUI `v1.44.1`, com ambos os hashes conferidos pelo `tools/prepare_legacy_deps.sh` usando archives oficiais: `zig build test --summary all` passou **25/25** em Debug e `zig build test -Doptimize=ReleaseSafe --summary all` passou **25/25**; `zig build -j2` compilou `CoreXEngine`; e `zig build validate -j2 --summary all` passou **9/9 passos**. Na execução completa, as suítes encadeadas passaram: tooling 46/46, Shared 62/62, Editor 36/36 e Runtime 16/16. São 21 testes legados + 4 testes CoreX–Zigway no passo raiz. Neste host foi necessário `LIBRARY_PATH` temporário apontando para o runtime `libX11.so.6` por faltar o symlink de desenvolvimento `libX11.so`; nenhuma janela foi aberta. `-Dplatform=null_backend` não é opção do build raiz e é rejeitada; os quatro testes de adapter selecionam `.null_backend` explicitamente, enquanto a seleção do restante da suíte permanece `auto`. Nenhum display ou GPU foi usado, portanto esses testes headless não validam janela nativa ou Vulkan.

## Ownership proposto (não implementado)

1. O adaptador de plataforma cria `Zigway.Platform` e a janela; Zigway é dono da conexão nativa, da janela e de seus handles.
2. O Engine/Graphics Backend cria e possui `VkInstance` e, quando habilitado, Debug Messenger.
3. O Backend cria `VkSurfaceKHR` a partir do descritor nativo emprestado; CoreX possui e destrói a Surface. A Surface não destrói a janela nem fecha conexão/display.
4. O Backend escolhe e possui `VkDevice`, filas, Swapchain, Image Views, semaphores, fences, command pools/buffers.
5. Encerramento: parar submissões e recolher trabalho pendente; destruir recursos da Swapchain; destruir `VkDevice`; destruir `VkSurfaceKHR`; destruir Debug Messenger; destruir `VkInstance`; só então destruir a janela e `Zigway.Platform`. Falhas parciais desfazem na ordem inversa dos recursos efetivamente criados.

Esse lifecycle é orientação para a implementação futura, não uma interface ou implementação existente.

## Bloqueio de validação Vulkan neste ambiente

Na continuação em `arena/c37dfcbd-corex`, Zig `0.17.0` foi executado a partir de instalação temporária em `/tmp` para validar arquivos do PR #8; o executável não foi instalado no PATH nem adicionado ao repositório. Os resultados pontuais e o bloqueio da suíte principal estão registrados acima. Os bloqueios Vulkan/host foram rechecados:

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
