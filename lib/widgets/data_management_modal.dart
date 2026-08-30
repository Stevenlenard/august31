import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../models/user.dart';
import '../api/api_service.dart';
import '../utils/session_manager.dart';
import '../utils/app_localizations.dart';
import '../utils/app_theme.dart';
import '../utils/custom_notification.dart';
import 'hover_action_button.dart';

class DataManagementModal extends StatefulWidget {
  final UserData user;
  final VoidCallback onSuccess;

  const DataManagementModal({
    super.key,
    required this.user,
    required this.onSuccess,
  });

  @override
  State<DataManagementModal> createState() => _DataManagementModalState();
}

class _DataManagementModalState extends State<DataManagementModal> {
  final ApiService _apiService = ApiService();
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  late TextEditingController usernameCtrl;
  late TextEditingController nameCtrl;
  late TextEditingController emailCtrl;
  late TextEditingController phoneCtrl;
  late String selectedPurok;

  final usernameFocus = FocusNode();
  final nameFocus = FocusNode();
  final emailFocus = FocusNode();
  final phoneFocus = FocusNode();

  bool usernameTouched = false;
  bool nameTouched = false;
  bool emailTouched = false;
  bool phoneTouched = false;
  bool purokTouched = false;

  String? usernameError;
  String? nameError;
  String? emailError;
  String? phoneError;
  String? purokError;

  Color? usernameColor;
  Color? emailColor;
  Color? phoneColor;
  Color? purokColor;

  bool _isLoading = false;

  final List<String> _puroks = [
    "Purok 1", "Purok 2", "Purok 3", "Purok 4", "Dos Riles", "Sentro",
    "San Isidro", "Paraiso", "Riverside", "Kalaw Street",
    "Home Subdivision", "Tanco Road / Ayala Highway", "Brixton Area"
  ];

