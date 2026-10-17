import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../corrida/filtro_gps.dart';
import 'geo.dart';

/// Situacao da permissao de localizacao.
enum Permissao {
  /// Ainda nao foi pedida (ou foi negada uma vez): da para pedir.
  aPedir,

  /// Negada em definitivo: so muda nos ajustes do aparelho.
  bloqueada,

  /// GPS desligado no aparelho.
  gpsDesligado,
  concedida,
}

/// Acesso ao GPS do aparelho. Interface para os testes trocarem por uma falsa.
abstract class Localizacao {
  Future<Permissao> situacao();

  /// Mostra o pedido de permissao do sistema.
  Future<Permissao> pedir();

  /// Posicao de agora, ou nulo sem permissao ou sem sinal.
  Future<Ponto?> posicaoAtual();

  /// Leituras continuas durante a corrida.
  Stream<Leitura> acompanhar();

  Future<void> abrirAjustes();
}

class LocalizacaoDoAparelho implements Localizacao {
  @override
  Future<Permissao> situacao() async {
    if (!await Geolocator.isLocationServiceEnabled()) return Permissao.gpsDesligado;
    return _traduzir(await Geolocator.checkPermission());
  }

  @override
  Future<Permissao> pedir() async {
    if (!await Geolocator.isLocationServiceEnabled()) return Permissao.gpsDesligado;
    return _traduzir(await Geolocator.requestPermission());
  }

  static Permissao _traduzir(LocationPermission permissao) {
    switch (permissao) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return Permissao.concedida;
      case LocationPermission.deniedForever:
        return Permissao.bloqueada;
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        return Permissao.aPedir;
    }
  }

  @override
  Future<Ponto?> posicaoAtual() async {
    if (await situacao() != Permissao.concedida) return null;
    try {
      final posicao = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return Ponto(posicao.latitude, posicao.longitude);
    } catch (_) {
      // Sem sinal a tempo: a ultima conhecida ainda serve para medir distancia.
      final ultima = await Geolocator.getLastKnownPosition();
      return ultima == null ? null : Ponto(ultima.latitude, ultima.longitude);
    }
  }

  @override
  Stream<Leitura> acompanhar() {
    return Geolocator.getPositionStream(locationSettings: _ajustesDaCorrida()).map(
      (p) => Leitura(
        ponto: Ponto(p.latitude, p.longitude),
        precisaoM: p.accuracy,
        em: p.timestamp,
        velocidadeMs: p.speed >= 0 ? p.speed : null,
        direcaoGraus: p.heading >= 0 ? p.heading : null,
      ),
    );
  }

  /// RNF-E05: o filtro de distancia faz o aparelho ficar quieto com o
  /// entregador parado, que e quando mais se gastaria bateria a toa.
  ///
  /// O rastreio segue com o app em segundo plano — o entregador vai abrir o
  /// navegador de mapas — mas so durante a corrida: no Android por um servico
  /// com notificacao visivel, no iOS com o indicador azul do sistema.
  static LocationSettings _ajustesDaCorrida() {
    const filtroDeDistanciaM = 8;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: filtroDeDistanciaM,
        intervalDuration: const Duration(seconds: 3),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Entrega em andamento',
          notificationText: 'Sua posição está sendo enviada para o cliente acompanhar.',
          notificationChannelName: 'Entrega em andamento',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: filtroDeDistanciaM,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: filtroDeDistanciaM,
    );
  }

  @override
  Future<void> abrirAjustes() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }
}
