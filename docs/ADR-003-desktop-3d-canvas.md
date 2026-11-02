# ADR-003 — Windows/Linux, autoria 3D e UI/Canvas

- Data: 2026-11-01. Estado: adotado conforme correção explícita de escopo do usuário.
- Responsáveis: aplicações (política/modelo de autoria), Build/CI (alvos), core/renderer (implementações GPU), plataforma/UI (Zigway/ZyntraUI).
- Precedência: substitui as referências a macOS e à matriz Vulkan/WebGPU/D3D12/Metal dos ADRs anteriores. Os demais limites continuam válidos.

## Decisões, alternativas e consequências

1. **Produto apenas Windows/Linux.** Vulkan e OpenGL são intenções nos dois; D3D11/D3D12 apenas no Windows. Nomes canônicos: `vulkan`, `opengl`, `d3d11`, `d3d12`. Não usar DXVK/Wine nem trocar automaticamente backend. Elegibilidade por SO não comprova extensão, feature level, driver, implementação do core ou criação de device. A política é pura, sem alocação; consulta/criação real permanece dependência do core. Builds de aplicações recusam outros alvos, e CI remove macOS. Testes cruzados Windows não serão chamados de execução nativa.
2. **Dois domínios de autoria:** `scene_3d` e `ui_canvas`. Não haverá modo de cena 2D, tilemap, física 2D ou pipeline de sprites de gameplay nesta entrega. Coordenadas, retângulos, fontes e clipping 2D continuam necessários ao Canvas/UI; excluí-los impediria o requisito. A máquina de ferramentas do Editor recusa ferramentas incompatíveis antes de alterar estado e reinicia a ferramenta ao trocar de domínio. É modelo de interação testável, não um painel gráfico já ligado ao core.
3. **Schema v2 em vez de alterar v1 silenciosamente.** V1 permanece legível/serializável com sua enumeração antiga, para inspeção e migração explícita. V2 usa apenas os quatro backends do escopo novo. A estrutura restante e os presets não mudam. V1 com Metal/WebGPU pode ser validado como documento histórico, mas nunca executado neste produto. V1 não passa a aceitar OpenGL/D3D11. Não converter nem salvar automaticamente documentos; Runtime continua somente leitor. Alternativas rejeitadas: mudar enumeração de v1 em lugar (quebra de contrato já publicado), reinterpretar backend removido ou fazer downgrade (oculta divergência).
4. **Validação não é execução.** `--validate-only` permite inspecionar configuração de outro SO, inclusive D3D no Linux, e registra a decisão de elegibilidade do host e os flags de serviços não ligados. Execução normal verifica a política antes de criar qualquer recurso e falha com causa específica; backend permitido também falha enquanto não houver adaptador real. O fingerprint sobe para v2 e inclui o identificador do perfil; um binário antigo não pode confirmar silenciosamente o perfil novo.
5. **Autorização para melhorias nas bibliotecas, sem fork especulativo.** Zigway permanece única stack de janela/input; ZyntraUI permanece toolkit de UI. Podemos corrigir/estender ambos quando um teste reproduzível comprovar limitação. Fixar commit/hash, licença, teste e patch de upstream antes de consumir mudança; não trocar dependências silenciosamente. Não implementar renderers do core dentro do toolkit para esconder serviço ausente.

## Inspeção concreta

No checkout, `src/graphics/renderer/render.zig` instancia apenas `NullBackend`: nenhum dos quatro renderers GPU está integrado. No Zigway v0.1.0-alpha.4, `docs/BACKENDS.md` e os diretórios Win32/X11/Wayland descrevem janelas/input; isso não implementa renderers Vulkan/D3D/OpenGL. No ZyntraUI v1.44.1, `src/viewport3d/raster.zig` declara rasterização **em software, sem GPU**. Sua demonstração não substituirá o viewport real do core. Nenhuma alteração upstream foi necessária para implementar a política/modelo desta fatia, portanto não há fork ou PR de biblioteca artificial.

Fontes inspecionadas: `https://github.com/CeoMatheusDev/Zigway/blob/v0.1.0-alpha.4/docs/BACKENDS.md`, `https://github.com/CeoMatheusDev/ZyntraUI/blob/v1.44.1/src/viewport3d/raster.zig`.

## Pendências com responsáveis

- **P05 (core/renderer):** Vulkan/OpenGL Windows/Linux, D3D11/D3D12 Windows; capacidades antes do device, superfície Zigway, viewport e draw commands reais. Nada disso é declarado funcional nesta fatia.
- **P08 (plataforma/UI):** validar interop real de superfície e input/DPI/texto nas versões fixadas; corrigir Zigway/ZyntraUI com testes quando houver reprodução. Antiga paridade macOS foi retirada do escopo, não está bloqueando Windows/Linux.
- **P10/P15 (aplicações):** conectar o modelo de ferramentas aos painéis ZyntraUI, transações de cena/Canvas, persistência atômica e Play completo.
- **P16 (Build/CI):** toolchain Windows 0.17.0 verificável e execução nativa Windows; atualização das actions. macOS deixa de ser alvo de produto/CI.
- **P14/P09/P11/P12/P13:** permanecem as responsabilidades de filesystem/NFC, ABI/gameplay, reload e testes GPU dos ADRs anteriores.
