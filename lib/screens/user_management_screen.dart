import 'package:flutter/material.dart';
import '../api/api_service.dart';

class UserManagementScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const UserManagementScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  
  List<dynamic> _users = [];
  bool _isLoading = true;
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _fetchUsers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchUsers() async {
    setState(() => _isLoading = true);
    try {
      final response = await _apiService.getUsers();
      if (response.data['success'] == true) {
        final List residents = response.data['residents'] ?? [];
        final List others = response.data['users'] ?? [];
        
        setState(() {
          _users = [...residents, ...others];
          _isLoading = false;
        });
      } else {
        throw response.data['message'] ?? "Failed to fetch users";
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error fetching users: $e")));
      }
    }
  }

  List<dynamic> _getFilteredUsers(String role) {
    final List<dynamic> filtered = _users.where((user) {
      final String userRole = user['role'].toString().toLowerCase();
      final bool matchesRole = userRole == role.toLowerCase();
      
      final String name = (user['name'] ?? "").toString().toLowerCase();
      final String email = (user['email'] ?? "").toString().toLowerCase();
      final String username = (user['username'] ?? "").toString().toLowerCase();
      
      final bool matchesSearch = name.contains(_searchQuery.toLowerCase()) || 
                                email.contains(_searchQuery.toLowerCase()) ||
                                username.contains(_searchQuery.toLowerCase());
                                
      return matchesRole && matchesSearch;
    }).toList();

    // Sort: Pending users (is_archived == 1) always at the top
    filtered.sort((a, b) {
      final bool aPending = (a['is_archived'].toString() == '1' || a['is_archived'] == true);
      final bool bPending = (b['is_archived'].toString() == '1' || b['is_archived'] == true);
      
      if (aPending && !bPending) return -1;
      if (!aPending && bPending) return 1;
      return 0;
    });

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: (widget.isEmbedded && widget.onBack == null)
        ? null
        : AppBar(
            title: const Text("User Management", style: TextStyle(fontWeight: FontWeight.w900)),
            backgroundColor: Colors.white,
            elevation: 0,
            foregroundColor: const Color(0xFF1A1A1A),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                if (widget.onBack != null) {
                  widget.onBack!();
                } else {
                  Navigator.pop(context);
                }
              },
            ),
          ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchBar(),
            _buildTabBar(),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFA5)))
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildUserList('resident'),
                        _buildUserList('driver'),
                        _buildUserList('admin'),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFEEEEEE)),
          ),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value),
            decoration: const InputDecoration(
              hintText: "Search name, email, or username...",
              hintStyle: TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
              prefixIcon: Icon(Icons.search_rounded, color: Color(0xFFBDBDBD), size: 22),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: Colors.white,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800),
          child: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: "Residents"),
              Tab(text: "Drivers"),
              Tab(text: "Admins"),
            ],
            labelColor: const Color(0xFF00BFA5),
            unselectedLabelColor: const Color(0xFF757575),
            indicatorColor: const Color(0xFF00BFA5),
            indicatorWeight: 3,
            labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildUserList(String role) {
    final filteredUsers = _getFilteredUsers(role);

    return RefreshIndicator(
      onRefresh: _fetchUsers,
      color: const Color(0xFF00BFA5),
      child: filteredUsers.isEmpty
          ? _buildEmptyState()
          : Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView.builder(
                  itemCount: filteredUsers.length,
                  padding: const EdgeInsets.all(20),
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemBuilder: (context, index) {
                    final user = filteredUsers[index];
                    final String displayRole = user['role'].toString().toUpperCase();
                    final bool isPending = (user['is_archived'].toString() == '1' || user['is_archived'] == true);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(6),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        leading: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: _getRoleBgColor(displayRole),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.person_rounded,
                            color: _getRoleColor(displayRole),
                            size: 26,
                          ),
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                user['name'] ?? "No Name",
                                style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A), fontSize: 16),
                              ),
                            ),
                            if (isPending)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF3E0),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  "PENDING",
                                  style: TextStyle(color: Color(0xFFE65100), fontSize: 9, fontWeight: FontWeight.w900),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            "${user['email'] ?? 'No Email'}\n${user['username'] ?? ''}",
                            style: const TextStyle(fontSize: 12, color: Color(0xFF757575), height: 1.3),
                          ),
                        ),
                        trailing: const Icon(Icons.info_outline_rounded, color: Color(0xFFD1D1D1)),
                        isThreeLine: true,
                        onTap: () => _showUserDetails(user),
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_off_rounded, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isEmpty ? "No users in this category" : "No users found for '$_searchQuery'",
            style: const TextStyle(color: Color(0xFF757575), fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Color _getRoleColor(String role) {
    switch (role) {
      case 'ADMIN': return const Color(0xFFFF1744);
      case 'DRIVER': return const Color(0xFF2E7D32);
      default: return const Color(0xFF1976D2);
    }
  }

  Color _getRoleBgColor(String role) {
    switch (role) {
      case 'ADMIN': return const Color(0xFFFFF0F2);
      case 'DRIVER': return const Color(0xFFE8F5E9);
      default: return const Color(0xFFE3F2FD);
    }
  }

  void _showUserDetails(dynamic user) {
    final String role = user['role'].toString().toUpperCase();
    final bool isPending = (user['is_archived'].toString() == '1' || user['is_archived'] == true);
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scrollController) => Container(
          padding: const EdgeInsets.all(32),
          child: ListView(
            controller: scrollController,
            children: [
              // Header
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      color: _getRoleBgColor(role),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(Icons.person_rounded, color: _getRoleColor(role), size: 36),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user['name'] ?? "User Details", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: -0.5)),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: _getRoleBgColor(role),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            role,
                            style: TextStyle(color: _getRoleColor(role), fontWeight: FontWeight.w900, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 40),
              
              // Basic Information
              const Text("BASIC INFORMATION", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
              const SizedBox(height: 16),
              _buildDetailItem(Icons.alternate_email_rounded, "Username", user['username'] ?? "N/A"),
              _buildDetailItem(Icons.email_outlined, "Email Address", user['email'] ?? "N/A"),
              _buildDetailItem(Icons.phone_android_rounded, "Phone Number", user['phone'] ?? "N/A"),
              
              const SizedBox(height: 32),
              
              // Role Specific Information
              if (role == 'RESIDENT') ...[
                const Text("RESIDENT DETAILS", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
                const SizedBox(height: 16),
                _buildDetailItem(Icons.location_on_outlined, "Purok", user['purok'] ?? "N/A"),
                _buildDetailItem(Icons.home_outlined, "Complete Address", user['complete_address'] ?? "N/A"),
              ] else if (role == 'DRIVER') ...[
                const Text("DRIVER DETAILS", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
                const SizedBox(height: 16),
                _buildDetailItem(Icons.badge_outlined, "License Number", user['license_number'] ?? "N/A"),
                _buildDetailItem(Icons.local_shipping_outlined, "Preferred Truck", user['preferred_truck'] ?? "N/A"),
              ],
              
              const SizedBox(height: 32),
              const Text("ACCOUNT STATUS", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFBDBDBD), letterSpacing: 1.2)),
              const SizedBox(height: 16),
              _buildDetailItem(Icons.calendar_today_rounded, "Member Since", (user['created_at'] ?? "N/A").toString().split(' ')[0]),
              _buildDetailItem(
                Icons.verified_user_outlined,
                "Approval Status",
                isPending ? "Pending Approval" : "Approved & Active",
              ),
              
              const SizedBox(height: 40),
              if (isPending) ...[
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _showRejectConfirmation(user['user_id'], user['role'], user['name']),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFEBEE),
                          foregroundColor: const Color(0xFFD32F2F),
                          minimumSize: const Size(0, 60),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          elevation: 0,
                        ),
                        child: const Text("REJECT", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: () => _approveUser(user['user_id'], user['role']),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFA000),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 60),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          elevation: 0,
                        ),
                        child: const Text("APPROVE", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00BFA5),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 60),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  elevation: 0,
                ),
                child: const Text("CLOSE", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _approveUser(dynamic id, dynamic role) async {
    try {
      final response = await _apiService.approveUser(int.parse(id.toString()), role.toString());
      if (response.data['success'] == true) {
        if (mounted) {
          Navigator.pop(context); // Close sheet
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Account approved successfully!")),
          );
          _fetchUsers(); // Refresh list
        }
      } else {
        throw response.data['message'] ?? "Failed to approve user";
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
  }

  void _showRejectConfirmation(dynamic id, dynamic role, String? name) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text("Reject Registration?", style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text("Are you sure you want to reject and delete the registration for ${name ?? 'this user'}? This action cannot be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCEL", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              _rejectUser(id, role);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text("REJECT & DELETE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _rejectUser(dynamic id, dynamic role) async {
    try {
      final response = await _apiService.rejectUser(int.parse(id.toString()), role.toString());
      if (response.data['success'] == true) {
        if (mounted) {
          Navigator.pop(context); // Close sheet
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Registration rejected and deleted.")),
          );
          _fetchUsers(); // Refresh list
        }
      } else {
        throw response.data['message'] ?? "Failed to reject user";
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
  }

  Widget _buildDetailItem(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF00BFA5), size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF9E9E9E))),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
