# Ferramentas auxiliares Python

Este diretório contém **somente ferramentas de desenvolvimento, teste e CI**. Nenhum módulo daqui é importado pelo Editor, Runtime ou pelo core.

## Isolamento obrigatório

- Use um ambiente virtual local em `tools/.venv/`; não instale pacotes Python no sistema.
- A única dependência Python de terceiros é `ziglang==0.17.0`, fixada com hashes em [requirements-zig.txt](requirements-zig.txt).
- O ambiente virtual, caches e bytecode são ignorados pelo Git.
- Os scripts restantes usam apenas a biblioteca padrão do Python.
- O Editor/Runtime distribuído não precisa de Python nem do ambiente virtual.

Na raiz do repositório, em Linux:

```sh
python3 -m venv tools/.venv
tools/.venv/bin/python -m pip install --require-hashes --only-binary=:all: -r tools/python/requirements-zig.txt
tools/.venv/bin/python -m ziglang version
```

O comando deve reportar exatamente `0.17.0`. Não instale dependências globalmente nem reutilize o ambiente virtual de outro projeto.

## Ferramentas

| Arquivo | Responsabilidade |
|---|---|
| `prepare_legacy_deps.py` | Baixa e verifica os arquivos de release fixados e prepara o cache Zig. |
| `test_prepare_legacy_deps.py` | Testes offline do extrator/verificador de arquivos TAR. |
| `check_contract_fixtures.py` | Verifica igualdade dos exemplos, schemas e SHA-256 dos presets. |
| `check_application_targets.py` | Verifica que alvos fora do produto são recusados pelo build. |
| `test_bootstrap.py` | Testes de integração entre os executáveis Editor e Runtime. |
| `ci_capture.py` | Encaminha saída de comandos na CI e limita o diagnóstico de falha. |

Execute a partir da raiz:

```sh
tools/.venv/bin/python tools/python/check_contract_fixtures.py
tools/.venv/bin/python tools/python/test_prepare_legacy_deps.py
tools/.venv/bin/python tools/python/prepare_legacy_deps.py
```

Os testes de integração exigem que `editor/` e `runtime/` tenham sido compilados antes:

```sh
tools/.venv/bin/python tools/python/test_bootstrap.py
```

## Fronteira arquitetural

`tools/python/` não é parte da engine, não é uma API pública e não pode ser dependência de runtime. Novos recursos do produto devem ser implementados em Zig/C/C++; Python só deve ser adicionado aqui quando houver justificativa concreta para automação ou validação externa. Não adicionar importações Python a scripts de inicialização, builds de distribuição ou executáveis do produto.
