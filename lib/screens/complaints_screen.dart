import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import '../api/api_service.dart';

class ComplaintsScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const ComplaintsScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<ComplaintsScreen> createState() => _ComplaintsScreenState();
}

class _ComplaintsScreenState extends State<ComplaintsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();
  List<dynamic> _residentComplaints = [];
  List<dynamic> _driverIssues = [];
  bool _isLoadingResident = true;
  bool _isLoadingDriver = true;
  StreamSubscription? _driverIssuesSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _fetchResidentComplaints();
    _listenToDriverIssues();
  }

  @override
  void dispose() {
    _driverIssuesSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _fetchResidentComplaints() async {
    setState(() => _isLoadingResident = true);
    try {
      final response = await _apiService.getComplaints();
      if (response.data['success'] == true) {
        setState(() { 
          _residentComplaints = response.data['data']; 
          _isLoadingResident = false; 
        });
      }
    } catch (e) { 
      if (mounted) setState(() => _isLoadingResident = false); 
    }
  }

  void _listenToDriverIssues() {
    _driverIssuesSubscription?.cancel();
    _driverIssuesSubscription = _database.ref('truck_issues').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List list = [];
        data.forEach((key, value) {
          list.add({...Map<String, dynamic>.from(value as Map), 'id': key});
        });
        // Sort newest first
        list.sort((a, b) => (b['createdAt'] ?? 0).compareTo(a['createdAt'] ?? 0));
        if (mounted) {
          setState(() {
            _driverIssues = list;
            _isLoadingDriver = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _driverIssues = [];
            _isLoadingDriver = false;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Resolve Radar", style: TextStyle(fontWeight: FontWeight.bold)),
        leading: widget.onBack != null ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack) : null,
        bottom: TabBar(
          controller: _tabController, 
          tabs: [
            Tab(text: "RESIDENTS (${_residentComplaints.length})"), 
            Tab(text: "DRIVERS (${_driverIssues.length})")
          ]
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _isLoadingResident ? const Center(child: CircularProgressIndicator()) : _buildList(true),
          _isLoadingDriver ? const Center(child: CircularProgressIndicator()) : _buildList(false)
        ],
      ),
    );
  }

  Widget _buildList(bool isResident) {
    final list = isResident ? _residentComplaints : _driverIssues;
    if (list.isEmpty) return const Center(child: Text("No items found"));
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: list.length,
      itemBuilder: (context, i) => _buildCard(list[i], isResident),
    );
  }

  Widget _buildCard(dynamic c, bool isResident) {
    String status = (c['status'] ?? 'PENDING').toString().toUpperCase().replaceAll('_', ' ');
    Color statusColor = Colors.orange;
    if (status == 'RESOLVED') statusColor = Colors.green;
    if (status == 'IN PROGRESS' || status == 'UNDER REVIEW') statusColor = Colors.blue;

    String title = isResident ? (c['category'] ?? "General") : (c['issueType'] ?? "Truck Issue");
    String subtitle = isResident ? (c['description'] ?? "") : (c['driverName'] ?? "Unknown Driver");
    String truckInfo = !isResident ? " - ${c['truckId'] ?? ''}" : "";

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.grey.shade100)),
      elevation: 2,
      shadowColor: Colors.black.withOpacity(0.05),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
            if (!isResident) ...[
              _buildUrgencyBadge(c['urgency'] ?? 'Medium'),
              const SizedBox(width: 8),
            ],
            _buildStatusBadge(status, statusColor),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(subtitle + truckInfo, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              isResident ? (c['created_at'] ?? '') : DateFormat('MMM dd, yyyy • h:mm a').format(DateTime.fromMillisecondsSinceEpoch(c['createdAt'] ?? 0)),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        onTap: () => _showDetailsModal(c, isResident),
      ),
    );
  }

  Widget _buildUrgencyBadge(dynamic urgency) {
    String u = urgency.toString().toUpperCase();
    Color color = _getUrgencyColor(urgency);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.2))),
      child: Text(u, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900)),
    );
  }

  Widget _buildStatusBadge(String status, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.2))),
      child: Text(status, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
    );
  }

  void _showDetailsModal(dynamic item, bool isResident) {
    final String status = (item['status'] ?? 'PENDING').toString().toUpperCase();
    final TextEditingController responseController = TextEditingController(text: item['adminResponse'] ?? item['admin_response'] ?? "");

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.8,
          maxChildSize: 0.9,
          minChildSize: 0.5,
          expand: false,
          builder: (context, scrollController) => Container(
            padding: const EdgeInsets.all(32),
            child: ListView(
              controller: scrollController,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(isResident ? "Resident Complaint" : "Driver Report", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                  ],
                ),
                const SizedBox(height: 24),
                _buildInfoSection("REPORTER", isResident ? (item['full_name'] ?? 'Unknown') : (item['driverName'] ?? 'Unknown')),
                if (!isResident) _buildInfoSection("TRUCK ID", item['truckId'] ?? 'N/A'),
                _buildInfoSection("CATEGORY / ISSUE", isResident ? (item['category'] ?? 'General') : (item['issueType'] ?? 'N/A')),
                if (!isResident) _buildInfoSection("URGENCY", (item['urgency'] ?? 'Medium').toString().toUpperCase(), color: _getUrgencyColor(item['urgency'])),
                _buildInfoSection("DESCRIPTION", isResident ? (item['description'] ?? '') : (item['description'] ?? '')),
                _buildInfoSection("SUBMITTED", isResident ? (item['created_at'] ?? '') : DateFormat('MMM dd, yyyy • h:mm a').format(DateTime.fromMillisecondsSinceEpoch(item['createdAt'] ?? 0))),
                const Divider(height: 48),
                const Text("ADMIN ACTION", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.1, color: Colors.grey)),
                const SizedBox(height: 16),
                TextField(
                  controller: responseController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: "Enter response to the ${isResident ? 'resident' : 'driver'}...",
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    if (status != 'IN_PROGRESS' && status != 'RESOLVED')
                      Expanded(child: _buildActionButton("MARK IN PROGRESS", Colors.blue, () => _updateStatus(item, 'IN_PROGRESS', responseController.text, isResident))),
                    const SizedBox(width: 12),
                    if (status != 'RESOLVED')
                      Expanded(child: _buildActionButton("RESOLVE", Colors.green, () => _updateStatus(item, 'RESOLVED', responseController.text, isResident))),
                  ],
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoSection(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.grey, letterSpacing: 1)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color ?? Colors.black87)),
        ],
      ),
    );
  }

  Widget _buildActionButton(String label, Color color, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 16),
        elevation: 0,
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
    );
  }

  Color _getUrgencyColor(dynamic urgency) {
    String u = urgency.toString().toLowerCase();
    if (u == 'critical') return Colors.red;
    if (u == 'high') return Colors.orange.shade900;
    if (u == 'medium') return Colors.orange;
    return Colors.blue;
  }

  Future<void> _updateStatus(dynamic item, String newStatus, String adminResponse, bool isResident) async {
    try {
      if (isResident) {
        await _apiService.updateComplaint(int.parse(item['id'].toString()), newStatus.toLowerCase(), adminResponse);
        
        // Notify Resident if resolved
        if (newStatus == 'RESOLVED') {
          await _database.ref('notifications').push().set({
            'type': 'COMPLAINT_RESOLVED',
            'title': 'Complaint Resolved',
            'message': 'Your complaint regarding ${item['category']} has been resolved.',
            'resident_id': item['user_id']?.toString(),
            'relatedId': item['id'],
            'timestamp': ServerValue.timestamp,
            'isRead': false,
          });
        }

        await _fetchResidentComplaints();
      } else {
        final updates = {
          'status': newStatus,
          'adminResponse': adminResponse,
          'updatedAt': ServerValue.timestamp,
        };
        if (newStatus == 'RESOLVED') {
          updates['resolvedAt'] = ServerValue.timestamp;
        }
        await _database.ref('truck_issues/${item['id']}').update(updates);
        
        // Notify Driver
        await _database.ref('notifications').push().set({
          'type': 'ISSUE_UPDATE',
          'title': 'Truck Issue ${newStatus.replaceAll('_', ' ')}',
          'message': 'Your report regarding ${item['issueType']} has been updated to ${newStatus.replaceAll('_', ' ')}.',
          'truck_id': item['truckId'],
          'relatedId': item['id'],
          'timestamp': ServerValue.timestamp,
          'isRead': false,
        });
      }
      
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Report updated to $newStatus")));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }
}
