# App do entregador

App Flutter (Android e iOS) do entregador do Cardápio Virtual: ele entra com os
dados da loja, vê os pedidos prontos para entrega, inicia a rota de um deles e
conclui ao chegar. Enquanto a rota está em andamento, o cliente acompanha a
moto no mapa pelo link do pedido.

## Como funciona

1. **Login** — três campos: **empresa** (o código numérico que aparece em
   *Painel → Entregadores*, ou o slug da loja), **seu acesso** (celular, CPF,
   e-mail, usuário ou o ID gerado pelo sistema, tudo no mesmo campo) e **senha**.
2. **Fila** — pedidos confirmados pela loja e já em separação, com cliente,
   endereço resumido, distância e o botão **Iniciar rota**. O selo
   **Mais próximo** marca o de menor distância. Atualiza sozinha a cada 15 s.
3. **Entrega** — endereço completo, referência, itens, pagamento e troco;
   botões para abrir o mapa, ligar e chamar no WhatsApp. O app passa a enviar
   a posição.
4. **Concluir** — a menos de 150 m do endereço aparece **Concluir entrega**.
   Antes disso há a saída **Já entreguei o pedido**, com confirmação, para
   quando o GPS falha ou o endereço não foi localizado. Concluir para o
   rastreio e devolve o entregador à fila.

Uma entrega por vez: com uma em andamento, o app abre direto nela.

## Rodando

```bash
flutter pub get
flutter run --dart-define=API_URL=https://api.sualoja.com.br
```

| Variável   | Padrão                            | Para quê |
|------------|-----------------------------------|----------|
| `API_URL`  | debug: `http://10.0.2.2:8080`; release: **obrigatória** | API do Cardápio Virtual. Em debug o padrão é o computador que roda o emulador Android. |
| `OSRM_URL` | debug: `https://router.project-osrm.org`; release: vazio | Servidor de rotas. Sem ele, distâncias em linha reta. O público é só para demonstração — veja abaixo. |

HTTP sem TLS só é aceito na build de **debug**; a de release exige HTTPS.

### Modo demonstração (só em debug)

Em debug o app sobe, por padrão, com uma API em memória (quatro pedidos em
Goiânia), já logado, e com a moto andando sozinha até o destino. Ao iniciar a
rota abre um painel de mapa com a rota traçada, cada leitura do GPS (aceita ou
descartada pelo filtro) e botões para provocar salto, precisão ruim, parada,
desvio, perda de sinal e queda de rede. Nada disso entra na build de release.

| Variável       | Padrão (debug) | Para quê |
|----------------|----------------|----------|
| `MOCK`         | `true`         | API em memória e login pulado. `false` usa a API de `API_URL`. |
| `GPS_SIMULADO` | `true`         | Moto simulada e painel de mapa, também com a API de verdade. |
| `DEV_LOGIN`    | —              | `empresa:identificador:senha`: entra sozinho na API de verdade. |

Contra o back local, para ver o rastreio chegar à página do cliente:

```bash
flutter run --dart-define=MOCK=false --dart-define=DEV_LOGIN=minha-loja:carlos:segredo123
```

```bash
flutter analyze
flutter test
```

## Build de produção

A build de release **não usa a chave de debug**: sem a chave de upload configurada, ela para com
uma mensagem. Feito uma vez, por quem vai publicar:

