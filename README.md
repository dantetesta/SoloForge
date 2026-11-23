# SoloForge

Aplicativo macOS para guitarristas que querem estudar uma gravação e compor solos sobre ela.

**Estúdio de estudo** separa a guitarra da mixagem no Mac e estima notas, tempos e digitação. Compare a guitarra isolada com a tablatura, reduza a velocidade e repita um trecho. Em mixagens densas, o app identifica frases incertas para revisão.

**Estúdio de criação** usa o mapa de acordes, dinâmica e acentos da música para pedir propostas de solo à OpenAI. Escolha o nível, ouça cada opção com a gravação e experimente outra digitação ou posição de capotraste.

## Compilar no Mac

Use um Mac com Apple Silicon, macOS 14 ou superior, ferramentas de desenvolvimento Apple e Swift 5.10 ou superior. Na raiz do repositório, execute:

```sh
./Scripts/fetch-model.sh
./Scripts/swift-local.sh test
./Scripts/package.sh
open dist/SoloForge.app
```

O primeiro comando baixa o separador HTDemucs de uma revisão fixa no Hugging Face e confere o SHA-256 dos três arquivos. O empacotador cria um app para execução local com assinatura ad hoc.

## Uso

Importe um áudio pela biblioteca. O modo Estudo roda localmente. Para gerar letra com tempos aproximados, instale FFmpeg e whisper.cpp e selecione um modelo Whisper multilíngue nos ajustes.

Para compor com a OpenAI, configure sua própria chave em **Preferências → OpenAI**. A chave fica no Chaves do macOS. A API recebe o mapa musical e cobra o uso na conta configurada. O modelo em `Director.model` exige acesso na conta da API.

A edição comunitária usa a pasta **SoloForgeCommunity** em Application Support. Projetos portáteis podem ser importados pela biblioteca.

## Licenças

O código original do SoloForge está sob a [licença MIT](LICENSE).

- As amostras de guitarra elétrica e violão são CC0. [Origens e créditos](Instruments/NOTICE.txt) · [Licença](Instruments/CC0.txt)
- Basic Pitch é disponibilizado pelo Spotify sob Apache 2.0. [Modelo de origem](https://github.com/spotify/basic-pitch/tree/fa5997af0a8210982619003269994a1be25eddf3/basic_pitch/saved_models/icassp_2022/nmp.mlpackage) · [Licença](Models/BasicPitch/LICENSE.txt)
- O separador usa HTDemucs de seis fontes. [Projeto original](https://github.com/facebookresearch/demucs) · [Licença do Demucs](Models/GuitarSeparation/LICENSE.txt) · [Conversão Core ML utilizada](https://huggingface.co/GOVO/HTDemucs_6S_CoreML/tree/f7f11bf599d5aa5fd5af0355ea7bffec72c0b7b8)
