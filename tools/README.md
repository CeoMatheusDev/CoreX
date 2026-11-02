# Ferramentas de desenvolvimento

As ferramentas auxiliares ficam separadas do código do produto.

- [Python tooling](python/README.md): scripts de validação, integração e CI, com ambiente isolado em `tools/.venv/`.
- Builds de Editor, Runtime e core são executados pela toolchain Zig. Nenhum executável do produto deve importar ou iniciar scripts deste diretório.
