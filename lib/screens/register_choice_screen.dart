import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import '../widgets/legal_agreement_dialog.dart';
import '../widgets/animated_auth_background.dart';
import '../widgets/fade_slide_entrance.dart';
import '../utils/app_localizations.dart';

class RegisterChoiceScreen extends StatefulWidget {
  const RegisterChoiceScreen({super.key});

  @override
  State<RegisterChoiceScreen> createState() => _RegisterChoiceScreenState();
}

class _RegisterChoiceScreenState extends State<RegisterChoiceScreen> {
  @override
  void initState() {
    super.initState();
    AppLocalizations.currentLanguage.addListener(_onLanguageChanged);
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppLocalizations.currentLanguage.removeListener(_onLanguageChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedAuthBackground(
      child: SafeArea(
        child: ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(scrollbars: false),
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                  child: Column(
                    children: [
                      FadeSlideEntrance(
                        delay: const Duration(milliseconds: 100),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(150),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF00796B), size: 20),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(flex: 2),
                      FadeSlideEntrance(
                        delay: const Duration(milliseconds: 300),
                        child: _buildBranding(),
                      ),
                      const SizedBox(height: 48),
                      // Options
                      FadeSlideEntrance(
                        delay: const Duration(milliseconds: 500),
                        child: _buildChoiceCard(
                          context: context,
                          title: AppLocalizations.get('resident'),
                          subtitle: AppLocalizations.get('track_trucks'),
                          icon: Icons.home_rounded,
                          iconColor: const Color(0xFF2196F3),
                          bgColor: const Color(0xFFE3F2FD),
                          route: '/register_resident',
                        ),
                      ),
                      const SizedBox(height: 20),
                      FadeSlideEntrance(
                        delay: const Duration(milliseconds: 600),
                        child: _buildChoiceCard(
                          context: context,
                          title: AppLocalizations.get('driver'),
                          subtitle: AppLocalizations.get('manage_routes'),
                          icon: Icons.local_shipping_rounded,
                          iconColor: const Color(0xFF4CAF50),
                          bgColor: const Color(0xFFE8F5E9),
                          route: '/register_driver',
                        ),
                      ),
                      const Spacer(flex: 4),
                      FadeSlideEntrance(
                        delay: const Duration(milliseconds: 800),
                        child: _buildFooter(context),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBranding() {
    return Column(
      children: [
        Container(
          width: 84, height: 84,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [AppColors.loginButtonStart, AppColors.loginButtonEnd], begin: Alignment.topLeft, end: Alignment.bottomRight),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: AppColors.loginButtonEnd.withAlpha(60), blurRadius: 20, offset: const Offset(0, 10)),
              BoxShadow(color: Colors.white.withAlpha(100), blurRadius: 2, spreadRadius: -2),
            ],
          ),
          child: const Icon(Icons.person_add_rounded, size: 44, color: Colors.white),
        ),
        const SizedBox(height: 24),
        Text(AppLocalizations.get('create_account'), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: AppColors.tealText, letterSpacing: -1.2)),
        Text(AppLocalizations.get('select_type'), style: const TextStyle(fontSize: 16, color: AppColors.textGray, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      ],
    );
  }

  Widget _buildChoiceCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String route,
  }) {
    return _HoverZoomCard(
      onTap: () => Navigator.pushNamed(context, route),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: AppDecorations.authCardDecoration(radius: 32), // Applied High-Depth Shadow
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(icon, color: iconColor, size: 30),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A1A1A),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF757575),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded, color: Colors.grey.shade300, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Column(children: [
      Wrap(alignment: WrapAlignment.center, spacing: 16, children: [
        _HoverZoomLink(onTap: () => LegalAgreementDialog.show(context, isTerms: true), child: Text(AppLocalizations.get('terms_conditions'), style: const TextStyle(color: AppColors.tealLink, fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.underline))),
        const Text('•', style: TextStyle(color: AppColors.textGray)),
        _HoverZoomLink(onTap: () => LegalAgreementDialog.show(context, isTerms: false), child: Text(AppLocalizations.get('privacy_policy'), style: const TextStyle(color: AppColors.tealLink, fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.underline))),
      ]),
      const SizedBox(height: 16),
      const Text('© 2026 Brgy. Balintawak Lipa City', style: TextStyle(color: Color(0xFF00796B), fontSize: 12, fontWeight: FontWeight.bold)),
      const Text('All rights reserved', style: TextStyle(color: Color(0xFF00796B), fontSize: 10)),
    ]);
  }
}

class _HoverZoomCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _HoverZoomCard({required this.child, required this.onTap});
  @override
  State<_HoverZoomCard> createState() => _HoverZoomCardState();
}
class _HoverZoomCardState extends State<_HoverZoomCard> {
  bool _isActive = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isActive = true),
      onExit: (_) => setState(() => _isActive = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isActive = true),
        onTapUp: (_) => setState(() => _isActive = false),
        onTapCancel: () => setState(() => _isActive = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isActive ? 1.03 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}

class _HoverZoomLink extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _HoverZoomLink({required this.child, required this.onTap});
  @override
  State<_HoverZoomLink> createState() => _HoverZoomLinkState();
}
class _HoverZoomLinkState extends State<_HoverZoomLink> {
  bool _isActive = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isActive = true),
      onExit: (_) => setState(() => _isActive = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isActive = true),
        onTapUp: (_) => setState(() => _isActive = false),
        onTapCancel: () => setState(() => _isActive = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isActive ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}
