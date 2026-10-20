import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

/// Erro devolvido pela API (ou falha de rede, com [status] nulo).
class ApiException implements Exception {
  const ApiException(this.mensagem, {this.status, this.codigo});

  final String mensagem;
  final int? status;

  /// Código de regra que a API manda junto da mensagem (ex.: `TERMOS_PENDENTES`).
  final String? codigo;

  /// Falta marcar o aceite dos termos de uso (primeiro acesso à empresa ou termos novos).
  bool get termosPendentes => codigo == 'TERMOS_PENDENTES';

  /// Sem resposta do servidor: rede caiu, tempo esgotou.
  bool get semConexao => status == null;

  /// Outro ja fez (ex.: pedido pego por outro entregador).
  bool get conflito => status == 409;

  /// Vale tentar de novo mais tarde, com a mesma requisicao: sem rede, API fora do ar ou
  /// pedindo calma. Os demais erros sao resposta definitiva.
  bool get passageiro => semConexao || status == 408 || status == 429 || (status ?? 0) >= 500;

  @override
  String toString() => mensagem;
}

/// Acesso HTTP a API. A loja e o entregador saem sempre do token.
class ApiClient {
  ApiClient({http.Client? cliente, String? baseUrl})
    : _http = cliente ?? http.Client(),
      _base = baseUrl ?? Config.apiUrl;

  static const _tempoLimite = Duration(seconds: 15);

  final http.Client _http;
  final String _base;

  String? token;

  /// Chamado quando a API recusa o token (expirou ou o acesso foi retirado).
  void Function()? aoPerderSessao;

  /// Chamado quando os termos de uso mudam com a sessão aberta: é preciso entrar de novo e
  /// marcar o aceite.
  void Function()? aoExigirTermos;

  /// Falso desde a última chamada que ficou sem resposta; volta a verdadeiro na primeira
  /// resposta do servidor, qualquer que seja o status. Quem tem algo guardado para enviar
  /// ouve a volta e tenta na hora, sem esperar o próprio temporizador.
  final ValueNotifier<bool> conectado = ValueNotifier(true);

  Future<dynamic> get(String caminho) => _enviar('GET', caminho);

  Future<dynamic> post(String caminho, [Object? corpo]) => _enviar('POST', caminho, corpo);

  Future<dynamic> put(String caminho, [Object? corpo]) => _enviar('PUT', caminho, corpo);

  Future<dynamic> delete(String caminho) => _enviar('DELETE', caminho);

  /// Envia um arquivo (multipart, campo `arquivo`).
  Future<dynamic> enviarArquivo(String caminho, List<int> bytes, String nomeDoArquivo) {
    final requisicao = http.MultipartRequest('POST', Uri.parse('$_base$caminho'))
      ..files.add(http.MultipartFile.fromBytes('arquivo', bytes, filename: nomeDoArquivo));
    return _executar(requisicao);
  }

  Future<dynamic> _enviar(String metodo, String caminho, [Object? corpo]) {
    final requisicao = http.Request(metodo, Uri.parse('$_base$caminho'));
    if (corpo != null) {
      requisicao.headers['Content-Type'] = 'application/json';
      requisicao.body = jsonEncode(corpo);
    }
    return _executar(requisicao);
  }

  Future<dynamic> _executar(http.BaseRequest requisicao) async {
    requisicao.headers['Accept'] = 'application/json';
    requisicao.headers['User-Agent'] = 'entregador-app/1.0';
    if (token != null) requisicao.headers['Authorization'] = 'Bearer $token';

    final http.Response resposta;
    try {
      resposta = await http.Response.fromStream(await _http.send(requisicao).timeout(_tempoLimite));
    } on TimeoutException {
      conectado.value = false;
      throw const ApiException('O servidor demorou para responder. Tente de novo.');
    } on SocketException {
      conectado.value = false;
      throw const ApiException('Sem conexão com a internet.');
    } on http.ClientException {
      conectado.value = false;
      throw const ApiException('Sem conexão com a internet.');
    }
    conectado.value = true;

    final texto = utf8.decode(resposta.bodyBytes);
    final dados = texto.isEmpty ? null : _decodificar(texto);
    if (resposta.statusCode >= 200 && resposta.statusCode < 300) return dados;

    if (resposta.statusCode == 401 && token != null) aoPerderSessao?.call();
    if (resposta.statusCode == 403 && dados is Map && dados['codigo'] == 'TERMOS_PENDENTES') {
      aoExigirTermos?.call();
    }
    final codigo = dados is Map ? dados['codigo'] as String? : null;
    throw ApiException(
      _mensagem(resposta.statusCode, dados),
      status: resposta.statusCode,
      codigo: codigo,
    );
  }

  static dynamic _decodificar(String texto) {
    try {
      return jsonDecode(texto);
    } on FormatException {
      return null;
    }
  }

  /// A API manda a mensagem pronta nos erros de regra; nos demais, uma generica.
  static String _mensagem(int status, dynamic dados) {
    final daApi = dados is Map ? dados['message'] : null;
    if (daApi is String && daApi.isNotEmpty && const {401, 403, 409, 422, 429}.contains(status)) {
      return daApi;
    }
    if (status == 401) return 'Sua sessão expirou. Entre novamente.';
    if (status == 403) return 'Você não tem permissão para isso.';
    if (status == 404) return 'Não encontrado.';
    if (status >= 500) return 'O serviço está indisponível no momento.';
    return 'Não foi possível concluir. Tente de novo.';
  }
}
