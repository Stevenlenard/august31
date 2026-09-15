import 'package:flutter/material.dart';

class CustomNotification {
  static void showTopNotification(BuildContext context, String message, [bool isError = true]) {
    final double screenHeight = MediaQuery.of(context).size.height;
    final double screenWidth = MediaQuery.of(context).size.width;
    final double topPadding = MediaQuery.of(context).padding.top;
    
    // Adaptive font size
    final double fontSize = (screenWidth * 0.04).clamp(13.0, 15.0);

    // CRITICAL: Precise top positioning logic
    // We want the notification to appear comfortably below the status bar
    final double topMargin = topPadding + 28.0;
    final double snackBarHeight = 60.0; 
    
    // Bottom margin for floating SnackBar is measured from the bottom of the screen.
    // To show it at the top, we set the bottom margin to (Total Height - Top Offset - SnackBar Height)
    final double bottomMargin = screenHeight - topMargin - snackBarHeight;

    // Adaptive horizontal margin for width control on Desktop
    final bool isDesktop = screenWidth >= 900;
    final double horizontalMargin = isDesktop ? (screenWidth - 420) / 2 : 16.0;

    ScaffoldMessenger.of(context).clearSnackBars(); 
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Container(
          height: 44, // Constrain height for consistency
          alignment: Alignment.center,
          child: Text(
            message, 
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w800, 
              fontSize: fontSize,
              color: Colors.white,
              letterSpacing: 0.2,
            )
          ),
        ),
        backgroundColor: isError ? Colors.redAccent.shade400 : const Color(0xFF00796B),
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.up,
        margin: EdgeInsets.only(
          bottom: bottomMargin.clamp(0.0, screenHeight - 100),
          left: horizontalMargin,
          right: horizontalMargin,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
