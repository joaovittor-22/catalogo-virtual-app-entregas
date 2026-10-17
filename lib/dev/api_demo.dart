import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../core/geo.dart';

/// API do entregador em memoria, para o modo demonstracao: uma loja em
/// Goiania com quatro pedidos prontos. Pedido concluido ou devolvido volta
/// para a fila, para a demonstracao nunca acabar.
class ApiDemo extends ChangeNotifier {
  ApiDemo();

  static const loja = Ponto(-16.704058, -49.270077);
  static const _espera = Duration(milliseconds: 250);

  late final http.Client cliente = MockClient(_responder);

  final List<Map<String, dynamic>> _fila = [
    _pedido(
      501,
      'A1B2C3',
      'Mariana Souza',
      'Rua 1135, 210',
      'Setor Marista',
      const Ponto(-16.699776, -49.258056),
      87.9,
      'pix',
      3,
    ),
    _pedido(
      502,
      'D4E5F6',
      'Ricardo Lima',
      'Rua 4, 1020',
      'Setor Oeste',
      const Ponto(-16.682835, -49.269051),
      42.5,
      'dinheiro',
      2,
    ),
    _pedido(
      503,
      'G7H8J9',
      'Ana Paula Reis',
      'Avenida Botafogo, 455',
      'Jardim Goiás',
      const Ponto(-16.709037, -49.244821),
      129.0,
      'credito',
      5,
    ),
    _pedido(
      504,
      'K1L2M3',
      'José Carvalho',
      'Avenida C-148, 77',
      'Jardim América',
      const Ponto(-16.718035, -49.283192),
      64.3,
      'debito',
      1,
    ),
  ];
  final List<Map<String, dynamic>> _historico = [];
  Map<String, dynamic>? _corrida;
  Map<String, dynamic>? _pedidoDaCorrida;
  int _proximaEntrega = 1;

  /// Na demonstração o primeiro acesso também pede o aceite dos termos (já aceito pela sessão
  /// que a demonstração abre sozinha; volta a pedir depois de excluir a conta).
  bool _termosAceitos = true;

  /// Posicoes que chegaram ao "servidor": e o que o cliente veria no mapa.
  final List<Ponto> recebidas = [];

  /// Ate quando a "rede" fica fora do ar.
  DateTime? _semRedeAte;

  bool get semRede => _semRedeAte != null && DateTime.now().isBefore(_semRedeAte!);

  void derrubarRede(Duration tempo) {
    _semRedeAte = DateTime.now().add(tempo);
    notifyListeners();
    Timer(tempo, notifyListeners);
  }

  static Map<String, dynamic> _pedido(
    int id,
    String numero,
    String cliente,
    String rua,
    String bairro,
    Ponto destino,
    double total,
    String pagamento,
    int itens,
  ) => {
    'pedidoId': id,
    'numero': numero,
    'clienteNome': cliente,
    'rua': rua,
    'enderecoResumo': '$rua · $bairro',
    'bairro': bairro,
    'latitude': destino.latitude,
    'longitude': destino.longitude,
    'total': total,
    'formaPagamento': pagamento,
    'quantidadeItens': itens,
  };

