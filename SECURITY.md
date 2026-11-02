# Política de segurança

## Versões suportadas

O CoreX está em desenvolvimento inicial e ainda não possui uma política formal de versões suportadas. Correções de segurança serão avaliadas conforme o estado da branch principal e a capacidade de reproduzir o problema.

## Reportar uma vulnerabilidade

**Não publique detalhes de uma vulnerabilidade não corrigida em uma issue pública.**

Use a opção **Private vulnerability reporting** na aba Security do repositório, caso esteja habilitada. Se a opção não estiver disponível, entre em contato diretamente com o mantenedor por um canal privado listado no perfil GitHub. Não inclua exploits funcionais, credenciais ou dados pessoais em discussões públicas.

Inclua, quando possível:

- resumo do impacto e dos componentes afetados;
- versão, commit ou branch reproduzível;
- plataforma, arquitetura e configuração;
- passos mínimos para reproduzir;
- logs sanitizados, crash dump reduzido ou PoC não destrutiva;
- avaliação de pré-condições e possível mitigação.

Não envie segredos reais, tokens, chaves privadas ou dados de terceiros.

## Escopo de segurança

Áreas relevantes incluem parsing de arquivos de projeto e presets, limites de memória/entrada, resolução de caminhos e symlinks, execução de processos filhos, ABI nativa, carregamento futuro de assets/scripts e gerenciamento de recursos.

O modo de verificação Editor → Runtime executa um binário indicado pelo usuário. Ele não é sandbox e não deve ser usado para executar binários não confiáveis.

## Processo de resposta

O mantenedor fará o possível para:

1. confirmar o recebimento;
2. reproduzir e classificar o impacto;
3. definir uma correção ou mitigação;
4. validar a correção;
5. coordenar a divulgação após a mitigação estar disponível.

Não há SLA de resposta ou prazo de correção garantido neste estágio do projeto.
