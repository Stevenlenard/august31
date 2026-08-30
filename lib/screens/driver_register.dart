import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../api/api_service.dart';
import '../utils/app_theme.dart';
import '../widgets/legal_agreement_dialog.dart';
import '../widgets/animated_auth_background.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';
import '../utils/app_localizations.dart';

class DriverRegisterScreen extends StatefulWidget {
  const DriverRegisterScreen({super.key});

  @override
  State<DriverRegisterScreen> createState() => _DriverRegisterScreenState();
}

class _DriverRegisterScreenState extends State<DriverRegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _licenseController = TextEditingController();
  final _phoneController = TextEditingController();
  final _truckController = TextEditingController();

  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _emailFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  final FocusNode _confirmPasswordFocus = FocusNode();
  final FocusNode _fullNameFocus = FocusNode();
  final FocusNode _licenseFocus = FocusNode();
  final FocusNode _phoneFocus = FocusNode();

  String? _usernameError;
  String? _emailError;
  String? _passwordError;
  String? _confirmPasswordError;
  String? _fullNameError;
  String? _licenseError;
  String? _phoneError;

  bool _isLoading = false;
  bool _obs1 = true;
  bool _obs2 = true;
  bool _termsAccepted = false;
  final ApiService _apiService = ApiService();

  @override
  void initState() {
    super.initState();
    AppLocalizations.currentLanguage.addListener(_onLanguageChanged);
    _usernameFocus.addListener(() { if (!_usernameFocus.hasFocus) _validateUsername(); setState(() {}); });
    _emailFocus.addListener(() { if (!_emailFocus.hasFocus) _validateEmail(); setState(() {}); });
    _passwordFocus.addListener(() { if (!_passwordFocus.hasFocus) _validatePassword(); setState(() {}); });
    _confirmPasswordFocus.addListener(() { if (!_confirmPasswordFocus.hasFocus) _validateConfirmPassword(); setState(() {}); });
    _fullNameFocus.addListener(() { if (!_fullNameFocus.hasFocus) _validateFullName(); setState(() {}); });
    _licenseFocus.addListener(() { if (!_licenseFocus.hasFocus) _validateLicense(); setState(() {}); });
    _phoneFocus.addListener(() { if (!_phoneFocus.hasFocus) _validatePhone(); setState(() {}); });
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _usernameFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _confirmPasswordFocus.dispose();
    _fullNameFocus.dispose();
    _licenseFocus.dispose();
    _phoneFocus.dispose();
    AppLocalizations.currentLanguage.removeListener(_onLanguageChanged);
    super.dispose();
  }

  Future<void> _validateUsername() async {
    final val = _usernameController.text.trim();
    if (val.isEmpty) {
      setState(() => _usernameError = AppLocalizations.get('err_username_email'));
      return;
    }
    try {
      final res = await _apiService.checkUsername(val);
      if (res.data['success'] == true) {
        setState(() => _usernameError = AppLocalizations.get('err_username_taken'));
      } else {
        setState(() => _usernameError = null);
      }
    } catch (e) {
      debugPrint("Check username error: $e");
    }
  }

  Future<void> _validateEmail() async {
    final val = _emailController.text.trim();
    if (val.isEmpty) {
      setState(() => _emailError = AppLocalizations.get('err_email_reg'));
      return;
    }
    if (!RegExp(r'^[\w-.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(val)) {
      setState(() => _emailError = AppLocalizations.get('err_email_format'));
      return;
    }
    try {
      final res = await _apiService.checkEmail(val);
      if (res.data['success'] == true) {
        setState(() => _emailError = AppLocalizations.get('err_email_taken'));
      } else {
        setState(() => _emailError = null);
      }
    } catch (e) {
      debugPrint("Check email error: $e");
    }
  }

  void _validatePassword() {
    final val = _passwordController.text;
    if (val.isEmpty) {
      setState(() => _passwordError = AppLocalizations.get('err_pass_new'));
      return;
    }
    if (val.length < 6) {
      setState(() => _passwordError = AppLocalizations.get('err_pass_len'));
      return;
    }
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

  void _validateConfirmPassword() {
    if (_confirmPasswordController.text != _passwordController.text) {
      setState(() => _confirmPasswordError = AppLocalizations.get('err_pass_match'));
    } else {
      setState(() => _confirmPasswordError = null);
    }
  }

  void _validateFullName() {
    final val = _fullNameController.text.trim();
    if (val.isEmpty) {
      setState(() => _fullNameError = AppLocalizations.get('err_name_req'));
      return;
    }
    if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(val)) {
      setState(() => _fullNameError = AppLocalizations.get('err_name_format'));
    } else {
      setState(() => _fullNameError = null);
    }
  }

  void _validateLicense() {
    final val = _licenseController.text.trim();
    if (val.isEmpty) {
      setState(() => _licenseError = AppLocalizations.get('err_license_req'));
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9!@#$%^&*(),.?":{}|<> -]+$').hasMatch(val)) {
      setState(() => _licenseError = AppLocalizations.get('err_license_format'));
    } else {
      setState(() => _licenseError = null);
    }
  }

  Future<void> _validatePhone() async {
    final val = _phoneController.text.trim();
    if (val.isEmpty) {
      setState(() => _phoneError = AppLocalizations.get('err_phone_req'));
      return;
    }
    if (!RegExp(r'^(09|63)\d{9}$').hasMatch(val)) {
      setState(() => _phoneError = AppLocalizations.get('err_phone_format'));
      return;
    }
    try {
      final res = await _apiService.checkPhone(val);
      if (res.data['success'] == true) {
        setState(() => _phoneError = AppLocalizations.get('err_phone_taken'));
      } else {
        setState(() => _phoneError = null);
      }
    } catch (e) {
      debugPrint("Check phone error: $e");
    }
  }

  void _submitRequest() async {
    setState(() => _isLoading = true);
    
    await _validateUsername();
    await _validateEmail();
    _validatePassword();
    _validateConfirmPassword();
    _validateFullName();
    _validateLicense();
    await _validatePhone();

    if (_usernameError != null || _emailError != null || _passwordError != null ||
        _confirmPasswordError != null || _fullNameError != null || _licenseError != null ||
        _phoneError != null || !_termsAccepted) {
      
      String msg = AppLocalizations.get('err_general');
      if (!_termsAccepted) msg = AppLocalizations.get('err_terms_req');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.redAccent));
      }
      setState(() => _isLoading = false);
      return;
    }

    try {
      final registerData = {
        'username': _usernameController.text.trim(),
        'name': _fullNameController.text.trim(),
        'email': _emailController.text.trim(),
        'password': _passwordController.text,
        'role': 'driver',
        'phone': _phoneController.text.trim(),
        'license_number': _licenseController.text.trim(),
        'preferred_truck': _truckController.text.trim(),
        'termsAccepted': 1,
        'privacyPolicyAccepted': 1,
        'termsVersion': '1.0',
        'privacyPolicyVersion': '1.0',
        'consentTimestamp': DateTime.now().toIso8601String(),
      };

      final response = await _apiService.register(registerData);

      if (response.data['success'] == true) {
        try {
          await FirebaseDatabase.instance.ref('notifications').push().set({
            "type": "REGISTRATION",
            "title": "New Driver Registered",
            "message": "${_fullNameController.text} has joined as a driver.",
            "timestamp": ServerValue.timestamp,
            "isRead": false,
            "relatedId": _usernameController.text.trim(),
          });
        } catch (e) {
          debugPrint("Firebase Notification Error: $e");
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response.data['message'] ?? 'Registration successful!'), backgroundColor: AppColors.tealText));
        
        // Bumalik sa simula (Welcome/Login Screen) para hindi mag-login nang hindi pa approved
        Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(response.data['message'] ?? 'Registration failed'), backgroundColor: Colors.redAccent));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.get('err_network')), backgroundColor: Colors.redAccent));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedAuthBackground(
      child: SafeArea(
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
                    const SizedBox(height: 16),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 500),
                        child: Column(
                          children: [
                            FadeSlideEntrance(
                              delay: const Duration(milliseconds: 300),
                              child: Container(
                                padding: const EdgeInsets.all(32),
                                decoration: AppDecorations.authCardDecoration(), // Applied High-Depth Shadow
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _buildSectionHeader(Icons.lock_outline_rounded, AppLocalizations.get('credentials')),
                                      const SizedBox(height: 8),
                                      _buildInput(_usernameController, AppLocalizations.get('username'), AppLocalizations.get('username'), icon: Icons.person_outline_rounded, focus: _usernameFocus, error: _usernameError),
                                      _buildInput(_emailController, AppLocalizations.get('email'), AppLocalizations.get('email'), icon: Icons.email_outlined, focus: _emailFocus, error: _emailError),
                                      _buildInput(_passwordController, AppLocalizations.get('password'), AppLocalizations.get('password'), isPass: true, obs: _obs1, onToggle: () => setState(() => _obs1 = !_obs1), icon: Icons.lock_outline_rounded, focus: _passwordFocus, error: _passwordError),
                                      _buildInput(_confirmPasswordController, AppLocalizations.get('confirm_password'), AppLocalizations.get('confirm_password'), isPass: true, obs: _obs2, onToggle: () => setState(() => _obs2 = !_obs2), icon: Icons.lock_clock_outlined, focus: _confirmPasswordFocus, error: _confirmPasswordError),

                                      const Padding(padding: EdgeInsets.symmetric(vertical: 32), child: Divider(height: 1, color: Color(0x1F000000))),

                                      _buildSectionHeader(Icons.local_shipping_outlined, AppLocalizations.get('work_info')),
                                      const SizedBox(height: 8),
                                      _buildInput(_fullNameController, AppLocalizations.get('full_name'), AppLocalizations.get('full_name'), icon: Icons.face_outlined, focus: _fullNameFocus, error: _fullNameError),
                                      _buildInput(_licenseController, AppLocalizations.get('license_number'), AppLocalizations.get('license_number'), icon: Icons.badge_outlined, focus: _licenseFocus, error: _licenseError),
                                      _buildInput(_phoneController, AppLocalizations.get('contact_number'), AppLocalizations.get('contact_number'), icon: Icons.phone_android_outlined, focus: _phoneFocus, error: _phoneError),
                                      _buildInput(_truckController, AppLocalizations.get('preferred_truck'), AppLocalizations.get('preferred_truck'), action: TextInputAction.done, icon: Icons.local_shipping_outlined, error: null),

                                      const SizedBox(height: 32),
                                      _buildTermsCheckbox(),
                                      const SizedBox(height: 32),
                                      HoverActionButton(
                                        text: AppLocalizations.get('register_as_driver'),
                                        loadingText: AppLocalizations.get('processing_registration'),
                                        onTap: _submitRequest,
                                        isLoading: _isLoading,
                                      ),

                                      const SizedBox(height: 16),
                                      Center(
                                        child: _HoverZoomLink(
                                          onTap: () => Navigator.pop(context),
                                          child: Text(AppLocalizations.get('back_to_login'), style: const TextStyle(color: AppColors.textGray, fontWeight: FontWeight.bold, fontSize: 15)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 48),
                    FadeSlideEntrance(
                      delay: const Duration(milliseconds: 500),
                      child: _buildFooter(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
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
        const SizedBox(height: 12),
        const Text('© 2026 Brgy. Balintawak Lipa City', style: TextStyle(color: Color(0xFF00796B), fontSize: 12, fontWeight: FontWeight.bold)),
        const Text('All rights reserved', style: TextStyle(color: Color(0xFF00796B), fontSize: 10)),
      ],
    );
  }

  Widget _buildTermsCheckbox() {
    return Row(
      children: [
        SizedBox(
          height: 24, width: 24,
          child: Checkbox(
            value: _termsAccepted,
            onChanged: (v) => setState(() => _termsAccepted = v ?? false),
            activeColor: AppColors.tealText,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            children: [
              Text(AppLocalizations.get('agree_terms'), style: const TextStyle(fontSize: 13, color: AppColors.textGray, fontWeight: FontWeight.w500)),
              _HoverZoomLink(
                onTap: () => LegalAgreementDialog.show(context, isTerms: true),
                child: Text(AppLocalizations.get('terms_conditions'), style: const TextStyle(fontSize: 13, color: AppColors.tealLink, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
              ),
              Text(AppLocalizations.get('and'), style: const TextStyle(fontSize: 13, color: AppColors.textGray, fontWeight: FontWeight.w500)),
              _HoverZoomLink(
                onTap: () => LegalAgreementDialog.show(context, isTerms: false),
                child: Text(AppLocalizations.get('privacy_policy'), style: const TextStyle(fontSize: 13, color: AppColors.tealLink, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(color: Colors.white.withAlpha(150), borderRadius: BorderRadius.circular(12)),
          child: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF00796B), size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLocalizations.get('driver'), style: const TextStyle(color: AppColors.tealText, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -1, height: 1)),
            Text(AppLocalizations.get('garbage_tracker'), style: const TextStyle(color: AppColors.textGray, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          ],
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: AppColors.tealText.withAlpha(30), shape: BoxShape.circle),
          child: const Icon(Icons.local_shipping_rounded, color: AppColors.tealText, size: 28),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, color: AppColors.tealText, size: 22),
        const SizedBox(width: 12),
        Text(title, style: const TextStyle(color: AppColors.tealText, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
      ],
    );
  }

  Widget _buildInput(TextEditingController ctrl, String label, String hint, {IconData? icon, bool isPass = false, bool obs = false, VoidCallback? onToggle, TextInputAction action = TextInputAction.next, FocusNode? focus, String? error}) {
    bool hasFocus = focus?.hasFocus ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 24, left: 4, bottom: 8), child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.inputLabel, letterSpacing: 0.2))),
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
            controller: ctrl, focusNode: focus, obscureText: obs, textInputAction: action,
            cursorColor: const Color(0xFF424242),
            inputFormatters: label.contains(AppLocalizations.get('contact_number')) ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)] : null,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.inputLabel),
            onFieldSubmitted: (_) { if(action == TextInputAction.done) _submitRequest(); },
            decoration: InputDecoration(
              hintText: hint, hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 15, fontWeight: FontWeight.w400),
              prefixIcon: icon != null ? Icon(icon, color: hasFocus ? AppColors.tealText : AppColors.tealText.withAlpha(150), size: 20) : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18), filled: true, fillColor: hasFocus ? Colors.white : Colors.grey.shade50,
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: error != null ? Colors.redAccent : Colors.grey.shade200, width: 1.5)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: error != null ? Colors.redAccent : AppColors.tealText, width: 2)),
              suffixIcon: isPass ? IconButton(icon: Icon(obs ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.grey.shade500, size: 20), onPressed: onToggle) : null,
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 8),
            child: Text(error, style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
      ],
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
