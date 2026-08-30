import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import '../api/api_service.dart';
import '../api/api_client.dart';
import '../widgets/legal_agreement_dialog.dart';
import '../widgets/animated_auth_background.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';
import '../utils/app_localizations.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  final FocusNode _emailFocus = FocusNode();
  final FocusNode _otpFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  final FocusNode _confirmPasswordFocus = FocusNode();

  String? _emailError;
  String? _otpError;
  String? _passwordError;
  String? _confirmPasswordError;

  final _formKey = GlobalKey<FormState>();
  final ApiService _apiService = ApiService();

  int _currentStep = 1; // 1: Email, 2: OTP, 3: New Password
  bool _isLoading = false;
  bool _isResending = false;
  bool _obscurePassword = true;

  // OTP Timer Logic
  Timer? _otpTimer;
  int _timerSecondsRemaining = 180; // 3 minutes
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    AppLocalizations.currentLanguage.addListener(_onLanguageChanged);
    _emailFocus.addListener(() => setState(() {}));
    _otpFocus.addListener(() => setState(() {}));
    _passwordFocus.addListener(() { 
      if (!_passwordFocus.hasFocus) _validatePassword();
      setState(() {});
    });
    _confirmPasswordFocus.addListener(() { 
      if (!_confirmPasswordFocus.hasFocus) _validateConfirmPassword();
      setState(() {});
    });
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _emailFocus.dispose();
    _otpFocus.dispose();
    _passwordFocus.dispose();
    _confirmPasswordFocus.dispose();
    _otpTimer?.cancel();
    AppLocalizations.currentLanguage.removeListener(_onLanguageChanged);
    super.dispose();
  }

  void _startOtpTimer() {
    _otpTimer?.cancel();
    setState(() {
      _timerSecondsRemaining = 180;
      _canResend = false;
    });
    _otpTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        if (_timerSecondsRemaining > 0) {
          setState(() => _timerSecondsRemaining--);
        } else {
          timer.cancel();
          setState(() {
            _canResend = true;
            _otpError = AppLocalizations.get('err_otp_expired');
          });
        }
      } else {
        timer.cancel();
      }
    });
  }

  String _formatTimer(int seconds) {
    final int m = seconds ~/ 60;
    final int s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _validateEmail() {
    final val = _emailController.text.trim();
    if (val.isEmpty) {
      setState(() => _emailError = AppLocalizations.get('err_email_reg'));
    } else if (!RegExp(r'^[\w-.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(val)) {
      setState(() => _emailError = AppLocalizations.get('err_email_format'));
    } else {
      setState(() => _emailError = null);
    }
  }

  void _validateOtp() {
    final val = _otpController.text;
    if (val.isEmpty) {
      setState(() => _otpError = AppLocalizations.get('err_otp_req'));
    } else if (val.length < 6) {
      setState(() => _otpError = AppLocalizations.get('err_otp_len'));
    } else if (_timerSecondsRemaining <= 0) {
      setState(() => _otpError = AppLocalizations.get('err_otp_expired'));
    } else {
      setState(() => _otpError = null);
    }
  }

  void _validatePassword() {
    final val = _passwordController.text;
    if (val.isEmpty) {
      setState(() => _passwordError = AppLocalizations.get('err_pass_new'));
    } else if (val.length < 6) {
      setState(() => _passwordError = AppLocalizations.get('err_pass_len'));
    } else {
      bool hasUpper = val.contains(RegExp(r'[A-Z]'));
      bool hasLower = val.contains(RegExp(r'[a-z]'));
      bool hasDigit = val.contains(RegExp(r'[0-9]'));
      bool hasSpecial = val.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));

      if (!hasUpper || !hasLower || !hasDigit || !hasSpecial) {
        setState(() => _passwordError = AppLocalizations.get('err_pass_complex'));
      } else {
        setState(() => _passwordError = null);
      }
    }
  }

  void _validateConfirmPassword() {
    if (_confirmPasswordController.text != _passwordController.text) {
      setState(() => _confirmPasswordError = AppLocalizations.get('err_pass_match'));
    } else {
      setState(() => _confirmPasswordError = null);
    }
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
                        child: _buildHeader(),
                      ),
                      const Spacer(flex: 2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: Column(
                          children: [
                            FadeSlideEntrance(
                              delay: const Duration(milliseconds: 300),
                              child: _buildBranding(),
                            ),
                            const SizedBox(height: 32),
                            FadeSlideEntrance(
                              delay: const Duration(milliseconds: 500),
                              child: _buildMainCard(),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(flex: 4),
                      FadeSlideEntrance(
                        delay: const Duration(milliseconds: 700),
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

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(150),
            borderRadius: BorderRadius.circular(12),
          ),
          child: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF00796B), size: 20),
            onPressed: () {
              if (_currentStep > 1) {
                setState(() {
                  _currentStep--;
                  _emailError = null;
                  _otpError = null;
                  _passwordError = null;
                  _confirmPasswordError = null;
                  if (_currentStep == 1) _otpTimer?.cancel();
                });
              } else {
                Navigator.pop(context);
              }
            },
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _currentStep == 1 ? AppLocalizations.get('verification') : (_currentStep == 2 ? AppLocalizations.get('enter_token') : AppLocalizations.get('new_password')),
              style: const TextStyle(
                color: AppColors.tealText,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: -1,
                height: 1,
              ),
            ),
            Text(
              AppLocalizations.get('account_recovery'),
              style: const TextStyle(
                color: AppColors.textGray,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBranding() {
    IconData icon = Icons.lock_reset_rounded;
    if (_currentStep == 2) icon = Icons.vibration_rounded;
    if (_currentStep == 3) icon = Icons.security_rounded;

    String mainTitle = AppLocalizations.get('verification');
    if (_currentStep == 2) mainTitle = AppLocalizations.get('enter_token');
    if (_currentStep == 3) mainTitle = AppLocalizations.get('new_password');

    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.loginButtonStart, AppColors.loginButtonEnd],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.loginButtonEnd.withAlpha(60),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(icon, size: 44, color: Colors.white),
        ),
        const SizedBox(height: 24),
        Text(mainTitle, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: AppColors.tealText, letterSpacing: -1.2)),
        Text(
          AppLocalizations.get('account_recovery'),
          style: const TextStyle(fontSize: 16, color: AppColors.textGray, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
      ],
    );
  }

  Widget _buildMainCard() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: AppDecorations.authCardDecoration(), // Applied High-Depth Shadow
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_currentStep == 1) _buildStep1Fields(),
            if (_currentStep == 2) _buildStep2Fields(),
            if (_currentStep == 3) _buildStep3Fields(),
            const SizedBox(height: 32),
            HoverActionButton(
              text: _currentStep == 1 ? AppLocalizations.get('send_verification') : (_currentStep == 2 ? AppLocalizations.get('verification_token') : AppLocalizations.get('reset_password')),
              loadingText: _currentStep == 1 ? AppLocalizations.get('verifying_email') : (_currentStep == 2 ? AppLocalizations.get('checking_token') : AppLocalizations.get('updating_password')),
              onTap: (_currentStep == 2 && _timerSecondsRemaining <= 0) ? null : _handleAction,
              isLoading: _isLoading,
            ),
            if (_currentStep == 2 && _timerSecondsRemaining <= 0) _buildResendSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildResendSection() {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Center(
        child: Column(
          children: [
            Text(
              AppLocalizations.get('didnt_receive_token'),
              style: const TextStyle(color: AppColors.textGray, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _isResending 
              ? const SizedBox(
                  height: 20, width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.tealText),
                )
              : _HoverZoomLink(
                  onTap: _canResend ? _resendToken : null,
                  child: Text(
                    AppLocalizations.get('resend_token'),
                    style: TextStyle(
                      color: _canResend ? AppColors.tealLink : Colors.grey.shade400,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep1Fields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            AppLocalizations.get('email_address'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.inputLabel, letterSpacing: 0.2),
          ),
        ),
        _buildRefinedTextField(
          controller: _emailController,
          focus: _emailFocus,
          hint: AppLocalizations.get('enter_reg_email'),
          icon: Icons.email_outlined,
          error: _emailError,
          keyboardType: TextInputType.emailAddress,
        ),
      ],
    );
  }

  Widget _buildStep2Fields() {
    bool isUrgent = _timerSecondsRemaining <= 30;
    bool isCritical = _timerSecondsRemaining <= 10;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                AppLocalizations.get('verification_token'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.inputLabel, letterSpacing: 0.2),
              ),
            ),
            if (_timerSecondsRemaining > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, right: 4),
                child: Text(
                  '${AppLocalizations.get('expires_in')}: ${_formatTimer(_timerSecondsRemaining)}',
                  style: TextStyle(
                    fontSize: 12, 
                    fontWeight: FontWeight.bold, 
                    color: isCritical ? Colors.redAccent : (isUrgent ? Colors.orange.shade800 : AppColors.textGray)
                  ),
                ),
              ),
          ],
        ),
        _buildRefinedTextField(
          controller: _otpController,
          focus: _otpFocus,
          hint: '000000',
          icon: Icons.vpn_key_outlined,
          error: _otpError,
          keyboardType: TextInputType.number,
          maxLength: 6,
          isOtp: true,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            "${AppLocalizations.get('code_sent_to')}: ${_emailController.text}",
            style: const TextStyle(fontSize: 12, color: AppColors.textGray, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildStep3Fields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            AppLocalizations.get('new_password'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.inputLabel, letterSpacing: 0.2),
          ),
        ),
        _buildRefinedTextField(
          controller: _passwordController,
          focus: _passwordFocus,
          hint: AppLocalizations.get('enter_password'),
          icon: Icons.lock_outline_rounded,
          error: _passwordError,
          isPassword: true,
          obscureText: _obscurePassword,
          onTogglePassword: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            AppLocalizations.get('confirm_password'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.inputLabel, letterSpacing: 0.2),
          ),
        ),
        _buildRefinedTextField(
          controller: _confirmPasswordController,
          focus: _confirmPasswordFocus,
          hint: AppLocalizations.get('confirm_your_password'),
          icon: Icons.lock_clock_outlined,
          error: _confirmPasswordError,
          isPassword: true,
          obscureText: _obscurePassword,
        ),
      ],
    );
  }

  Widget _buildRefinedTextField({required TextEditingController controller, required FocusNode focus, required String hint, required IconData icon, String? error, bool isPassword = false, bool obscureText = false, VoidCallback? onTogglePassword, TextInputType? keyboardType, int? maxLength, bool isOtp = false}) {
    bool hasFocus = focus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            controller: controller,
            focusNode: focus,
            obscureText: isPassword ? obscureText : false,
            keyboardType: keyboardType,
            maxLength: maxLength,
            cursorColor: const Color(0xFF424242),
            textAlign: isOtp ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: isOtp ? 24 : 15,
              fontWeight: isOtp ? FontWeight.w900 : FontWeight.w600,
              color: isOtp ? AppColors.tealText : AppColors.inputLabel,
              letterSpacing: isOtp ? 8 : null,
            ),
            decoration: InputDecoration(
              counterText: "",
              hintText: hint,
              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: isOtp ? 0 : null),
              prefixIcon: icon != null ? Icon(icon, color: hasFocus ? AppColors.tealText : AppColors.tealText.withAlpha(150), size: 20) : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              filled: true,
              fillColor: hasFocus ? Colors.white : Colors.grey.shade50,
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: error != null ? Colors.redAccent : Colors.grey.shade200, width: 1.2)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: error != null ? Colors.redAccent : AppColors.tealText, width: 2.0)),
              suffixIcon: isPassword ? IconButton(
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Icon(obscureText ? Icons.visibility_off_rounded : Icons.visibility_rounded, key: ValueKey(obscureText), color: hasFocus ? AppColors.tealText : Colors.grey.shade500, size: 20),
                ),
                onPressed: onTogglePassword
              ) : null,
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(error, style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  void _handleAction() {
    if (_currentStep == 1) {
      _validateEmail();
      if (_emailError == null) _sendEmail();
    } else if (_currentStep == 2) {
      _validateOtp();
      if (_otpError == null) _verifyOTP();
    } else if (_currentStep == 3) {
      _validatePassword();
      _validateConfirmPassword();
      if (_passwordError == null && _confirmPasswordError == null) _resetPassword();
    }
  }

  void _sendEmail() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.forgotPassword(_emailController.text.trim());
      if (response.data['success'] == true) {
        _showSuccess(response.data['message'] ?? AppLocalizations.get('verifying_email'));
        setState(() => _currentStep = 2);
        _startOtpTimer();
      } else {
        setState(() => _emailError = AppLocalizations.get('err_email_taken'));
      }
    } catch (e) {
      _showConnectionError();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _resendToken() async {
    setState(() => _isResending = true);
    try {
      final response = await _apiService.forgotPassword(_emailController.text.trim());
      if (response.data['success'] == true) {
        _showSuccess(AppLocalizations.get('processing'));
        setState(() {
          _otpError = null;
          _otpController.clear();
        });
        _startOtpTimer();
      } else {
        _showError(AppLocalizations.get('err_general'));
      }
    } catch (e) {
      _showConnectionError();
    } finally {
      if (mounted) setState(() => _isResending = false);
    }
  }

  void _verifyOTP() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.verifyOTP(_emailController.text.trim(), _otpController.text.trim());
      if (response.data['success'] == true) {
        _showSuccess(AppLocalizations.get('checking_token'));
        setState(() => _currentStep = 3);
        _otpTimer?.cancel();
      } else {
        setState(() => _otpError = AppLocalizations.get('err_otp_req'));
      }
    } catch (e) {
      _showConnectionError();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _resetPassword() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.resetPassword(
        _emailController.text.trim(),
        _otpController.text.trim(),
        _passwordController.text,
      );
      if (response.data['success'] == true) {
        _showSuccess(AppLocalizations.get('updating_password'));
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      } else {
        _showError(response.data['message'] ?? AppLocalizations.get('err_general'));
      }
    } catch (e) {
      _showConnectionError();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.green));
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.redAccent));
  }

  void _showConnectionError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.get('err_network')),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Widget _buildFooter() {
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          children: [
            _HoverZoomLink(
              onTap: () => LegalAgreementDialog.show(context, isTerms: true),
              child: Text(AppLocalizations.get('terms_conditions'), style: const TextStyle(color: AppColors.tealLink, fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
            ),
            const Text('•', style: TextStyle(color: AppColors.textGray)),
            _HoverZoomLink(
              onTap: () => LegalAgreementDialog.show(context, isTerms: false),
              child: Text(AppLocalizations.get('privacy_policy'), style: const TextStyle(color: AppColors.tealLink, fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('© 2026 Brgy. Balintawak Lipa City', style: TextStyle(color: Color(0xFF00796B), fontSize: 12, fontWeight: FontWeight.bold)),
        const Text('All rights reserved', style: TextStyle(color: Color(0xFF00796B), fontSize: 10)),
      ],
    );
  }
}

class _HoverZoomLink extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _HoverZoomLink({required this.child, this.onTap});
  @override
  State<_HoverZoomLink> createState() => _HoverZoomLinkState();
}
class _HoverZoomLinkState extends State<_HoverZoomLink> {
  bool _isActive = false;
  @override
  Widget build(BuildContext context) {
    bool isEnabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isActive = isEnabled),
      onExit: (_) => setState(() => _isActive = false),
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isActive = isEnabled),
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
