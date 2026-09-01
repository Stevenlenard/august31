import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../api/api_service.dart';
import '../utils/app_theme.dart';
import '../utils/session_manager.dart';
import '../widgets/hover_action_button.dart';
import '../widgets/fade_slide_entrance.dart';

class ResidentComplaintsScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const ResidentComplaintsScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<ResidentComplaintsScreen> createState() => _ResidentComplaintsScreenState();
}

class _ResidentComplaintsScreenState extends State<ResidentComplaintsScreen> {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  List<dynamic> _complaints = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchComplaints();
  }

  Future<void> _fetchComplaints() async {
    setState(() => _isLoading = true);
    final user = await SessionManager.getUser();
    try {
      final response = await _apiService.getComplaints();
      if (response.data['success'] == true) {
        final List all = response.data['data'];
        final List filtered = all.where((c) => c['user_id'].toString() == user?.userId.toString()).toList();
        setState(() {
          _complaints = filtered;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteFromFirebase(int id) async {
    try {
      // 1. Delete the complaint record itself from Firebase
      final snapshot = await _database.ref('complaints').get();
      if (snapshot.exists) {
        final Map data = snapshot.value as Map;
        data.forEach((key, value) {
          if (value is Map && (value['complaint_id']?.toString() == id.toString() || value['id']?.toString() == id.toString())) {
            _database.ref('complaints/$key').remove();
          }
        });
      }

      // 2. Cleanup associated notifications in Firebase
      final notifRef = _database.ref('notifications');
      final notifSnapshot = await notifRef.get();
      
      if (notifSnapshot.exists) {
        final Map notifData = notifSnapshot.value as Map;
        notifData.forEach((key, value) {
          if (value is Map) {
            // Kung ang notif ay tungkol sa complaint na ito
            if (value['type'] == 'COMPLAINT_RESOLVED' && 
                value['relatedId']?.toString() == id.toString()) {
              notifRef.child(key).remove();
            }
          }
        });
      }
    } catch (e) {
      debugPrint("Firebase complaint/notif cleanup error: $e");
    }
  }

  void _handleDelete(int index) async {
    final complaint = _complaints[index];
    final int id = int.tryParse(complaint['complaint_id'].toString()) ?? 0;

    bool confirmed = await _showConfirmDialog(
      title: "Delete Complaint?",
      message: "This action cannot be undone. Are you sure you want to remove this record?",
    );

    if (confirmed) {
      try {
        final response = await _apiService.deleteComplaint(id);
        if (response.data['success'] == true) {
          await _deleteFromFirebase(id);
          final removedItem = _complaints.removeAt(index);
          _listKey.currentState?.removeItem(
            index,
            (context, animation) => _buildOrganizedComplaintItem(removedItem, animation),
            duration: const Duration(milliseconds: 300),
          );
          _showSnackBar("Successful delete complaint");
          setState(() {}); // Refresh counts
        }
      } catch (e) {
        _showSnackBar("Failed to delete: $e", isError: true);
      }
    }
  }

  void _handleClearAll() async {
    if (_complaints.isEmpty) return;

    bool confirmed = await _showConfirmDialog(
      title: "Clear All History?",
      message: "Are you sure you want to permanently delete all your complaint records?",
    );

    if (confirmed) {
      try {
        List<int> ids = _complaints.map((c) => int.tryParse(c['complaint_id'].toString()) ?? 0).toList();
        final response = await _apiService.bulkDeleteComplaints(ids);
        
        if (response.data['success'] == true) {
          for (int id in ids) {
            await _deleteFromFirebase(id);
          }
          
          for (int i = _complaints.length - 1; i >= 0; i--) {
            final removedItem = _complaints.removeAt(i);
            _listKey.currentState?.removeItem(
              i,
              (context, animation) => _buildOrganizedComplaintItem(removedItem, animation),
              duration: const Duration(milliseconds: 200),
            );
            await Future.delayed(const Duration(milliseconds: 100));
          }
          _showSnackBar("Successful cleared all complaint");
          setState(() {}); // Refresh UI
        }
      } catch (e) {
        _showSnackBar("Bulk delete failed: $e", isError: true);
      }
    }
  }

  Future<bool> _showConfirmDialog({required String title, required String message}) async {
    return await showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 48),
            const SizedBox(height: 24),
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, height: 1.5)),
            const SizedBox(height: 32),
            HoverActionButton(
              text: "Confirm Delete",
              isDestructive: true,
              onTap: () => Navigator.pop(context, true)
            ),
            const SizedBox(height: 16),
            _HoverZoomLink(
              onTap: () => Navigator.pop(context, false), 
              child: const Text("Go Back", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700, fontSize: 15))
            ),
          ]),
        ),
      ),
    ) ?? false;
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF00897B),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    int pending = _complaints.where((c) => c['status'].toString().toLowerCase() == 'pending').length;
    int inProgress = _complaints.where((c) => c['status'].toString().toLowerCase() == 'in_progress').length;
    int resolved = _complaints.where((c) => c['status'].toString().toLowerCase() == 'resolved').length;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: FadeSlideEntrance(
        child: SafeArea(
          child: Column(
            children: [
              // 🏛️ POLISHED HEADER
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
                ),
                child: Row(
                  children: [
                    if (!widget.isEmbedded || widget.onBack != null)
                      _buildCircularBackButton(),
                    const SizedBox(width: 12),
                    const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text("My Complaints", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A), letterSpacing: -0.5)),
                      Text("Track your submitted reports", style: TextStyle(fontSize: 11, color: Color(0xFF757575), fontWeight: FontWeight.w600)),
                    ])),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.history_edu_rounded, color: Color(0xFF00897B), size: 24)
                    ),
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: [
                      // 📊 BALANCED SUMMARY CARDS
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                        child: Row(
                          children: [
                            _buildSummaryCard("Pending", pending.toString(), const Color(0xFFE0F2F1), const Color(0xFF00796B), Icons.hourglass_empty_rounded),
                            const SizedBox(width: 12),
                            _buildSummaryCard("Active", inProgress.toString(), const Color(0xFFE3F2FD), const Color(0xFF1976D2), Icons.bolt_rounded),
                            const SizedBox(width: 12),
                            _buildSummaryCard("Solved", resolved.toString(), const Color(0xFFE8F5E9), const Color(0xFF2E7D32), Icons.verified_rounded),
                          ],
                        ),
                      ),

                      // ➕ PRO ACTION BUTTON
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 800),
                          child: HoverActionButton(
                            text: "New Complaint",
                            onTap: () => _showAddComplaintModal(context),
                          ),
                        ),
                      ),

                      if (_complaints.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 800),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _HoverZoomLink(
                              onTap: _handleClearAll,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.delete_sweep_rounded, size: 18, color: Color(0xFF00796B)),
                                  const SizedBox(width: 8),
                                  const Text("Clear All History", style: TextStyle(color: Color(0xFF00796B), fontWeight: FontWeight.w800, fontSize: 13)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // 📋 REFINED COMPLAINTS LIST
                      if (_isLoading)
                        const Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator(color: Color(0xFF00897B)))
                      else if (_complaints.isEmpty)
                        _buildEmptyState()
                      else
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 800),
                            child: AnimatedList(
                              key: _listKey,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              initialItemCount: _complaints.length,
                              itemBuilder: (context, index, animation) {
                                if (index >= _complaints.length) return const SizedBox();
                                return _buildDismissibleItem(_complaints[index], index, animation);
                              },
                            ),
                          ),
                        ),
                      const SizedBox(height: 120),
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

  void _showAddComplaintModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddComplaintModal(onSuccess: _fetchComplaints),
    );
  }

  Widget _buildSummaryCard(String label, String count, Color bgColor, Color textColor, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: bgColor, 
          borderRadius: BorderRadius.circular(28), 
          boxShadow: AppTheme.pulidongShadow
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: textColor, size: 22),
            const SizedBox(height: 8),
            Text(count, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: textColor, letterSpacing: -0.5)),
            Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: textColor, letterSpacing: 0.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildCircularBackButton() {
    return GestureDetector(
      onTap: () {
        if (widget.onBack != null) {
          widget.onBack!();
        } else {
          Navigator.pop(context);
        }
      },
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF1A1A1A), size: 18),
      ),
    );
  }

  Widget _buildDismissibleItem(dynamic complaint, int index, Animation<double> animation) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Dismissible(
        key: Key(complaint['complaint_id'].toString()),
        direction: DismissDirection.horizontal,
        confirmDismiss: (dir) async => await _showConfirmDialog(title: "Delete this record?", message: "This entry will be permanently removed from your history."),
        onDismissed: (dir) async {
           // We don't need confirm here as confirmDismiss handled it
           final int id = int.tryParse(complaint['complaint_id'].toString()) ?? 0;
           try {
             _complaints.removeAt(index);
             await _apiService.deleteComplaint(id);
             await _deleteFromFirebase(id);
             _showSnackBar("Successful delete complaint");
             setState(() {});
           } catch (_) {}
        },
        background: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(28)),
          alignment: Alignment.centerLeft,
          child: const Icon(Icons.delete_outline_rounded, color: Colors.red),
        ),
        secondaryBackground: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(28)),
          alignment: Alignment.centerRight,
          child: const Icon(Icons.delete_outline_rounded, color: Colors.red),
        ),
        child: _buildOrganizedComplaintItem(complaint, animation),
      ),
    );
  }

  Widget _buildOrganizedComplaintItem(dynamic complaint, Animation<double> animation) {
    String status = (complaint['status'] ?? 'PENDING').toString().toUpperCase();
    Color statusColor = status == 'PENDING' ? Colors.orange : (status == 'RESOLVED' ? Colors.green : Colors.blue);
    String adminResponse = (complaint['admin_response'] ?? '').toString().trim();

    return FadeTransition(
      opacity: animation,
      child: SizeTransition(
        sizeFactor: animation,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [BoxShadow(color: Colors.black.withAlpha(6), blurRadius: 12, offset: const Offset(0, 4))],
            border: Border.all(color: const Color(0xFFF8F9FA), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(complaint['category'] ?? "General", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: Color(0xFF1A1A1A))),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: statusColor.withAlpha(20), borderRadius: BorderRadius.circular(10)), child: Text(status, style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w900))),
                ],
              ),
              const SizedBox(height: 12),
              Text(complaint['description'] ?? "", style: const TextStyle(color: Color(0xFF616161), fontSize: 14, height: 1.5, fontWeight: FontWeight.w500)),
              
              if (adminResponse.isNotEmpty) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9), // Light Green Background
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.green.shade100),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded, size: 14, color: Colors.green.shade800),
                          const SizedBox(width: 8),
                          Text(
                            "ADMIN RESPONSE",
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.green.shade800, letterSpacing: 0.5)
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        adminResponse,
                        style: TextStyle(color: Colors.green.shade900, fontSize: 13, height: 1.4, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),
              Row(children: [const Icon(Icons.calendar_today_rounded, size: 12, color: Colors.black26), const SizedBox(width: 8), Text(complaint['created_at']?.toString().split('T')[0] ?? "2026-06-27", style: const TextStyle(color: Colors.black26, fontSize: 11, fontWeight: FontWeight.w800))]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(64),
      child: Column(children: [
        Container(padding: const EdgeInsets.all(24), decoration: const BoxDecoration(color: Color(0xFFF5F5F5), shape: BoxShape.circle), child: const Icon(Icons.assignment_turned_in_rounded, size: 56, color: Colors.black12)),
        const SizedBox(height: 24),
        const Text("Clear History", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))),
        const SizedBox(height: 8),
        const Text("All your system complaints will appear here once submitted.", textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF757575), fontSize: 13, height: 1.4)),
      ]),
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
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _active = true), 
      onExit: (_) => setState(() => _active = false), 
      cursor: SystemMouseCursors.click, 
      child: GestureDetector(
        onTap: widget.onTap, 
        onTapDown: (_) => setState(() => _active = true), 
        onTapUp: (_) => setState(() => _active = false), 
        onTapCancel: () => setState(() => _active = false),
        child: AnimatedScale(scale: _active ? 1.05 : 1.0, duration: const Duration(milliseconds: 200), child: widget.child)
      )
    );
  }
}
class AddComplaintModal extends StatefulWidget {
  final VoidCallback onSuccess;
  const AddComplaintModal({required this.onSuccess});