  Future<http.Response> _responder(http.Request requisicao) async {
    await Future<void>.delayed(_espera);
    if (semRede) throw http.ClientException('Rede fora (demonstração)', requisicao.url);

    final metodo = requisicao.method;
    final caminho = requisicao.url.path.replaceFirst('/api/entregador', '');
    // Upload de foto chega em multipart: so JSON e decodificado.
    final emJson = (requisicao.headers['content-type'] ?? '').startsWith('application/json');
    final corpo = emJson && requisicao.body.isNotEmpty ? jsonDecode(requisicao.body) : null;
    final partes = caminho.split('/');

    if (metodo == 'GET' && requisicao.url.path == '/api/legal/entregador') return _ok(_termos);
    if (metodo == 'POST' && caminho == '/auth/login') {
      // Como a API: o primeiro acesso exige marcar o aceite dos termos.
      if (!_termosAceitos && (corpo as Map)['termosVersao'] == null) {
        return _ok({
          'codigo': 'TERMOS_PENDENTES',
          'message': 'Marque que leu e aceita os termos de uso para entrar.',
        }, status: 422);
      }
      _termosAceitos = true;
      return _ok(sessaoJson());
    }
    if (metodo == 'POST' && caminho == '/conta/excluir') {
      if ((corpo as Map)['senha'] == 'errada') {
        return _ok({'message': 'Senha incorreta. Os dados não foram removidos.'}, status: 422);
      }
      if (_corrida != null) {
        return _ok({
          'message':
              'Você tem uma entrega em andamento. Conclua a entrega antes de excluir a conta.',
        }, status: 422);
      }
      _termosAceitos = false;
      return _ok({'loja': 'Mercado Demonstração'});
    }
    if (metodo == 'GET' && caminho == '/fila') {
      return _ok({'corridaAtivaId': _corrida?['id'], 'loja': _ponto(loja), 'pedidos': _fila});
    }
    if (metodo == 'POST' && caminho.startsWith('/fila/') && caminho.endsWith('/iniciar-rota')) {
      return _iniciarRota(int.parse(partes[2]));
    }
    if (metodo == 'GET' && caminho == '/corrida') return _ok(_corrida);
    if (metodo == 'GET' && caminho == '/historico') return _ok(_historico.reversed.toList());

    if (caminho.startsWith('/entregas/')) {
      final corrida = _corrida;
      if (corrida == null || corrida['id'] != int.parse(partes[2])) {
        return _ok({'message': 'Entrega não encontrada.'}, status: 404);
      }
      final acao = partes.length > 3 ? partes[3] : '';
      if (metodo == 'GET' && acao.isEmpty) return _ok(corrida);
      if (metodo == 'PUT' && acao == 'rota') return _ok(null);
      if (metodo == 'POST' && acao == 'posicoes') {
        for (final p in (corpo as Map)['posicoes'] as List) {
          recebidas.add(
            Ponto((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble()),
          );
        }
        notifyListeners();
        return _ok({'rastreioAtivo': true});
      }
      if (acao == 'comprovante' && (metodo == 'POST' || metodo == 'DELETE')) {
        final enviado = metodo == 'POST';
        corrida['temComprovante'] = enviado;
        corrida['comprovanteEm'] = enviado ? DateTime.now().toUtc().toIso8601String() : null;
        return _ok(corrida);
      }
      if (metodo == 'POST' && acao == 'concluir') return _encerrar('entregue');
      if (metodo == 'POST' && acao == 'devolver') return _encerrar('devolvida');
    }
    return _ok({'message': 'Rota não simulada: $metodo $caminho'}, status: 404);
  }

  Future<http.Response> _iniciarRota(int pedidoId) async {
    if (_corrida != null) {
      return _ok({'message': 'Você já tem uma entrega em andamento.'}, status: 409);
    }
    final pedido = _fila.where((p) => p['pedidoId'] == pedidoId).firstOrNull;
    if (pedido == null) return _ok({'message': 'Outro entregador pegou este pedido.'}, status: 409);
    _fila.remove(pedido);
    _pedidoDaCorrida = pedido;
    recebidas.clear();
    final destino = Ponto(pedido['latitude'] as double, pedido['longitude'] as double);
    _corrida = {
      'id': _proximaEntrega++,
      'status': 'em_rota',
      'pedidoId': pedido['pedidoId'],
      'numero': pedido['numero'],
      'clienteNome': pedido['clienteNome'],
      'clienteTelefone': '62999990000',
      'enderecoCompleto': '${pedido['rua']}, ${pedido['bairro']}, Goiânia/GO',
      'referencia': 'Portão cinza',
      'latitude': destino.latitude,
      'longitude': destino.longitude,
      'formaPagamento': pedido['formaPagamento'],
      'trocoPara': pedido['formaPagamento'] == 'dinheiro' ? 50.0 : null,
      'total': pedido['total'],
      'itens': [
        {
          'qtd': pedido['quantidadeItens'],
          'nome': 'Item de demonstração',
          'adicionais': <String>[],
        },
      ],
      'raioChegadaM': 150,
      'iniciadaEm': DateTime.now().toUtc().toIso8601String(),
    };
    notifyListeners();
    return _ok(_corrida);
  }

  http.Response _encerrar(String status) {
    final corrida = {
      ..._corrida!,
      'status': status,
      'finalizadaEm': DateTime.now().toUtc().toIso8601String(),
    };
    _historico.add({...corrida, 'enderecoResumo': _pedidoDaCorrida!['enderecoResumo']});
    _fila.add(_pedidoDaCorrida!);
    _corrida = null;
    _pedidoDaCorrida = null;
    notifyListeners();
    return _ok(corrida);
  }

  static final Map<String, dynamic> _termos = {
    'titulo': 'Termos de Uso do Entregador',
    'versao': 1,
    'publicadoEm': '2026-10-17T12:00:00Z',
    'conteudo': '''
Estes Termos explicam como o app funciona e como os seus dados pessoais são tratados (demonstração).

## 1. Seu cadastro
- **Só a empresa parceira cadastra você.** Você não se cadastra sozinho pelo app.
- Cada empresa parceira tem um cadastro seu, separado das outras.

## 2. De quem é a responsabilidade pelos seus dados
**A Empresa parceira em que você entra é a responsável pelos seus dados pessoais.** A Mesa os trata em nome dela.

## 3. Aceitar, ou remover os seus dados
- No primeiro acesso, marque que leu e aceita estes Termos na tela de entrada. Sem marcar, você não entra.
- Se excluir a conta, os seus dados saem **apenas da empresa parceira em que você está logado**. Fica um registro inativo e anônimo, só para o histórico das entregas.
''',
  };

  static Map<String, dynamic> sessaoJson() => {
    'token': 'token-demo',
    'entregador': {'nome': 'Entregador Demo', 'codigo': '000001'},
    'loja': {'nome': 'Mercado Demonstração'},
    'expiraEmMs': const Duration(days: 30).inMilliseconds,
  };

  static Map<String, double> _ponto(Ponto p) => {'latitude': p.latitude, 'longitude': p.longitude};

  static http.Response _ok(Object? corpo, {int status = 200}) => http.Response(
    corpo == null ? '' : jsonEncode(corpo),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