1. Crie a chave de upload e guarde-a fora do repositório, com backup (perdê-la complica as
   atualizações na Play Store):

   ```bash
   keytool -genkeypair -v -keystore ~/chaves/mesa-upload.jks -storetype JKS \
     -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

2. Crie `android/key.properties` (já está no `.gitignore`, nunca vai para o git):

   ```properties
   storePassword=...
   keyPassword=...
   keyAlias=upload
   storeFile=/home/voce/chaves/mesa-upload.jks
   ```

3. Gere o app:

   ```bash
   API_URL=https://api.seudominio.com.br OSRM_URL=https://rotas.seudominio.com.br scripts/build-release.sh
   ```

   Sai o `app-release.aab` (Play Store) e o `app-release.apk` (instalação direta). O script
   recusa `API_URL` sem HTTPS e roda analyze e testes antes. Uma build de release feita sem
   `API_URL` abre uma tela avisando, em vez de tentar o emulador.

### Antes de publicar na Play Store

- **Política de privacidade:** use a URL pública do site (`/termos` e `/privacidade`); os termos do
  entregador ficam no próprio app.
- **Segurança dos dados:** declarar nome, CPF, telefone, e-mail, localização precisa (só durante a
  entrega), fotos (comprovante) e que os dados podem ser excluídos pelo app (Conta e termos).
- **Localização com serviço em primeiro plano:** o app usa `FOREGROUND_SERVICE_LOCATION`; a Play pede
  a declaração do uso e um vídeo curto mostrando a entrega em andamento. O app já mostra o aviso
  antes de pedir a permissão.
- **Exclusão de conta:** é feita no app; confira se a política da Play exige também um link na web
  para pedir a exclusão.
- **Versão:** suba `version:` no `pubspec.yaml` a cada envio (o `versionCode` vem dele).

## Distância e rota

Tudo gratuito e sobre dados do OpenStreetMap:

- **Linha reta** (haversine), calculada no próprio app, aparece na hora — com
  `~` na frente para indicar que é aproximada.
- **Por rua**, pelo [OSRM](https://project-osrm.org): uma chamada mede a
  distância até todos os pedidos da fila, outra traça a rota da entrega.
  Quando o OSRM não responde, fica a linha reta; a entrega nunca depende dele.

O servidor público do OSRM não tem garantia de disponibilidade nem é para uso
comercial. Para produção, suba o seu (a imagem `osrm/osrm-backend` com o
extrato da região do [Geofabrik](https://download.geofabrik.de/south-america/brazil.html))
e aponte `OSRM_URL` para ele.

## Correção da posição

O GPS do celular erra — é o que põe a moto "em cima de uma casa". Antes de
sair do aparelho, cada leitura passa por [`FiltroGps`](lib/corrida/filtro_gps.dart)
e depois pelo encaixe na rota, em [`Rastreador`](lib/corrida/rastreador.dart):

| Problema | Correção |
|---|---|
| Leitura com raio de incerteza acima de 50 m | Descartada |
| Salto isolado (mais de ~150 km/h entre duas leituras) | Descartado; três seguidos que concordam recomeçam o filtro |
| Tremor com o entregador parado | A posição não se mexe |
| Zigue-zague lateral andando | Filtro de Kalman com previsão por velocidade e rumo |
| Ponto fora da rua, a até 35 m da rota | Encaixado na rota (*map matching*) |
| Três leituras seguidas longe da rota | Rota recalculada a partir de onde ele está |

No teste, um erro lateral de 12 m cai para menos de 3 m sem a posição atrasar.
A página de rastreio repete o descarte de saltos e o encaixe, como segunda
barreira.

## Localização e bateria

- A permissão é pedida ao abrir a primeira entrega, depois de explicar para
  quê. **Negada, a entrega funciona normalmente**, só sem rastreio.
- A posição é enviada **somente** entre iniciar a rota e concluir.
- O rastreio continua com o app em segundo plano (o entregador abre o
  navegador de mapas): no Android por um serviço com notificação visível, no
  iOS com o indicador azul do sistema. Com o app fechado, nada é enviado.
- O aparelho só gera leitura a cada 8 m percorridos, e as posições saem em
  lote a cada 3 s. Sem rede, ficam guardadas e seguem quando ela volta.

## Organização

```
lib/
  core/      API, configuração, geometria, formatação, tema, acesso ao GPS
  auth/      sessão (guardada no Keystore/Keychain), login
  fila/      pedidos prontos, distâncias, "Iniciar rota"
  corrida/   entrega em andamento, filtro de GPS, rastreador, rotas (OSRM)
test/        filtro, geometria, rastreador e telas, com API e GPS falsos
```

## O que ainda não foi feito

- Rodar em aparelho real: o que está verificado é análise estática, testes e a
  build do APK de debug. Comportamento do GPS em campo e a notificação do
  serviço em segundo plano precisam de teste na rua.
- Ícone, nome de pacote definitivo, assinatura e publicação nas lojas.
- Ações feitas sem rede (concluir, devolver) não são enfileiradas: o app avisa
  e o entregador toca de novo. Só as posições são guardadas para reenvio.

## Termos de uso

No primeiro acesso a cada empresa, a tela de entrada pede para marcar "Li e aceito os termos de
uso" (o link abre o texto e volta). Sem marcar, não entra. Depois o checkbox some e a entrada fica
salva; volta se trocar o código da empresa ou se os termos mudarem. Em **Conta e termos** o
entregador lê os termos e pode excluir a conta: os dados saem só da loja em que ele está logado.

