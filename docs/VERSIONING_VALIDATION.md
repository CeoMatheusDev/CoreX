# Procedimentos de validação do versionamento CoreX

Esta página registra comandos reproduzíveis para a infraestrutura atual. A validação Linux desta rodada está em [`APPLICATION_PROGRESS.md`](APPLICATION_PROGRESS.md); este documento não transforma cross-compilation em execução nativa.

## Linux — build completo local

Use Zig 0.17.0 instalado pelo script versionado. Em ambientes onde o parser de DNS do Zig exigir newline em `/etc/resolv.conf`, não edite a configuração do host: use uma montagem temporária em namespace privado com o mesmo conteúdo e apenas LF final. O build legado Linux também precisa do link de desenvolvimento X11; quando só a biblioteca runtime `libX11.so.6` existir, pode-se usar um symlink temporário em `LIBRARY_PATH`, sem alterar `/usr`.

```sh
set -eu
zig version                         # deve ser 0.17.0
zig fmt --check build.zig src/core/version.zig shared editor runtime tools/zig
zig build --summary all             # CoreXEngine Debug
zig build test --summary all
zig build -Doptimize=ReleaseSafe --prefix /tmp/corex-release --summary all
zig build test -Doptimize=ReleaseSafe --summary all
/tmp/corex-release/bin/CoreXEngine --version
zig-out/bin/CoreXEngine --version

(cd shared && zig build test --summary all)
(cd shared && zig build test -Doptimize=ReleaseSafe --summary all)
(cd editor && zig build && zig build test --summary all)
(cd editor && zig build -Doptimize=ReleaseSafe && zig build test -Doptimize=ReleaseSafe --summary all)
(cd runtime && zig build && zig build test --summary all)
(cd runtime && zig build -Doptimize=ReleaseSafe && zig build test -Doptimize=ReleaseSafe --summary all)
(cd tools/zig && zig build && zig build test --summary all)
(cd tools/zig && zig build -Doptimize=ReleaseSafe --prefix /tmp/corex-tools-release && zig build test -Doptimize=ReleaseSafe --summary all)
```

Execute a partir da raiz, sem modificar `VERSION`:

```sh
tools/zig/zig-out/bin/corex-version validate
tools/zig/zig-out/bin/corex-version compare 0.1.0a1 0.1.0b1
before=$(cat VERSION)
tools/zig/zig-out/bin/corex-version bump beta --dry-run
test "$(cat VERSION)" = "$before"
tools/zig/zig-out/bin/corex-version release check
/tmp/corex-tools-release/bin/corex-version release check
editor/zig-out/bin/CoreXEditor --version
runtime/zig-out/bin/CoreXRuntime --version
python3 tools/test_bootstrap.py
```

Para comparar geração de manifesto sem reutilizar cache local, dê um `ZIG_LOCAL_CACHE_DIR` diferente a cada build, mantendo o cache global de pacotes Zig:

```sh
set -eu
mkdir -p /tmp/corex-cache-a /tmp/corex-cache-b /tmp/corex-out-a /tmp/corex-out-b
(cd editor && ZIG_LOCAL_CACHE_DIR=/tmp/corex-cache-a zig build --prefix /tmp/corex-out-a)
(cd editor && ZIG_LOCAL_CACHE_DIR=/tmp/corex-cache-b zig build --prefix /tmp/corex-out-b)
cmp /tmp/corex-out-a/share/corex/distribution.json /tmp/corex-out-b/share/corex/distribution.json
cmp /tmp/corex-out-a/share/corex/presets.zon /tmp/corex-out-b/share/corex/presets.zon
```

Compare também o campo `fingerprint` ao executar os dois binários contra o mesmo `.proj`. Não compare/declare os executáveis byte a byte reproduzíveis sem fazer essa comparação específica.

## Windows — execução nativa pendente

