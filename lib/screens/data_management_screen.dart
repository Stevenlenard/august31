import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/api_service.dart';

class DataManagementScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const DataManagementScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();
  
  List<dynamic> _backupHistory = [];
  bool _isLoading = true;
  bool _isBackingUp = false;

  @override
  void initState() {
    super.initState();
    _fetchBackupHistory();
  }

  // 1. UNIVERSAL SUCCESS CHECKER (String/Bool/Int Resilient)
  bool _isOperationSuccessful(dynamic data) {
    if (data == null) return false;
    if (data is! Map) return false;
    final val = data['success'];
    return (val == true || val == 1 || val.toString().toLowerCase() == "true" || val.toString() == "1");
  }

  Future<void> _fetchBackupHistory() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getBackupHistory();
      if (_isOperationSuccessful(response.data)) {
        setState(() {
          _backupHistory = response.data['backups'] ?? [];
          _isLoading = false;
        });
      } else {
        throw response.data['message'] ?? "Failed to load history";
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        debugPrint("History Fetch Error: $e");
      }
    }
  }

  Future<void> _triggerBackup() async {
    setState(() => _isBackingUp = true);
    try {
      final response = await _apiService.triggerBackup();
      if (_isOperationSuccessful(response.data)) {
        _showSuccessModal("Full system snapshot created successfully.");
        _fetchBackupHistory();
      } else {
        throw response.data['message'] ?? "Backup generation failed";
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Backup Error: $e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isBackingUp = false);
    }
  }

  Future<void> _downloadFile(String? url) async {
    if (url == null || url.isEmpty) return;
    final Uri uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw "Could not launch $url";
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Download Error: $e")));
      }
    }
  }

  Future<void> _exportFullSystem() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.exportData();
      final dynamic data = response.data;
      
      if (_isOperationSuccessful(data)) {
        final String? url = data['url'];
        if (url != null) {
          await _downloadFile(url);
          _showSuccessModal(data['message'] ?? "Snapshots bundled and downloaded successfully.");
        }
      } else {
        throw data['message'] ?? "Export failed on server";
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Export Error: $e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildControlsSection(),
            Expanded(
              child: _isLoading 
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFA5)))
                : _buildHistoryTable(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Color(0xFFE0E0E0)))),
      child: Row(
        children: [
          if (widget.onBack != null) IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Data Management", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              Text("Security Hub & Database Maintenance", style: TextStyle(fontSize: 12, color: Color(0xFF757575))),
            ],
          ),
          const Spacer(),
          _buildAutoBackupToggle(),
        ],
      ),
    );
  }

  Widget _buildAutoBackupToggle() {
    return StreamBuilder(
      stream: _database.ref('admin_settings/auto_backup').onValue,
      builder: (context, snapshot) {
        bool autoBackup = false;
        if (snapshot.hasData && snapshot.data!.snapshot.exists) {
          autoBackup = snapshot.data!.snapshot.value == true;
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(color: autoBackup ? const Color(0xFFE0F2F1) : const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12), border: Border.all(color: autoBackup ? const Color(0xFF00BFA5) : Colors.grey.shade300)),
          child: Row(
            children: [
              Text("Auto Backup", style: TextStyle(fontWeight: FontWeight.bold, color: autoBackup ? const Color(0xFF00BFA5) : Colors.black87)),
              const SizedBox(width: 8),
              Switch(value: autoBackup, activeColor: const Color(0xFF00BFA5), onChanged: (v) => _database.ref('admin_settings/auto_backup').set(v)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControlsSection() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
      child: Row(
        children: [
          _buildActionButton("BACKUP NOW", Icons.backup_rounded, const Color(0xFF1A1A1A), _isBackingUp ? null : _triggerBackup, isLoading: _isBackingUp),
          const SizedBox(width: 16),
          _buildActionButton("EXPORT REPORT", Icons.picture_as_pdf_rounded, const Color(0xFF00BFA5), _exportFullSystem),
          const Spacer(),
          Text("${_backupHistory.length} Total Snapshots", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildActionButton(String label, IconData icon, Color color, VoidCallback? onTap, {bool isLoading = false}) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: isLoading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : Icon(icon, size: 18, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      style: ElevatedButton.styleFrom(backgroundColor: color, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    );
  }

  Widget _buildHistoryTable() {
    if (_backupHistory.isEmpty) return const Center(child: Text("No snapshots found", style: TextStyle(color: Colors.grey)));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
        child: DataTable(
          headingRowColor: MaterialStateProperty.all(const Color(0xFF424242)),
          headingTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          columns: const [
            DataColumn(label: Text("Snapshot Name")),
            DataColumn(label: Text("Date")),
            DataColumn(label: Text("Size")),
            DataColumn(label: Text("Download")),
          ],
          rows: _backupHistory.map((backup) => DataRow(
            cells: [
              DataCell(Text(backup['filename'] ?? "N/A", style: const TextStyle(fontWeight: FontWeight.bold))),
              DataCell(Text(backup['date'] ?? "N/A")),
              DataCell(Text(backup['size'] ?? "N/A")),
              DataCell(IconButton(icon: const Icon(Icons.download_for_offline_rounded, color: Color(0xFF00BFA5)), onPressed: () => _downloadFile(backup['url']))),
            ],
          )).toList(),
        ),
      ),
    );
  }

  void _showSuccessModal(String message) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          padding: const EdgeInsets.all(32),
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.green, size: 80),
              const SizedBox(height: 24),
              const Text("Operation Success", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600, fontSize: 16)),
              const SizedBox(height: 32),
              SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () => Navigator.pop(context), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A1A1A), padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),
            ],
          ),
        ),
      ),
    );
  }
}
