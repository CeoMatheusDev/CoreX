# Projeto de exemplo

`Example.proj` é um documento CoreX schema v2 para testar a abertura e validação do projeto. As pastas `scenes`, `assets` e `scripts` são pontos de partida; seus arquivos README não são assets de jogo.

```sh
# Na raiz do repositório, após compilar editor/ com Zig 0.17.0:
editor/zig-out/bin/CoreXEditor exemploproject/Example.proj --headless --validate-only
```

Esta validação cobre o documento e a distribuição/presets, **não** carrega arquivos da cena, assets ou scripts. `scenes/Main.scene` é o caminho de inicialização reservado pelo documento, mas o formato de cena e seu loader ainda não foram implementados; o arquivo não é fornecido como cena funcional. O Editor gráfico e a splash ainda não estão disponíveis, portanto abertura normal retorna erro de core indisponível. A associação do `.proj` com o sistema operacional ainda precisa ser instalada/implementada; chamar com o caminho posicional por si só não registra essa associação.
