// Doroosak design tokens — taken 1:1 from the approved MVP screens.
// Every screen reads colors, type, radii and spacing from here; no screen
// hard-codes a value. Change a token here and every screen follows.

import 'package:flutter/material.dart';

abstract final class DColors {
  // Brand
  static const emerald = Color(0xFF0B5D3B); // primary actions, selected states, key info
  static const emeraldDark = Color(0xFF084A2F); // pressed / hover
  static const emeraldTint = Color(0xFFE3EFE8); // soft emerald surfaces, Quran tile
  static const emeraldOnDark = Color(0xFFCFE3D8); // secondary text on emerald
  static const gold = Color(0xFFE8C766); // highlights: raise hand, hold timer, badges
  static const goldInk = Color(0xFF7A5B0C); // gold used as text/icon on light
  static const goldOnGold = Color(0xFF3D2E05); // text on a gold fill
  static const goldTint = Color(0xFFF5ECD2); // notices, Islamic Studies tile

  // Neutrals
  static const background = Color(0xFFFAF7F0); // warm off-white page
  static const surface = Color(0xFFFFFFFF); // cards
  static const surfaceSunken = Color(0xFFF3EFE6); // classroom page, chat bubbles
  static const border = Color(0xFFE8E2D4);
  static const borderStrong = Color(0xFFD9D2C2); // secondary buttons
  static const divider = Color(0xFFF0EBE0);
  static const ink = Color(0xFF17201B); // primary text
  static const inkBody = Color(0xFF3A423D); // long body text
  static const inkMuted = Color(0xFF59625C); // secondary text (passes 4.5:1 on background)

  // Subject tiles: soft fill + matching ink for icon/subtitle
  static const quranFill = emeraldTint, quranInk = emerald;
  static const islamicFill = goldTint, islamicInk = goldInk;
  static const arabicFill = Color(0xFFF4E4DA), arabicInk = Color(0xFF8A3F1E);
  static const englishFill = Color(0xFFE1ECF4), englishInk = Color(0xFF1F4E79);

  // Status
  static const danger = Color(0xFFB42318); // Leave lesson, destructive
  static const quranHighlight = Color(0xFFF5E3A8); // highlighted ayah
  static const quranHighlightRing = Color(0xFFE0C35C);
  static const mushafPaper = Color(0xFFFFFDF8);
}

abstract final class DFonts {
  static const display = 'Readex Pro'; // headings, names, numbers (Arabic + Latin)
  static const bodyLatin = 'Plus Jakarta Sans'; // English UI text
  static const bodyArabic = 'IBM Plex Sans Arabic'; // Arabic UI text
  static const mushaf = 'Amiri'; // Quran text (replace with the licensed Mushaf font)
}

abstract final class DRadius {
  static const chip = 999.0;
  static const button = 14.0;
  static const input = 12.0;
  static const tile = 18.0;
  static const card = 20.0;
  static const hero = 22.0;
  static const avatar = 18.0;
}

abstract final class DSpace {
  // 4-pt scale
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 20.0, xxl = 24.0, xxxl = 32.0;
  static const pageH = 20.0; // horizontal page padding on phones
  static const minTouch = 44.0; // every tappable thing is at least this tall
  static const buttonHeight = 54.0;
}

/// Type scale used on the screens (sizes in logical px).
abstract final class DType {
  static TextStyle _d(double size, FontWeight w, {double height = 1.2}) =>
      TextStyle(fontFamily: DFonts.display, fontSize: size, fontWeight: w, height: height, color: DColors.ink);

  static final heroTitle = _d(36, FontWeight.w600, height: 1.15); // sign-in headline
  static final pageTitle = _d(26, FontWeight.w600); // "Your Teachers from Yemen"
  static final sectionTitle = _d(18, FontWeight.w600);
  static final cardTitle = _d(16, FontWeight.w600);
  static final bigTime = _d(26, FontWeight.w600); // booked-time display
}

ThemeData doroosakTheme({required bool arabic}) {
  final body = arabic ? DFonts.bodyArabic : DFonts.bodyLatin;
  final scheme = ColorScheme.fromSeed(
    seedColor: DColors.emerald,
    primary: DColors.emerald,
    onPrimary: Colors.white,
    secondary: DColors.gold,
    onSecondary: DColors.goldOnGold,
    surface: DColors.surface,
    onSurface: DColors.ink,
    error: DColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: DColors.background,
    fontFamily: body,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 16, height: 1.55, color: DColors.inkBody),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: DColors.inkBody),
      bodySmall: TextStyle(fontSize: 13, height: 1.45, color: DColors.inkMuted),
      labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: DColors.emerald,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(DSpace.buttonHeight),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DRadius.button)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: DColors.ink,
        backgroundColor: DColors.surface,
        minimumSize: const Size.fromHeight(DSpace.buttonHeight),
        side: const BorderSide(color: DColors.borderStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DRadius.button)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    cardTheme: CardThemeData(
      color: DColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DRadius.card),
        side: const BorderSide(color: DColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DRadius.input),
        borderSide: const BorderSide(color: DColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DRadius.input),
        borderSide: const BorderSide(color: DColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DRadius.input),
        borderSide: const BorderSide(color: DColors.emerald, width: 1.5),
      ),
    ),
    chipTheme: const ChipThemeData(
      shape: StadiumBorder(side: BorderSide(color: DColors.border)),
      backgroundColor: DColors.surface,
      selectedColor: DColors.ink,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: DColors.surface,
      indicatorColor: DColors.emeraldTint,
      height: 80,
    ),
    dividerColor: DColors.divider,
  );
}
