import 'package:entregador_app/core/formato.dart';
import 'package:entregador_app/core/geo.dart';
import 'package:entregador_app/fila/pedido_fila.dart';
import 'package:flutter_test/flutter_test.dart';

ItemFila _item(int id, double? distancia) => ItemFila(
  PedidoFila(
    pedidoId: id,
    numero: 'N$id',
    clienteNome: 'Cliente',
    enderecoResumo: 'Rua',
    destino: null,
    total: 10,
    formaPagamento: 'pix',
    quantidadeItens: 1,
  ),
)..distanciaM = distancia;

void main() {
  // Uma rua para leste (~1,07 km) e depois para o norte (~1,11 km).
  const rota = [Ponto(-16.69, -49.26), Ponto(-16.69, -49.25), Ponto(-16.68, -49.25)];

  test('mede distancia em linha reta', () {
    expect(distanciaM(rota[0], rota[1]), closeTo(1065, 15));
    expect(distanciaM(rota[1], rota[2]), closeTo(1112, 15));
    expect(distanciaM(rota[0], rota[0]), 0);
  });

  test('encaixa na rua o ponto que caiu em cima de uma casa', () {
    // ~20 m ao sul da rua, no meio do primeiro trecho.
    final encaixe = encaixarNaRota(const Ponto(-16.69018, -49.255), rota)!;
    expect(encaixe.trecho, 0);
    expect(encaixe.distanciaM, closeTo(20, 3));
    expect(encaixe.ponto.latitude, closeTo(-16.69, 0.00001));
    expect(encaixe.ponto.longitude, closeTo(-49.255, 0.0001));
  });

  test('alem do fim da rota, encaixa na ponta', () {
    final encaixe = encaixarNaRota(const Ponto(-16.675, -49.25), rota)!;
    expect(encaixe.trecho, 1);
    expect(encaixe.ponto, rota[2]);
    expect(encaixarNaRota(rota[0], const [Ponto(0, 0)]), isNull);
  });

  test('marca o mais proximo so quando ha o que comparar', () {
    expect(indiceDoMaisProximo([_item(1, 900), _item(2, 300), _item(3, 1500)]), 1);
    // Pedido sem endereco localizado nao entra na comparacao.
    expect(indiceDoMaisProximo([_item(1, null), _item(2, 800), _item(3, 500)]), 2);
    expect(indiceDoMaisProximo([_item(1, 900)]), isNull);
    expect(indiceDoMaisProximo([_item(1, 900), _item(2, null)]), isNull);
    expect(indiceDoMaisProximo([]), isNull);
  });

  test('formata dinheiro, distancia, tempo e telefone', () {
    expect(moeda(57.5), r'R$ 57,50');
    expect(moeda(1234567.891), r'R$ 1.234.567,89');
    expect(moeda(null), r'R$ 0,00');
    expect(distancia(432), '430 m');
    expect(distancia(2350), '2,4 km');
    expect(duracao(20), 'menos de 1 min');
    expect(duracao(540), '9 min');
    expect(duracao(4500), '1 h 15 min');
    expect(pagamento('dinheiro'), 'Dinheiro');
    expect(telefoneInternacional('(62) 98888-7777'), '5562988887777');
    expect(telefoneInternacional('5562988887777'), '5562988887777');
  });
}
