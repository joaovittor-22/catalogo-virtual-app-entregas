import 'package:flutter/material.dart';

/// Cores do Cardapio Virtual.
class Cores {
  const Cores._();

  static const primaria = Color(0xFF155C3B);
  static const fundo = Color(0xFFEEE9DC);
  static const superficie = Color(0xFFFFFDF6);
  static const texto = Color(0xFF17261D);
  static const apagado = Color(0xFF687068);
  static const borda = Color(0xFFD9D2C1);
  static const destaque = Color(0xFFE2A93B);
  static const perigo = Color(0xFFB42318);
  static const sucesso = Color(0xFF1F7047);
}

/// RNF-E07: o entregador esta na rua, de capacete e com pressa — texto
/// grande, contraste alto e botoes que se acertam com o polegar.
ThemeData temaDoApp() {
  final esquema = ColorScheme.fromSeed(
    seedColor: Cores.primaria,
    primary: Cores.primaria,
    surface: Cores.superficie,
    error: Cores.perigo,
  );
  const alturaBotao = Size.fromHeight(56);
  final formaBotao = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  const textoBotao = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);

  return ThemeData(
    useMaterial3: true,
    colorScheme: esquema,
    scaffoldBackgroundColor: Cores.fundo,
    appBarTheme: const AppBarTheme(
      backgroundColor: Cores.primaria,
      foregroundColor: Colors.white,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: Cores.superficie,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Cores.borda),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: alturaBotao,
        shape: formaBotao,
        textStyle: textoBotao,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: alturaBotao,
        shape: formaBotao,
        textStyle: textoBotao,
        side: const BorderSide(color: Cores.borda, width: 1.5),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Cores.superficie,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Cores.borda),
      ),
    ),
  );
}