  @override
  void initState() {
    super.initState();
    usernameCtrl = TextEditingController(text: widget.user.username);
    nameCtrl = TextEditingController(text: widget.user.name);
    emailCtrl = TextEditingController(text: widget.user.email);
    phoneCtrl = TextEditingController(text: widget.user.phone);
    selectedPurok = widget.user.purok ?? "Sentro";

    usernameFocus.addListener(() {
      if (usernameFocus.hasFocus) usernameTouched = true;
      if (!usernameFocus.hasFocus) _validateUsername();
      if (mounted) setState(() {});
    });
    nameFocus.addListener(() {
      if (nameFocus.hasFocus) nameTouched = true;
      if (!nameFocus.hasFocus) _validateFullName();
      if (mounted) setState(() {});
    });
    emailFocus.addListener(() {
      if (emailFocus.hasFocus) emailTouched = true;
      if (!emailFocus.hasFocus) _validateEmail();
      if (mounted) setState(() {});
    });
    phoneFocus.addListener(() {
      if (phoneFocus.hasFocus) phoneTouched = true;
      if (!phoneFocus.hasFocus) _validatePhone();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    usernameCtrl.dispose();
    nameCtrl.dispose();
    emailCtrl.dispose();
    phoneCtrl.dispose();
    usernameFocus.dispose();
    nameFocus.dispose();
    emailFocus.dispose();
    phoneFocus.dispose();
    super.dispose();
  }

  Future<void> _validateUsername({bool force = false}) async {
    final val = usernameCtrl.text.trim();
    if (val.isEmpty) {
      setState(() { usernameError = AppLocalizations.get('err_username_email'); usernameColor = Colors.redAccent; });
      return;
    }
    if (val == widget.user.username) {
      if (usernameTouched || force) {
        setState(() { usernameError = "This is your current username"; usernameColor = Colors.blueAccent; });
      } else {
        setState(() { usernameError = null; usernameColor = null; });
      }
      return;
    }
    try {
      final res = await _apiService.checkUsername(val);
      if (res.data['success'] == true) {
        setState(() { usernameError = AppLocalizations.get('err_username_taken'); usernameColor = Colors.redAccent; });
      } else {
        setState(() { usernameError = null; usernameColor = null; });
      }
    } catch (e) {
      debugPrint("Check username error: $e");
    }
  }

  void _validateFullName() {
    final val = nameCtrl.text.trim();
    if (val.isEmpty) {
      setState(() { nameError = AppLocalizations.get('err_name_req'); });
      return;
    }
    if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(val)) {
      setState(() { nameError = AppLocalizations.get('err_name_format'); });
    } else {
      setState(() { nameError = null; });
    }
  }

  Future<void> _validateEmail({bool force = false}) async {
    final val = emailCtrl.text.trim();
    if (val.isEmpty) {
      setState(() { emailError = AppLocalizations.get('err_email_reg'); emailColor = Colors.redAccent; });
      return;
    }
    if (!RegExp(r'^[\w-.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(val)) {
      setState(() { emailError = AppLocalizations.get('err_email_format'); emailColor = Colors.redAccent; });
      return;
    }
    if (val == widget.user.email) {
      if (emailTouched || force) {
        setState(() { emailError = "This is your already email"; emailColor = Colors.blueAccent; });
      } else {
        setState(() { emailError = null; emailColor = null; });
      }
      return;
    }
    try {
      final res = await _apiService.checkEmail(val);
      if (res.data['success'] == true) {
        setState(() { emailError = AppLocalizations.get('err_email_taken'); emailColor = Colors.redAccent; });
      } else {
        setState(() { emailError = null; emailColor = null; });
      }
    } catch (e) {
      debugPrint("Check email error: $e");
    }
  }

  Future<void> _validatePhone({bool force = false}) async {
    final val = phoneCtrl.text.trim();
    if (val.isEmpty) {
      setState(() { phoneError = AppLocalizations.get('err_phone_req'); phoneColor = Colors.redAccent; });
      return;
    }
    if (!RegExp(r'^(09|63)\d{9}$').hasMatch(val)) {
      setState(() { phoneError = AppLocalizations.get('err_phone_format'); phoneColor = Colors.redAccent; });
      return;
    }
    if (val == widget.user.phone) {
      if (phoneTouched || force) {
        setState(() { phoneError = "This is your already number"; phoneColor = Colors.blueAccent; });
      } else {
        setState(() { phoneError = null; phoneColor = null; });
      }
      return;
    }
    try {
      final res = await _apiService.checkPhone(val);
      if (res.data['success'] == true) {
        setState(() { phoneError = AppLocalizations.get('err_phone_taken'); phoneColor = Colors.redAccent; });
      } else {
        setState(() { phoneError = null; phoneColor = null; });
      }
    } catch (e) {
      debugPrint("Check phone error: $e");
    }
  }

  void _validatePurok(String? val, {bool force = false}) {
    if (val == widget.user.purok) {
      if (purokTouched || force) {
        setState(() { purokError = "This is your current purok"; purokColor = Colors.blueAccent; });
      } else {
        setState(() { purokError = null; purokColor = null; });
      }
    } else {
      setState(() { purokError = null; purokColor = null; });
    }
  }

  Future<void> _submit() async {
    if (usernameTouched || usernameCtrl.text.trim() != (widget.user.username ?? "")) {
      await _validateUsername(force: true);
    }
    
    _validateFullName();
    
    if (emailTouched || emailCtrl.text.trim() != (widget.user.email ?? "")) {
      await _validateEmail(force: true);
    }
    
    if (phoneTouched || phoneCtrl.text.trim() != (widget.user.phone ?? "")) {
      await _validatePhone(force: true);
    }
    
    if (purokTouched || selectedPurok != (widget.user.purok ?? "")) {
      _validatePurok(selectedPurok, force: true);
    }

    if ((usernameError != null && usernameColor == Colors.redAccent) || 
        nameError != null || 
        (emailError != null && emailColor == Colors.redAccent) || 
        (phoneError != null && phoneColor == Colors.redAccent)) {
      return;
    }

    List<String> changedFields = [];
    if (usernameCtrl.text.trim() != (widget.user.username ?? "")) changedFields.add("username");
    if (nameCtrl.text.trim() != (widget.user.name ?? "")) changedFields.add("full name");
    if (emailCtrl.text.trim() != (widget.user.email ?? "")) changedFields.add("email");
    if (phoneCtrl.text.trim() != (widget.user.phone ?? "")) changedFields.add("contact number");
    if (selectedPurok != (widget.user.purok ?? "")) changedFields.add("purok");

    if (changedFields.isEmpty) {
      Navigator.pop(context);
      return;
    }

    bool confirm = await _showConfirmActionDialog(
      title: "Save Changes?",
      message: "Are you sure you want to update your profile information?",
      confirmText: "Save Changes",
      icon: Icons.save_rounded,
    );
    if (!confirm) return;

    setState(() => _isLoading = true);
    
    try {
      final response = await _apiService.updateResidentData({
        'user_id': widget.user.userId,
        'role': widget.user.role,
        'name': nameCtrl.text.trim(),
        'username': usernameCtrl.text.trim(),
        'phone': phoneCtrl.text.trim(),
        'email': emailCtrl.text.trim(),
        'purok': selectedPurok,
      });
      
      if (response.data['success'] == true) {
        await _database.ref('residents/${widget.user.userId}').update({
          'name': nameCtrl.text.trim(),
          'email': emailCtrl.text.trim(),
          'phone': phoneCtrl.text.trim(),
          'purok': selectedPurok,
        });

        final updatedUser = widget.user.copyWith(
          name: nameCtrl.text.trim(),
          username: usernameCtrl.text.trim(),
          email: emailCtrl.text.trim(),
          phone: phoneCtrl.text.trim(),
          purok: selectedPurok,
        );
        await SessionManager.saveUser(updatedUser.toJson());
        
        if (mounted) {
          Navigator.pop(context);
          widget.onSuccess();
          String successMsg = "Successful save changes information";
          if (changedFields.length == 1) {
            successMsg = "Successful save ${changedFields[0]}";
          }
          CustomNotification.showTopNotification(context, successMsg, false);
        }
      } else {
        CustomNotification.showTopNotification(context, response.data['message'] ?? "Update failed");
      }
    } catch (e) {
      CustomNotification.showTopNotification(context, "Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _showConfirmActionDialog({
    required String title,
    required String message,
    required IconData icon,
    String confirmText = "Confirm",
    bool isDestructive = false,
  }) async {
    return await showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isDestructive ? Colors.redAccent : AppColors.tealText, size: 48),
              const SizedBox(height: 24),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5),
              ),
              const SizedBox(height: 32),
              HoverActionButton(
                text: confirmText,
                isDestructive: isDestructive,
                onTap: () => Navigator.pop(context, true),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => Navigator.pop(context, false),
                child: const Text("Go Back", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    ) ?? false;
  }

  void _showPurokModal(String current, ValueChanged<String?> onSelected) {
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
              Text(AppLocalizations.get('select_purok'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.tealText)),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _puroks.length,
                  itemBuilder: (context, index) {
                    final p = _puroks[index];
                    bool isSelected = current == p;
                    return ListTile(
                      title: Text(p, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.inputLabel)),
                      leading: Icon(Icons.location_on_outlined, color: isSelected ? AppColors.tealText : Colors.grey),
                      trailing: isSelected 
                        ? Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(color: Color(0xFF00897B), shape: BoxShape.circle),
                            child: const Icon(Icons.check, color: Colors.white, size: 14),
                          )
                        : null,
                      onTap: () {
                        onSelected(p);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(0, 12, 0, MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10))),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(child: Text("Data Management", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Divider(height: 32),
          ),
          Flexible(
            child: Scrollbar(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildValidatedField(
                      label: "Username", 
                      controller: usernameCtrl, 
                      focusNode: usernameFocus, 
                      error: usernameError, 
                      errorColor: usernameColor,
                      obscureText: false, 
                      onToggle: () {}
                    ),
                    const SizedBox(height: 16),
                    _buildValidatedField(
                      label: "Full Name", 
                      controller: nameCtrl, 
                      focusNode: nameFocus, 
                      error: nameError, 
                      obscureText: false, 
                      onToggle: () {}
                    ),
                    const SizedBox(height: 16),
                    _buildValidatedField(
                      label: "Email Address", 
                      controller: emailCtrl, 
                      focusNode: emailFocus, 
                      error: emailError, 
                      errorColor: emailColor,
                      obscureText: false, 
                      onToggle: () {}
                    ),
                    const SizedBox(height: 16),
                    _buildValidatedField(
                      label: "Contact Number", 
                      controller: phoneCtrl, 
                      focusNode: phoneFocus, 
                      error: phoneError, 
                      errorColor: phoneColor,
                      obscureText: false, 
                      onToggle: () {}
                    ),
                    const SizedBox(height: 16),
                    _buildPurokDropdownWithValidation(
                      selectedPurok, 
                      (val) { 
                        purokTouched = true;
                        setState(() => selectedPurok = val!); 
                        _validatePurok(val); 
                      },
                      purokError,
                      purokColor
                    ),
                    const SizedBox(height: 32),
                    HoverActionButton(
                      text: "Save Changes",
                      loadingText: "Saving changes...",
                      isLoading: _isLoading,
                      onTap: _submit,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildValidatedField({
    required String label, 
    required TextEditingController controller, 
    required FocusNode focusNode, 
    String? error, 
    Color? errorColor,
    required bool obscureText, 
    required VoidCallback onToggle
  }) {
    bool hasFocus = focusNode.hasFocus;
    bool isPassword = label.toLowerCase().contains("password");
    bool isError = error != null && (errorColor == null || errorColor == Colors.redAccent);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              if (hasFocus)
                BoxShadow(color: (isError ? Colors.redAccent : AppColors.tealText).withValues(alpha: 30 / 255), blurRadius: 12, spreadRadius: 2)
            ],
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            obscureText: obscureText,
            cursorColor: const Color(0xFF424242),
            style: const TextStyle(fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              filled: true,
              fillColor: hasFocus ? Colors.white : const Color(0xFFF3F5F7),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isError ? Colors.redAccent : Colors.grey.shade200, width: 1.2)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isError ? Colors.redAccent : AppColors.tealText, width: 2.0)),
              suffixIcon: isPassword ? IconButton(icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: hasFocus ? (isError ? Colors.redAccent : AppColors.tealText) : Colors.grey.shade500, size: 20), onPressed: onToggle) : null,
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(error, style: TextStyle(color: errorColor ?? Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Widget _buildPurokDropdownWithValidation(String selected, ValueChanged<String?> onChanged, String? error, Color? errorColor) {
    bool isError = error != null && (errorColor == null || errorColor == Colors.redAccent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Purok / Area", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => _showPurokModal(selected, onChanged),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F5F7), 
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isError ? Colors.redAccent : Colors.transparent, width: 1.2),
            ),
            child: Row(
              children: [
                Icon(Icons.location_on_outlined, color: isError ? Colors.redAccent : const Color(0xB400796B), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    selected,
                    style: const TextStyle(color: AppColors.inputLabel, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(Icons.keyboard_arrow_down_rounded, color: isError ? Colors.redAccent : AppColors.tealText, size: 24),
              ],
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(error, style: TextStyle(color: errorColor ?? Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
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
