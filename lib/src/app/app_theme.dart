import 'package:flutter/material.dart';

abstract final class B8Colors {
  static const primary = Color(0xFF25C06D);
  static const primaryDark = Color(0xFF17A45A);
  static const mint = Color(0xFFE7F7EF);
  static const background = Color(0xFFF2F7F5);
  static const surface = Color(0xFFFFFFFF);
  static const text = Color(0xFF1F2A37);
  static const muted = Color(0xFF93A1B2);
  static const line = Color(0xFFDCE7E2);
  static const danger = Color(0xFFFF4D4F);
}

abstract final class B8Theme {
  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: B8Colors.primary,
      onPrimary: Colors.white,
      primaryContainer: B8Colors.mint,
      onPrimaryContainer: B8Colors.primaryDark,
      secondary: Color(0xFF3B82F6),
      onSecondary: Colors.white,
      error: B8Colors.danger,
      onError: Colors.white,
      surface: B8Colors.surface,
      onSurface: B8Colors.text,
      outline: B8Colors.line,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: B8Colors.background,
      fontFamilyFallback: const [
        'PingFang SC',
        'Noto Sans CJK SC',
        'Noto Sans SC',
      ],
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: B8Colors.text,
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
        headlineSmall: TextStyle(
          color: B8Colors.text,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: TextStyle(
          color: B8Colors.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: TextStyle(
          color: B8Colors.text,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: B8Colors.text, fontSize: 16),
        bodyMedium: TextStyle(color: B8Colors.text, fontSize: 14),
        bodySmall: TextStyle(color: B8Colors.muted, fontSize: 12),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: B8Colors.background,
        foregroundColor: B8Colors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: B8Colors.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: B8Colors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: B8Colors.surface,
        hintStyle: const TextStyle(color: B8Colors.muted),
        labelStyle: const TextStyle(color: B8Colors.text),
        prefixIconColor: B8Colors.muted,
        suffixIconColor: B8Colors.muted,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: B8Colors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: B8Colors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: B8Colors.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: B8Colors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: B8Colors.primary.withValues(alpha: 0.45),
          minimumSize: const Size(0, 52),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: B8Colors.line, thickness: 1),
      useMaterial3: true,
    );
  }
}

final class B8Avatar extends StatelessWidget {
  const B8Avatar({
    super.key,
    required this.label,
    this.imageUrl = '',
    this.size = 48,
    this.backgroundColor = const Color(0xFFC9F0DB),
  });

  final String label;
  final String imageUrl;
  final double size;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: Text(
        label.trim().isEmpty ? '友' : label.trim().characters.first,
        style: TextStyle(
          color: B8Colors.primaryDark,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: imageUrl.trim().isEmpty
          ? fallback
          : Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

final class B8SectionTitle extends StatelessWidget {
  const B8SectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Container(
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: B8Colors.primary,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ],
      ),
    );
  }
}

final class B8EmptyState extends StatelessWidget {
  const B8EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: B8Colors.mint,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: B8Colors.primary, size: 34),
            ),
            const SizedBox(height: 18),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: B8Colors.muted),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}