O bootstrap versionado `tools/install_zig.sh` e `tools/zig-requirements.txt` cobrem hosts Linux; o repositório não fornece um instalador verificado de Zig para Windows. Use somente uma distribuição Zig 0.17.0 cuja origem e hash tenham sido verificados pelo procedimento aprovado da equipe. Não substitua por outra versão para contornar um problema de instalação.

No PowerShell 7.3+, com `zig.exe` verificado e a raiz do checkout como diretório atual. A preferência abaixo faz comandos nativos com código diferente de zero interromperem o procedimento:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Zig = 'C:\Toolchains\zig-0.17.0\zig.exe'
if ((& $Zig version) -ne '0.17.0') { throw 'Zig 0.17.0 obrigatório' }

& $Zig fmt --check build.zig src/core/version.zig src/main.zig src/legacy_tests.zig shared editor runtime tools/zig
& $Zig build --summary all
& $Zig build test --summary all
& $Zig build -Doptimize=ReleaseSafe --prefix "$env:TEMP\corex-release" --summary all
& $Zig build test -Doptimize=ReleaseSafe --summary all

Push-Location shared; & $Zig build test --summary all; & $Zig build test -Doptimize=ReleaseSafe --summary all; Pop-Location
Push-Location editor; & $Zig build --summary all; & $Zig build test --summary all; & $Zig build -Doptimize=ReleaseSafe --summary all; & $Zig build test -Doptimize=ReleaseSafe --summary all; Pop-Location
Push-Location runtime; & $Zig build --summary all; & $Zig build test --summary all; & $Zig build -Doptimize=ReleaseSafe --summary all; & $Zig build test -Doptimize=ReleaseSafe --summary all; Pop-Location
Push-Location tools/zig; & $Zig build --summary all; & $Zig build test --summary all; & $Zig build -Doptimize=ReleaseSafe --prefix "$env:TEMP\corex-tools-release" --summary all; & $Zig build test -Doptimize=ReleaseSafe --summary all; Pop-Location

$Expected = (Get-Content VERSION -Raw).TrimEnd("`r", "`n")
if ((& .\zig-out\bin\CoreXEngine.exe --version) -ne $Expected) { throw 'CoreXEngine identity mismatch' }
if ((& .\tools\zig\zig-out\bin\corex-version.exe version) -ne $Expected) { throw 'corex-version mismatch' }
$BeforeDryRun = Get-Content VERSION -Raw
& .\tools\zig\zig-out\bin\corex-version.exe compare 0.1.0a1 0.1.0b1
& .\tools\zig\zig-out\bin\corex-version.exe bump beta --dry-run
if ((Get-Content VERSION -Raw) -ne $BeforeDryRun) { throw 'dry-run modified VERSION' }
& .\tools\zig\zig-out\bin\corex-version.exe release check
& "$env:TEMP\corex-tools-release\bin\corex-version.exe" release check
$Editor = (& .\editor\zig-out\bin\CoreXEditor.exe --version | ConvertFrom-Json).fields
$Runtime = (& .\runtime\zig-out\bin\CoreXRuntime.exe --version | ConvertFrom-Json).fields
if ($Editor.engine_version -ne $Runtime.engine_version -or $Editor.project_engine_version -ne $Runtime.project_engine_version) { throw 'Editor/Runtime identity mismatch' }
python tools/test_bootstrap.py
```

Execute os comandos `Push-Location` de `shared`, `editor`, `runtime` e `tools/zig` como fonte normativa. O Runtime e Editor devem ser executados a partir de suas árvores instaladas para testar caminhos dos recursos; `--version` não exige projeto nem manifesto. Adapte os caminhos de executáveis se o prefixo de instalação for diferente.

## Cross-compilation Windows (não é teste nativo)

Em Linux com Zig 0.17.0:

```sh
for package in shared editor runtime tools/zig; do
  (cd "$package" && "$ZIG_EXE" build check -Dtarget=x86_64-windows-gnu -j2 --summary all)
done
zig build check -Dtarget=x86_64-windows-gnu -j2 --summary all
```

Esses comandos compilam/linkam módulos e testes para o alvo Windows, mas não executam `.exe`.
