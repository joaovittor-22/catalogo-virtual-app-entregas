import '../core/geo.dart';

double? _numero(dynamic valor) => valor is num ? valor.toDouble() : null;

/// Pedido pronto para entrega, como aparece na fila.
class PedidoFila {
  const PedidoFila({
    required this.pedidoId,
    required this.numero,
    required this.clienteNome,
    required this.enderecoResumo,
    required this.destino,
    required this.total,
    required this.formaPagamento,
    required this.quantidadeItens,
  });

  final int pedidoId;
  final String numero;
  final String clienteNome;
  final String enderecoResumo;

  /// Nulo quando o endereco nao pode ser localizado no mapa.
  final Ponto? destino;
  final double total;
  final String? formaPagamento;
  final int quantidadeItens;

  factory PedidoFila.fromJson(Map<String, dynamic> json) {
    final latitude = _numero(json['latitude']);
    final longitude = _numero(json['longitude']);
    return PedidoFila(
      pedidoId: (json['pedidoId'] as num).toInt(),
      numero: json['numero'] as String? ?? '',
      clienteNome: json['clienteNome'] as String? ?? 'Cliente',
      enderecoResumo: json['enderecoResumo'] as String? ?? 'Endereço não informado',
      destino: latitude == null || longitude == null ? null : Ponto(latitude, longitude),
      total: _numero(json['total']) ?? 0,
      formaPagamento: json['formaPagamento'] as String?,
      quantidadeItens: (json['quantidadeItens'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Pedido da fila com a distancia ate ele.
class ItemFila {
  ItemFila(this.pedido);

  final PedidoFila pedido;
  double? distanciaM;
  double? duracaoS;

  /// Verdadeiro quando a distancia e por rua; falso, em linha reta.
  bool porRua = false;
}

/// Indice do pedido mais proximo, ou nulo quando nao ha o que comparar
/// (menos de dois pedidos com distancia conhecida).
int? indiceDoMaisProximo(List<ItemFila> itens) {
  int? melhor;
  var comDistancia = 0;
  for (var i = 0; i < itens.length; i++) {
    final distancia = itens[i].distanciaM;
    if (distancia == null) continue;
    comDistancia++;
    if (melhor == null || distancia < itens[melhor].distanciaM!) melhor = i;
  }
  return comDistancia >= 2 ? melhor : null;
}
