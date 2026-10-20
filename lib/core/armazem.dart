import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Texto guardado no aparelho entre uma abertura e outra do app.
abstract class Armazem {
  Future<String?> ler(String chave);
  Future<void> gravar(String chave, String valor);
  Future<void> apagar(String chave);
}

/// No Keystore/Keychain, como a sessao: a fila e a corrida guardadas tem nome,
/// telefone e endereco de cliente.
class ArmazemSeguro implements Armazem {
  ArmazemSeguro([FlutterSecureStorage? armazenamento])
    : _armazenamento = armazenamento ?? const FlutterSecureStorage();

  final FlutterSecureStorage _armazenamento;

  @override
  Future<String?> ler(String chave) async {
    try {
      return await _armazenamento.read(key: chave);
    } catch (_) {
      // Cofre indisponivel ou dado corrompido: segue sem o que estava guardado.
      return null;
    }
  }

  @override
  Future<void> gravar(String chave, String valor) async {
    try {
      await _armazenamento.write(key: chave, value: valor);
    } catch (_) {
      // Sem gravar, o app so perde o que guardaria para depois.
    }
  }

  @override
  Future<void> apagar(String chave) async {
    try {
      await _armazenamento.delete(key: chave);
    } catch (_) {}
  }
}

/// Para os testes e o modo demonstracao.
class ArmazemEmMemoria implements Armazem {
  final Map<String, String> dados = {};

  @override
  Future<String?> ler(String chave) async => dados[chave];

  @override
  Future<void> gravar(String chave, String valor) async => dados[chave] = valor;

  @override
  Future<void> apagar(String chave) async => dados.remove(chave);
}

/// O que um entregador guarda no aparelho, separado por loja e entregador:
/// quem entra com outra conta nao ve nem reenvia nada da anterior.
class DadosLocais {
  DadosLocais(this._armazem, this.dono);

  static const _nomes = ['fila', 'corrida', 'pendencias'];

  final Armazem _armazem;

  /// Loja e entregador da sessao (ver `Sessao.dono`).
  final String dono;

  final Map<String, String> _gravado = {};

  String _chave(String nome) => '$nome:$dono';

  /// O que foi guardado com [nome], com a hora em que foi guardado. Mais antigo
  /// que [validade], nao serve mais e e apagado.
  Future<({Object? dados, DateTime em})?> ler(String nome, {Duration? validade}) async {
    final texto = await _armazem.ler(_chave(nome));
    if (texto == null) return null;
    try {
      final json = jsonDecode(texto) as Map<String, dynamic>;
      final em = DateTime.parse(json['em'] as String);
      if (validade != null && DateTime.now().difference(em) > validade) {
        await apagar(nome);
        return null;
      }
      _gravado[nome] = jsonEncode(json['dados']);
      return (dados: json['dados'], em: em);
    } catch (_) {
      await apagar(nome);
      return null;
    }
  }

  /// Grava so quando o conteudo muda: a fila e atualizada a cada 15 s e quase
  /// sempre volta igual, e cada gravacao no cofre cifra e escreve no disco.
  Future<void> gravar(String nome, Object? dados) async {
    final texto = jsonEncode(dados);
    if (_gravado[nome] == texto) return;
    _gravado[nome] = texto;
    await _armazem.gravar(
      _chave(nome),
      '{"em":"${DateTime.now().toIso8601String()}","dados":$texto}',
    );
  }

  Future<void> apagar(String nome) async {
    _gravado.remove(nome);
    await _armazem.apagar(_chave(nome));
  }

  /// Sair da conta ou exclui-la nao deixa dado de cliente no aparelho.
  static Future<void> apagarTudo(Armazem armazem, String dono) async {
    for (final nome in _nomes) {
      await armazem.apagar('$nome:$dono');
    }
  }
}
