/// Быстрые плавные переходы между экранами (~190 мс: лёгкий
/// горизонтальный сдвиг + затухание). Использовать вместо
/// MaterialPageRoute — он на Android даёт тяжёлый modal-переход.
library;

import 'package:flutter/material.dart';

Route<T> fastRoute<T>(Widget child) => PageRouteBuilder<T>(
  transitionDuration: const Duration(milliseconds: 190),
  reverseTransitionDuration: const Duration(milliseconds: 160),
  pageBuilder: (context, animation, secondaryAnimation) => child,
  transitionsBuilder: (context, animation, secondaryAnimation, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.03, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  },
);

Future<T?> pushFast<T>(BuildContext context, Widget child) =>
    Navigator.of(context).push(fastRoute<T>(child));
