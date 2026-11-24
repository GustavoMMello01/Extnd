# Extnd

Projeto inicial de um app macOS para usar um iPad como segunda tela. A versão atual abre uma janela SwiftUI com uma apresentação do projeto e uma tela de informações. A conexão com o iPad, o streaming e o servidor ficam para etapas futuras.

## Abrir no Xcode

1. Abra `Extnd.xcodeproj`.
2. Selecione o esquema **Extnd** e o destino **My Mac**.
3. Pressione **⌘R** para executar ou **⌘U** para rodar os testes.

O projeto usa Swift 6, requer macOS 14.0 ou posterior e não tem dependências externas. O identificador do app é `io.extnd.Extnd`. A configuração local usa assinatura ad hoc, sem equipe de desenvolvimento.

Para compilar e testar pelo Terminal na pasta do projeto:

```sh
xcodebuild -project Extnd.xcodeproj -scheme Extnd -destination 'platform=macOS' test
```

## Estrutura

| Pasta | Responsabilidade |
| --- | --- |
| `Extnd/App` | Ponto de entrada do app e configuração da janela |
| `Extnd/Features/Home` | Interface inicial e informações da versão |
| `ExtndTests` | Testes XCTest executados no app macOS |

O cliente futuro tem como referência o iPad mini 3 com iOS 12.5.8. O projeto atual contém o app macOS e seu alvo de testes.