  @override
  State<AddComplaintModal> createState() => AddComplaintModalState();
}

class AddComplaintModalState extends State<AddComplaintModal> {
  final ApiService _apiService = ApiService();
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final TextEditingController _descriptionController = TextEditingController();
  String _selectedCategory = 'Uncollected Garbage';
  bool _isLoading = false;

  final List<String> _categories = [
    'Uncollected Garbage',
    'Spilled Waste',
    'Driver Behavior',
    'Schedule Issue',
    'Other'
  ];

  void _showCategoryPicker() {
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
              const Text("Select Category", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _categories.length,
                  itemBuilder: (context, index) {
                    final c = _categories[index];
                    bool isSelected = _selectedCategory == c;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
                      title: Text(c, style: TextStyle(fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600, color: isSelected ? const Color(0xFF00897B) : const Color(0xFF1A1A1A))),
                      trailing: isSelected 
                        ? Container(padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: Color(0xFF00897B), shape: BoxShape.circle), child: const Icon(Icons.check, color: Colors.white, size: 14))
                        : null,
                      onTap: () {
                        setState(() => _selectedCategory = c);
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

  void _submit() async {
    final desc = _descriptionController.text.trim();
    if (desc.isEmpty) {
      _showSnackBar("Please provide issue details", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    final user = await SessionManager.getUser();

    try {
      final response = await _apiService.fileComplaint(
        user?.userId.toString() ?? "0",
        _selectedCategory,
        desc,
      );

      if (response.data['success'] == true) {
        await _database.ref('notifications').push().set({
          'type': 'RESIDENT_COMPLAINT',
          'title': 'New Resident Complaint',
          'message': '${user?.name ?? 'A resident'} filed a complaint: $_selectedCategory',
          'resident_id': user?.userId,
          'timestamp': ServerValue.timestamp,
          'isRead': false,
        });

        if (!mounted) return;
        Navigator.pop(context);
        widget.onSuccess();
        _showSnackBar("Complaint submitted successfully");
      }
    } catch (e) {
      if (mounted) _showSnackBar("Error: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF00897B),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(0, 12, 0, MediaQuery.of(context).viewInsets.bottom + 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32))
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)))),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(child: Text("New Complaint", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.tealText))),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.grey)),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Divider(height: 32),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Select Category", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.grey)),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: _showCategoryPicker,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade200)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_selectedCategory, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1A1A1A))),
                          const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text("Describe the issue", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.grey)),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(16)),
                    child: TextField(
                      controller: _descriptionController,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      decoration: const InputDecoration(
                        hintText: "Tell us more...",
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  HoverActionButton(
                    text: "Submit Complaint",
                    loadingText: "Submitting...",
                    isLoading: _isLoading,
                    onTap: _submit
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
