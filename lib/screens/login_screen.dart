import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../api/api_service.dart';
import '../utils/app_theme.dart';
import '../widgets/legal_agreement_dialog.dart';
import '../utils/login_security_manager.dart';
import '../utils/session_manager.dart';
import '../widgets/animated_auth_background.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';
import '../utils/app_localizations.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscureText = true;

  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  String? _usernameError;
  String? _passwordError;

  SecurityStatus? _securityStatus;
  int _secondsRemaining = 0;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    _checkSecurityStatus();
    AppLocalizations.currentLanguage.addListener(_onLanguageChanged);
    _usernameFocus.addListener(() { 
      if (!_usernameFocus.hasFocus) {
        _validateUsername();
        _checkSecurityStatus();
      }
      setState(() {}); 
    });
    _passwordFocus.addListener(() { 
      if (!_passwordFocus.hasFocus) _validatePassword();
      setState(() {}); 
    });
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _lockoutTimer?.cancel();
    AppLocalizations.currentLanguage.removeListener(_onLanguageChanged);
    super.dispose();
  }

  void _validateUsername() {
    final val = _usernameController.text.trim();
    if (val.isEmpty) {
      setState(() => _usernameError = AppLocalizations.get('err_username_email'));
    } else {
      setState(() => _usernameError = null);
    }
  }

  void _validatePassword() {
    final val = _passwordController.text;
    if (val.isEmpty) {
      setState(() => _passwordError = AppLocalizations.get('err_password_req'));
    } else {
      setState(() => _passwordError = null);
    }
  }

  Future<void> _checkSecurityStatus() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) return;

    final status = await LoginSecurityManager.checkStatus(username);
    if (mounted) {
      setState(() {
        _securityStatus = status;
        if (status.isLocked && status.lockoutUntil != null) {
          final diff = status.lockoutUntil!.difference(DateTime.now()).inSeconds;
          if (diff > 0) {
            _secondsRemaining = diff;
            _startLockoutTimer();
          } else {
            // Lockout expired, reset immediately
            _secondsRemaining = 0;
            _securityStatus = SecurityStatus(attempts: 0, isLocked: false);
          }
        } else {
          _secondsRemaining = 0;
        }
      });
    }
  }

  void _startLockoutTimer() {
    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        if (_secondsRemaining > 0) {
          setState(() => _secondsRemaining--);
        } else {
          timer.cancel();
          _checkSecurityStatus();
        }
      } else {
        timer.cancel();
      }
    });
  }

  void _handleLogin() async {
    _validateUsername();
    _validatePassword();

    if (_usernameError != null || _passwordError != null) return;

    final username = _usernameController.text.trim();
    final status = await LoginSecurityManager.checkStatus(username);
    if (status.isLocked) {
      _checkSecurityStatus();
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await ApiService().login(
        username,
        _passwordController.text,
      );

      if (response.data['success'] == true) {
        await LoginSecurityManager.resetAttempts(username);
        if (!mounted) return;
        
        final user = response.data['user'];
        final role = user['role'];
        final name = user['name'] ?? username;

        // Save User to Session
        await SessionManager.saveUser(user);

        // Show Welcome Message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Welcome Back, $name!", style: const TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: const Color(0xFF00897B),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            margin: const EdgeInsets.all(20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );

        if (role == 'admin') {
          Navigator.pushReplacementNamed(context, '/admin_dashboard');
        } else if (role == 'driver') {
          Navigator.pushReplacementNamed(context, '/driver_dashboard', arguments: user);
        } else if (role == 'resident') {
          Navigator.pushReplacementNamed(context, '/resident_dashboard', arguments: user);
        }
      } else {
        await LoginSecurityManager.recordFailedAttempt(username);
        _checkSecurityStatus();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(response.data['message'] ?? AppLocalizations.get('err_auth_failed'), style: const TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.get('err_connection'), style: const TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _checkAndRequestPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    LocationPermission locationPermission = await Geolocator.checkPermission();
    PermissionStatus notificationStatus = await Permission.notification.status;

    if (!serviceEnabled || 
        (locationPermission == LocationPermission.denied || locationPermission == LocationPermission.deniedForever) || 
        !notificationStatus.isGranted) {
      
      return await _showPermissionDialog();
    }
    return true;
  }

  Future<bool> _showPermissionDialog() async {
    bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.settings_suggest_rounded, color: AppColors.tealText, size: 52),
              const SizedBox(height: 24),
              const Text("Permissions Required", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 16),
              const Text(
                "To use the Garbage Tracker, you must enable Location Services and allow Notifications. This ensures real-time tracking and collection alerts work correctly.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5),
              ),
              const SizedBox(height: 32),
              HoverActionButton(
                text: "Open Settings",
                onTap: () async {
                  await openAppSettings();
                  if (context.mounted) Navigator.pop(context, true);
                },
              ),
              const SizedBox(height: 16),
              _HoverZoomLink(
                onTap: () => Navigator.pop(context, false),
                child: const Text("Go Back", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
    return result ?? false;
  }

  void _showLanguageModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppLocalizations.get('select_language'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.tealText)),
              const SizedBox(height: 16),
              _buildLanguageItem(context, 'English (UK)', AppLanguage.en),
              _buildLanguageItem(context, 'Filipino', AppLanguage.fil),
              _buildLanguageItem(context, 'Bisaya', AppLanguage.bis),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLanguageItem(BuildContext context, String label, AppLanguage lang) {
    bool isSelected = AppLocalizations.currentLanguage.value == lang;
    return ListTile(
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.inputLabel)),
      leading: Icon(Icons.language_rounded, color: isSelected ? AppColors.tealText : Colors.grey),
      trailing: isSelected ? const Icon(Icons.check_circle, color: AppColors.tealText) : null,
      onTap: () {
        AppLocalizations.setLanguage(lang);
        Navigator.pop(context);
      },
    );
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
                      const Spacer(flex: 2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: Column(
                          children: [
                            FadeSlideEntrance(
                              delay: const Duration(milliseconds: 200),
                              child: _buildBranding(),
                            ),
                            const SizedBox(height: 32),
                            
                            FadeSlideEntrance(
                              delay: const Duration(milliseconds: 400),
                              child: Container(
                                padding: const EdgeInsets.all(28),
                                decoration: AppDecorations.authCardDecoration(), // Applied High-Depth Shadow
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (_securityStatus?.isLocked == true && _secondsRemaining > 0) _buildLockoutCard(),
                                      _buildRefinedTextField(
                                        label: AppLocalizations.get('username_email'),
                                        hint: AppLocalizations.get('enter_credentials'),
                                        controller: _usernameController,
                                        icon: Icons.person_outline_rounded,
                                        focus: _usernameFocus,
                                        error: _usernameError,
                                      ),
                                      const SizedBox(height: 24),
                                      _buildRefinedTextField(
                                        label: AppLocalizations.get('password'),
                                        hint: AppLocalizations.get('enter_password'),
                                        controller: _passwordController,
                                        isPassword: true,
                                        obscureText: _obscureText,
                                        onTogglePassword: () => setState(() => _obscureText = !_obscureText),
                                        icon: Icons.lock_outline_rounded,
                                        focus: _passwordFocus,
                                        error: _passwordError,
                                      ),
                                      const SizedBox(height: 12),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: _HoverZoomLink(
                                          onTap: () => Navigator.pushNamed(context, '/forgot_password'),
                                          child: Text(AppLocalizations.get('forgot_password'), style: const TextStyle(color: AppColors.tealLink, fontWeight: FontWeight.w700, fontSize: 13)),
                                        ),
                                      ),
                                      const SizedBox(height: 32),
                                      HoverActionButton(
                                        text: AppLocalizations.get('sign_in'),
                                        loadingText: AppLocalizations.get('confirming_credentials'),
                                        onTap: _handleLogin,
                                        isLoading: _isLoading,
                                      ),
                                      const SizedBox(height: 24),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(AppLocalizations.get('dont_have_account'), style: const TextStyle(color: AppColors.textGray, fontSize: 13)),
                                          _HoverZoomLink(
                                            onTap: () => Navigator.pushNamed(context, '/register'),
                                            child: Text(AppLocalizations.get('create_account'), style: const TextStyle(color: AppColors.tealLink, fontWeight: FontWeight.w900, fontSize: 13)),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(flex: 4), 
                      FadeSlideEntrance(
                        delay: const Duration(milliseconds: 600),
                        child: _buildFooter(),
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

  Widget _buildLockoutCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 24), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.red.shade200, width: 1.5)),
      child: Column(children: [
        Row(children: [Icon(Icons.lock_clock_rounded, color: Colors.red.shade900, size: 20), const SizedBox(width: 12), Expanded(child: Text('Security Lockout', style: TextStyle(color: Colors.red.shade900, fontWeight: FontWeight.bold)))]),
        const SizedBox(height: 8),
        Text('Login is temporarily disabled due to multiple failed attempts.', textAlign: TextAlign.center, style: TextStyle(color: Colors.red.shade900, fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text('${(_secondsRemaining ~/ 60).toString().padLeft(2, '0')}:${(_secondsRemaining % 60).toString().padLeft(2, '0')}', style: TextStyle(color: Colors.red.shade900, fontSize: 22, fontWeight: FontWeight.w900, fontFamily: 'monospace')),
        const SizedBox(height: 12),
        _HoverZoomLink(onTap: () => Navigator.pushNamed(context, '/forgot_password'), child: Text('Reset your password', style: TextStyle(color: Colors.red.shade900, fontSize: 13, fontWeight: FontWeight.bold, decoration: TextDecoration.underline))),
      ]),
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
            ],
          ),
          child: const Icon(Icons.local_shipping_rounded, size: 44, color: Colors.white),
        ),
        const SizedBox(height: 24),
        Text(
          AppLocalizations.get('garbage_tracker'), 
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: AppColors.tealText, letterSpacing: -1.2)
        ),
        Text(
          AppLocalizations.get('welcome_back'), 
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: AppColors.textGray, fontWeight: FontWeight.w600, letterSpacing: 0.5)
        ),
        const SizedBox(height: 12),
        _HoverZoomLink(
          onTap: _showLanguageModal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.currentLanguage.value == AppLanguage.en ? 'English (UK)' : 
                (AppLocalizations.currentLanguage.value == AppLanguage.fil ? 'Filipino' : 'Bisaya'),
                style: const TextStyle(color: AppColors.textGray, fontWeight: FontWeight.w700, fontSize: 13, decoration: TextDecoration.underline),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.textGray, size: 18),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
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

  Widget _buildRefinedTextField({required String label, required String hint, required TextEditingController controller, IconData? icon, bool isPassword = false, bool obscureText = false, VoidCallback? onTogglePassword, FocusNode? focus, String? error}) {
    bool hasFocus = focus?.hasFocus ?? false;
    
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(left: 4, bottom: 8), child: Text(label, style: const TextStyle(color: AppColors.inputLabel, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.2))),
      AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            if (hasFocus)
              BoxShadow(
                color: AppColors.tealText.withAlpha(30),
                blurRadius: 12,
                spreadRadius: 2,
              )
          ],
        ),
        child: TextFormField(
          controller: controller, focusNode: focus, obscureText: isPassword ? obscureText : false,
          cursorColor: const Color(0xFF424242),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.inputLabel),
          textInputAction: isPassword ? TextInputAction.done : TextInputAction.next,
          onFieldSubmitted: (_) { if (isPassword) _handleLogin(); },
          decoration: InputDecoration(
            hintText: hint, hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w400),
            prefixIcon: icon != null ? Icon(icon, color: hasFocus ? AppColors.tealText : AppColors.tealText.withAlpha(150), size: 20) : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18), filled: true, fillColor: hasFocus ? Colors.white : Colors.grey.shade50,
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: error != null ? Colors.redAccent : Colors.grey.shade200, width: 1.2)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: error != null ? Colors.redAccent : AppColors.tealText, width: 2.0)),
            suffixIcon: isPassword ? 
              IconButton(
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Icon(obscureText ? Icons.visibility_off_rounded : Icons.visibility_rounded, key: ValueKey(obscureText), color: hasFocus ? AppColors.tealText : Colors.grey.shade500, size: 20),
                ),
                onPressed: onTogglePassword
              ) : null,
          ),
        ),
      ),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 6, left: 4), child: Text(error, style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600))),
    ]);
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
