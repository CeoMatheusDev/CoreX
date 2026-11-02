# ADR-004 — abertura de projeto e splash do Editor

- Estado: requisito definido; implementação **parcial**.
- Escopo: Windows/Linux, Editor 3D e UI/Canvas. Não adiciona Hub ou Editor 2D.

## Comportamento desejado

O `.proj` é a entrada obrigatória do Editor. Ao abrir um arquivo associado ao CoreX, o sistema deve iniciar o Editor com o caminho como **um único argumento**, sem shell ou interpolação. Sem projeto, o Editor deve informar um erro e não iniciar uma sessão vazia. A instalação da associação deve ser explícita e testada nos dois sistemas, sem alterar associações do usuário silenciosamente.

A abertura interativa deve apresentar uma splash com área de 800×600 e barra de progresso. O trabalho de leitura/validação do documento e de seus recursos deve ocorrer fora da thread de interface. O Editor só pode aparecer pronto para edição depois de concluir os carregamentos e inicializações obrigatórios; uma falha deve permanecer visível e não se transformar em sucesso ou projeto vazio.

## Fases e limites

1. Inicializar a janela pela stack de plataforma autorizada (Zigway) e a UI real (ZyntraUI), mantendo a thread de interface responsiva.
2. Resolver e ler o `.proj`, validar schema e obter o conjunto de recursos. `editor/src/project_preflight.zig` já implementa uma tarefa concorrente **apenas para o documento**, testada isoladamente; o bootstrap existente ainda não a utiliza. O estado `document_validated` não significa cena, assets, scripts, GPU ou Editor carregados.
3. Descobrir e carregar recursos reais com limites de arquivo/memória, tratamento seguro de paths e links, cancelamento e diagnóstico por arquivo. Os formatos e loaders de cena/assets ainda não estão implementados. Não executar scripts ou código de projeto durante uma simples validação de documento.
4. Inicializar serviços reais do Editor, publicar sucesso somente após todas as etapas obrigatórias e substituir a splash pela janela do Editor. Fechar a splash deve cancelar, aguardar/recolher workers e liberar dados; falhas não podem exibir 100% ou `editor.ready`.

Progresso deve corresponder a trabalho concluído. Enquanto o total de recursos ainda é desconhecido, usar indicação indeterminada; quando conhecido, fixar o denominador ou outra política monotônica verificável. Não simular porcentagens nem prometer que bytes lidos equivalem a assets decodificados. A UI deve receber snapshots sincronizados dos workers e ser atualizada apenas pela thread dona da janela. O tamanho, comportamento DPI, foco, apresentação de erros e cancelamento precisam de testes nativos Windows/Linux.

## Disponível nesta etapa

- A CLI do Editor aceita um `.proj` posicional, como recebido em abertura por associação, além de `--project`. Dois caminhos são recusados; Runtime não ganha esse atalho. Sem projeto continua retornando erro.
- `exemploproject/Example.proj` é um documento schema v2 real para testes de validação. Suas pastas existem, mas não há cena funcional inventada nem loader de recursos.
- Uma tarefa Zig executa leitura e parsing do `.proj` concorrentemente, publica estágios atômicos e transfere o documento ou falha ao consumidor. Ela não é usada pela execução normal até que exista orquestração/UI real; cancelamento é cooperativo e aguarda o worker.
- `editor/src/project_opening.zig` experimenta uma máquina de estados para coordenar o preflight real com uma lista fixa de até 65.536 recursos. A descoberta é indeterminada; cada ticket concluído conta uma única vez e a inicialização reserva a última etapa. Falhas/cancelamento não anunciam sucesso. Os eventos de recursos e de prontidão são **sintéticos nos testes**: o coordenador depende de chamadas corretas do futuro loader e não verifica arquivos nem inicializa o Editor. Ainda não está integrado à execução normal ou a uma UI.
- O coordenador tem dono único; snapshots não são sincronizados para acesso concorrente. `cancel` e `deinit` aguardam o worker, e até a coleta após estágio terminal pode aguardar o término da thread: integrar com UI exigirá uma estratégia sem bloquear o loop de eventos.
- Testes Zig executam a CLI real em instalação temporária, verificam a entrada posicional e erros, e testam a tarefa concorrente e invariantes do coordenador. Não registram associação no SO nem criam uma janela.

## Pendências para cumprir o requisito

- Splash real, barra e tratamento de fechamento/erros com Zigway/ZyntraUI; integração dos workers ao loop da UI.
- Formato e carregamento real de cena, assets e scripts, com regras seguras de resolução e limites; estágio de inicialização do Editor e gate de prontidão.
- Associação `.proj` instalável no Windows e Linux, com tratamento correto de caminhos, testes de abertura por duplo clique e sem substituir escolhas existentes sem autorização.
- Testes de interface e cancelamento nativos em Windows e Linux. Cross-compilação não comprova comportamento de janela/associação.

Até lá, a execução gráfica normal segue retornando `application.core_unavailable`; `--validate-only` nunca comprova que os arquivos do projeto foram carregados.
