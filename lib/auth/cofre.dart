import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sessao.dart';

/// Guarda a sessao no armazenamento seguro do sistema (Keystore/Keychain),
/// nunca em preferencias abertas. A senha nao e guardada em lugar nenhum.
abstract class Cofre {
  Future<Sessao?> lerSessao();
  Future<void> gravarSessao(Sessao sessao);
  Future<void> apagarSessao();

  /// Empresa e identificador do ultimo login, para nao redigitar.
  Future<({String empresa, String identificador})?> lerUltimoAcesso();
  Future<void> gravarUltimoAcesso(String empresa, String identificador);

  /// Empresa em que o entregador já marcou o aceite dos termos neste aparelho. Com outra
  /// empresa (ou termos novos), a tela de entrada volta a pedir o aceite.
  Future<String?> lerEmpresaComAceite();
  Future<void> gravarEmpresaComAceite(String? empresa);
}

class CofreSeguro implements Cofre {
  CofreSeguro([FlutterSecureStorage? armazenamento])
    : _armazenamento = armazenamento ?? const FlutterSecureStorage();

  static const _chaveSessao = 'sessao';
  static const _chaveAcesso = 'ultimo_acesso';
  static const _chaveAceite = 'empresa_com_aceite';

  final FlutterSecureStorage _armazenamento;

  @override
  Future<Sessao?> lerSessao() async {
    try {
      final texto = await _armazenamento.read(key: _chaveSessao);
      if (texto == null) return null;
      final sessao = Sessao.fromJson(jsonDecode(texto) as Map<String, dynamic>);
      return sessao.expirada ? null : sessao;
    } catch (_) {
      // Dado corrompido ou cofre indisponivel: segue como deslogado.
      return null;
    }
  }

  @override
  Future<void> gravarSessao(Sessao sessao) =>
      _armazenamento.write(key: _chaveSessao, value: jsonEncode(sessao.toJson()));

  @override
  Future<void> apagarSessao() => _armazenamento.delete(key: _chaveSessao);

  @override
  Future<({String empresa, String identificador})?> lerUltimoAcesso() async {
    try {
      final texto = await _armazenamento.read(key: _chaveAcesso);
      if (texto == null) return null;
      final dados = jsonDecode(texto) as Map<String, dynamic>;
      return (
        empresa: dados['empresa'] as String? ?? '',
        identificador: dados['identificador'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> gravarUltimoAcesso(String empresa, String identificador) => _armazenamento.write(
    key: _chaveAcesso,
    value: jsonEncode({'empresa': empresa, 'identificador': identificador}),
  );

  @override
  Future<String?> lerEmpresaComAceite() async {
    try {
      return await _armazenamento.read(key: _chaveAceite);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> gravarEmpresaComAceite(String? empresa) => empresa == null
      ? _armazenamento.delete(key: _chaveAceite)
      : _armazenamento.write(key: _chaveAceite, value: empresa);
}
