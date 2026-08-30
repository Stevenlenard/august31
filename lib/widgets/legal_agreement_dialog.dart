import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import '../utils/app_localizations.dart';

class LegalAgreementDialog extends StatelessWidget {
  final String title;
  final String content;

  const LegalAgreementDialog({
    super.key,
    required this.title,
    required this.content,
  });

  static void show(BuildContext context, {required bool isTerms}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ValueListenableBuilder(
        valueListenable: AppLocalizations.currentLanguage,
        builder: (context, lang, child) {
          return LegalAgreementDialog(
            title: isTerms ? AppLocalizations.get('terms_conditions') : AppLocalizations.get('privacy_policy'),
            content: isTerms ? AppLocalizations.getTerms() : AppLocalizations.getPrivacy(),
          );
        }
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(0, 12, 0, MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 24),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Row(
              children: [
                Icon(
                  title.contains('Terms') || title.contains('Tuntunin') || title.contains('Termino') 
                    ? Icons.gavel_rounded 
                    : Icons.privacy_tip_rounded,
                  color: AppColors.tealText,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: AppColors.tealText,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: Colors.grey),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Divider(height: 32),
          ),
          Flexible(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: Text(
                content,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: Colors.grey.shade800,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
