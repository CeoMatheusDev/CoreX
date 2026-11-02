# Guia de início

Este guia prepara um ambiente de desenvolvimento e executa os testes/validadores atualmente disponíveis. O sucesso dos comandos de validação não significa que o CoreX já execute jogos.

## 1. Requisitos

- Zig 0.17.0.
- Python 3 para scripts auxiliares.
- Toolchain C23 e linker compatíveis com o alvo.
- Linux: dependências de desenvolvimento necessárias pelo build que será executado.

Não substitua a versão do Zig silenciosamente. O projeto fixa APIs e dependências para uma versão específica.

## 2. Obter o código

```sh
git clone https://github.com/CeoMatheusDev/CoreX.git
cd CoreX
```

## 3. Executar testes dos contratos compartilhados

```sh
cd shared
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
cd ..
```

O pacote compartilhado testa parsing/validação dos documentos, presets, resolução, ownership, limites e DTO C23. Consulte shared/README.md para a API e cobertura detalhadas.

## 4. Compilar Editor e Runtime

```sh
cd editor
zig build
zig build test --summary all
cd ../runtime
zig build
zig build test --summary all
cd ..
```

Cada aplicação instala seu executável e os recursos de distribuição em seu próprio diretório zig-out. Mantenha binário e diretório share/corex juntos ao mover a instalação.

## 5. Validar um projeto

```sh
runtime/zig-out/bin/CoreXRuntime \\
  --project docs/examples/EmptyGameV2.proj \\
  --headless --validate-only
```

O modo valida o documento, a distribuição e os parâmetros de preset. Não carrega cena, assets ou scripts, não cria dispositivo gráfico e não inicia simulação.

Para executar a validação cruzada do Editor contra o Runtime:

```sh
editor/zig-out/bin/CoreXEditor \\
  --project docs/examples/EmptyGameV2.proj \\
  --headless --validate-only \\
  --check-runtime "$PWD/runtime/zig-out/bin/CoreXRuntime"
```

O caminho do Runtime precisa ser absoluto. Esse comando inicia o processo indicado e, portanto, só deve ser usado com um executável confiável. Não é um mecanismo de sandbox.

## 6. Scripts de verificação

```sh
python tools/check_contract_fixtures.py
python tools/test_bootstrap.py
```

O teste de bootstrap requer os dois executáveis compilados. Os testes e seus limites estão descritos em APPLICATION_PROGRESS.md e APPLICATION_CLI.md.

## 7. Core legado

O build da raiz é independente dos pacotes editor/, runtime/ e shared/. Ele possui dependências e limitações próprias, incluindo o backend Null e subsistemas ainda incompletos. Consulte o README principal e o workflow legacy-core antes de executar essa parte.

## 8. Próximos passos

- Leia [ARCHITECTURE.md](ARCHITECTURE.md).
- Revise [ADR-003](ADR-003-desktop-3d-canvas.md) antes de propor mudanças no escopo.
- Consulte [APPLICATION_PROGRESS.md](APPLICATION_PROGRESS.md) para não duplicar trabalho nem assumir capacidades inexistentes.
- Siga o [guia de contribuição](../CONTRIBUTING.md) ao preparar alterações.
