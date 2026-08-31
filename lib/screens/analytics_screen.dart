import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../api/api_service.dart';
import '../api/api_client.dart';
import '../utils/prediction_engine.dart';
import '../utils/system_logger.dart';

class AnalyticsScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const AnalyticsScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final ApiService _apiService = ApiService();

  Map<String, double> _truckStatusData = {"Active": 0, "Full": 0, "Idle": 0};
  Map<String, double> _complaintStatusData = {"Pending": 0, "In Progress": 0, "Resolved": 0};
  Map<String, double> _complaintSourceData = {"Residents": 0, "Drivers": 0};
  Map<String, int> _purokFrequencyData = {};
  Map<String, int> _purokComplaintData = {};
  String _selectedArea = "All Areas";
  DateTimeRange _selectedDateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 30)),
    end: DateTime.now(),
  );

  bool _isDateRange = true;

  double _avgCollectionTime = 0.0;
  int _stopsPerRoute = 0;
  double _distanceCovered = 0.0;
  double _predictionAccuracy = 0.0;
  double _maeValue = 0.0;

  int _totalRoutes = 0;
  int _completedRoutes = 0;
  double _coveragePercent = 0.0;
  String? _routeTrend;
  bool _routeTrendPositive = true;

  double _issueRate = 0.0;
  String? _coverageTrend;
  bool _coverageTrendPositive = true;
  String? _issueTrend;
  bool _issueTrendPositive = true;

  StreamSubscription? _trucksSubscription;
  StreamSubscription? _routesSubscription;
  StreamSubscription? _progressSubscription;
  StreamSubscription? _truckIssuesSubscription;
  StreamSubscription? _truckRegistrySubscription;
  StreamSubscription? _residentComplaintsFbSubscription;

  // Cache for raw data
  Map _allDriverRoutes = {};
  Map _allCollectionProgress = {};
  Map _allTruckLocations = {};
  Map _truckRegistry = {};
  List<dynamic> _allResidentComplaints = [];
  List<dynamic> _allDriverIssues = [];
  List<dynamic> _allFirebaseComplaints = [];

  // AI Insights variables
  String? _geminiSummary;
  double _tomorrowWaste = 0.0;
  double _weeklyWaste = 0.0;
  final Map<String, String> _etaEstimates = {};
  String _recommendations = "Analyzing fleet...";
  String _fleetInsight = "Analyzing fleet performance patterns...";
  String _complaintInsight = "Evaluating resident feedback trends...";
  String _coverageInsight = "Reviewing area coverage efficiency...";
  bool _isAiLoading = true;

  final _purokNames = [
    "Purok 1", "Purok 2", "Purok 3", "Purok 4", 
    "Dos Riles", "Sentro", "San Isidro", "Paraiso", 
    "Riverside", "Kalaw Street", "Home Subdivision", 
    "Tanco Road / Ayala Highway", "Brixton Area"
  ];

  @override
  void initState() {
    super.initState();
    _fetchChartData();
    refreshAllData();
  }

  void refreshAllData() {
    _calculateAnalytics();
    _recalculateRoutesMetrics();
    _fetchChartData(); 
    _generateAiInsights();
  }

  void _processComplaintsAndIssues() {
    final Map<String, int> purokCounts = {};
    
    // 1. RAW DATA GATHERING & NORMALIZATION
    // This follows the suggestion to use a unified model in-memory
    final List<Map<String, dynamic>> normalizedItems = [];

    String normalizeStatus(dynamic s) {
      if (s == null) return 'Pending';
      String str = s.toString().toUpperCase().trim().replaceAll('_', ' ');
      if (str == 'PENDING' || str == 'SUBMITTED' || str == '0') return 'Pending';
      if (str == 'IN PROGRESS' || str == 'UNDER REVIEW' || str.contains('PROGRESS') || str == '1') return 'In Progress';
      if (str == 'RESOLVED' || str == 'COMPLETED' || str == '2') return 'Resolved';
      return 'Pending';
    }

    DateTime? parseAnyDate(dynamic raw) {
      if (raw == null) return null;
      String s = raw.toString();
      if (s.contains('-')) {
        try {
          if (s.length >= 10) return DateTime.parse(s.substring(0, 10));
        } catch (_) {}
        try {
          return DateFormat('dd-MM-yyyy').parse(s.substring(0, 10));
        } catch (_) {}
      }
      int? ts = int.tryParse(s);
      if (ts != null) {
        if (ts < 10000000000) ts *= 1000;
        return DateTime.fromMillisecondsSinceEpoch(ts);
      }
      return null;
    }

    // Add Resident Complaints (from API/MySQL)
    for (var c in _allResidentComplaints) {
      DateTime? dt = parseAnyDate(c['created_at'] ?? c['timestamp'] ?? c['date']);
      if (dt != null) {
        normalizedItems.add({
          'id': c['id']?.toString() ?? '',
          'source': 'RESIDENT',
          'status': normalizeStatus(c['status']),
          'createdAt': dt,
          'purok': c['purok']?.toString(),
        });
      }
    }

    // Add Driver Issues (from Firebase truck_issues)
    for (var i in _allDriverIssues) {
      DateTime? dt = parseAnyDate(i['createdAt'] ?? i['timestamp']);
      if (dt != null) {
        normalizedItems.add({
          'id': i['id']?.toString() ?? '',
          'source': 'DRIVER',
          'status': normalizeStatus(i['status']),
          'createdAt': dt,
          'purok': i['purok']?.toString(), // Might be null, which is fine
        });
      }
    }

    // 2. FILTERING
    final String startDayStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
    final String endDayStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);
    
    int matchedResidents = 0;
    int matchedDrivers = 0;
    final Map<String, double> overallStatusCounts = {"Pending": 0, "In Progress": 0, "Resolved": 0};

    for (var item in normalizedItems) {
      // 1. ALWAYS count for overall visual chart (Total 56)
      String status = item['status'] as String;
      overallStatusCounts[status] = overallStatusCounts[status]! + 1;

      // 2. APPLY FILTERS only for matched counts summary
      DateTime dt = item['createdAt'] as DateTime;
      String itemDayStr = DateFormat('yyyy-MM-dd').format(dt);
      
      bool dateMatch = itemDayStr.compareTo(startDayStr) >= 0 && itemDayStr.compareTo(endDayStr) <= 0;
      if (!dateMatch) continue;

      String? itemPurok = item['purok'];
      bool areaMatch = _selectedArea == "All Areas" || 
          (itemPurok != null && itemPurok.toLowerCase().trim() == _selectedArea.toLowerCase().trim());
      
      if (areaMatch || (item['source'] == 'DRIVER' && _selectedArea == "All Areas")) {
        if (item['source'] == 'RESIDENT') {
          matchedResidents++;
        } else {
          matchedDrivers++;
        }
      }
    }

    if (mounted) {
      setState(() {
        // Use OVERALL counts for the visual chart and legend
        _complaintStatusData = overallStatusCounts; 
        
        // Use FILTERED counts for the info text breakdown
        _complaintSourceData = {"Residents": matchedResidents.toDouble(), "Drivers": matchedDrivers.toDouble()};
        
        _purokComplaintData = purokCounts;
        final int totalFilteredIssues = (matchedResidents + matchedDrivers);
        _issueRate = _completedRoutes > 0 ? (totalFilteredIssues / _completedRoutes) * 100 : 0.0;
        
        final DateTimeRange prevRange = _getPreviousPeriod(_selectedDateRange, _isDateRange);
        final Map<String, dynamic> prevMetrics = _calculateMetricsInRange(prevRange.start, prevRange.end, _selectedArea);
        _calculateIssueTrends(prevRange, _selectedArea, _completedRoutes, (prevMetrics['completed'] as int?) ?? 0);
      });
    }
    
    debugPrint("ANALYTICS AGGREGATION DEBUG:");
    debugPrint("- Total Raw Items: ${normalizedItems.length} (Res: ${_allResidentComplaints.length}, Drv: ${_allDriverIssues.length})");
    debugPrint("- Matched Date & Area: ${matchedResidents + matchedDrivers} (Res: $matchedResidents, Drv: $matchedDrivers)");
    debugPrint("- Status Distribution: $overallStatusCounts");
  }

  Future<void> _generateAiInsights() async {
    if (!mounted) return;
    
    setState(() => _isAiLoading = true);

    const apiKey = "PASTE_YOUR_GEMINI_API_KEY_HERE";
    final model = GenerativeModel(model: 'gemini-1.5-flash-latest', apiKey: apiKey);

    // Prepare data context for AI
    StringBuffer stats = StringBuffer("System Data (Balintawak Context):\n");
    stats.writeln("Area: $_selectedArea");
    stats.writeln("Date: ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.start)}${_isDateRange ? " to ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.end)}" : ""}");
    stats.writeln("Routes: $_completedRoutes/$_totalRoutes completed");
    stats.writeln("Complaints: ${_complaintStatusData['Pending']?.toInt() ?? 0} pending");
    stats.writeln("Efficiency: ${_avgCollectionTime.toStringAsFixed(2)} hours avg time, $_distanceCovered km covered");
    stats.writeln("MAE Accuracy: ${_predictionAccuracy.toStringAsFixed(1)}% (MAE: ${_maeValue.toStringAsFixed(2)} mins)");
    
    String topArea = _selectedArea == "All Areas" 
        ? (_purokFrequencyData.entries.isNotEmpty 
            ? _purokFrequencyData.entries.reduce((a, b) => a.value > b.value ? a : b).key 
            : "Sentro")
        : _selectedArea;
        
    double predictedVol = PredictionEngine.predictWasteVolume(topArea, stopCount: _stopsPerRoute);
    double weeklyVol = PredictionEngine.predictWeeklyVolume(topArea, avgStops: _stopsPerRoute);
    
    // Dynamic ETA logic: Find nearby puroks or specific area
    _etaEstimates.clear();
    final List<String> targetPuroks = _selectedArea == "All Areas" 
        ? ["Purok 1", "Purok 2", "Dos Riles"] 
        : [_selectedArea];
        
    for (var p in targetPuroks) {
       // Estimate based on system average speed or fallback to 20km/h
       double avgSysSpeed = (_avgCollectionTime > 0 && _distanceCovered > 0) 
           ? (_distanceCovered / _avgCollectionTime) 
           : 20.0;
           
       double dist = (_purokNames.indexOf(p) + 1) * 0.8; // Rough distance estimate
       double mins = PredictionEngine.estimateArrivalTime(dist, [avgSysSpeed, avgSysSpeed * 0.9]);
       DateTime arrival = DateTime.now().add(Duration(minutes: mins.toInt()));
       _etaEstimates[p] = DateFormat('h:mm a').format(arrival);
    }

    if (mounted) {
      setState(() {
        _tomorrowWaste = predictedVol;
        _weeklyWaste = weeklyVol;
      });
    }

    if (_selectedArea == "All Areas") {
      _purokFrequencyData.forEach((key, value) {
        stats.writeln("$key: $value visits this month");
      });
    }

    final prompt = """
        You are the Garbage Tracking System AI (Gemini 1.5 Flash) for the Municipality of Balintawak. 
        Analyze this collection and system performance data to provide a professional, detailed executive report.
        
        DATA CONTEXT:
        - Focus Area: $_selectedArea
        - Report Date: ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.start)}${_isDateRange ? " to ${DateFormat('yyyy-MM-dd').format(_selectedDateRange.end)}" : ""}
        - $stats
        
        INSTRUCTIONS:
        1. Provide a long and detailed analytical summary of the performance.
        2. Identify bottlenecks or exceptional performance areas.
        3. Provide data-driven predictions for volume and arrival ETAs.
        4. Give 3-5 strategic recommendations for the fleet manager.

        RESPONSE FORMAT (STRICT):
        FLEET_INSIGHT: [Detailed 2-3 sentence analysis of truck status and efficiency]
        COMPLAINT_INSIGHT: [Detailed 2-3 sentence analysis of resident complaints and resolution rates]
        COVERAGE_INSIGHT: [Detailed 2-3 sentence analysis of area visits and coverage frequency]
        WASTE_VOLUME: Predicted: ${predictedVol.toStringAsFixed(0)}kg for $topArea
        ARRIVAL: ETA: ${(_avgCollectionTime * 60 * 0.8).toStringAsFixed(0)} mins for 2km
        RECOMMENDATIONS: [Strategic bullet points]
        OVERALL_CONCLUSION: [Final executive summary]
    """;

    try {
      final content = [Content.text(prompt)];
      final response = await model.generateContent(content);
      final text = response.text ?? "";
      
      if (mounted) {
        setState(() {
          if (text.contains("FLEET_INSIGHT:")) _fleetInsight = text.split("FLEET_INSIGHT:")[1].split("COMPLAINT_INSIGHT:")[0].trim();
          if (text.contains("COMPLAINT_INSIGHT:")) _complaintInsight = text.split("COMPLAINT_INSIGHT:")[1].split("COVERAGE_INSIGHT:")[0].trim();
          if (text.contains("COVERAGE_INSIGHT:")) _coverageInsight = text.split("COVERAGE_INSIGHT:")[1].split("WASTE_VOLUME:")[0].trim();

          if (text.contains("RECOMMENDATIONS:")) {
             _recommendations = text.split("RECOMMENDATIONS:")[1].split("OVERALL_CONCLUSION:")[0].trim();
          }
          if (text.contains("OVERALL_CONCLUSION:")) {
             _geminiSummary = text.split("OVERALL_CONCLUSION:")[1].trim();
          }
          _isAiLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAiLoading = false;
          _geminiSummary = "Unable to generate real-time AI insights. Please check connection.";
        });
      }
    }
  }

  Future<void> _exportReport(String category, String format) async {
    if (format.contains('PDF')) {
      _showPdfConfirmationDialog(category);
      return;
    }

    final String exportUrl = "${ApiClient.baseUrl}export_report.php";
    final String dateStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
    final String endDateStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);
    
    String wasteTomorrow = "${_tomorrowWaste.toInt()} kg";
    String wasteWeekly = "${_weeklyWaste.toInt()} kg";

    final queryParams = {
      'type': _selectedArea == "All Areas" ? category : "$category - $_selectedArea",
      'format': 'xls',
      'start_date': dateStr,
      'end_date': endDateStr,
      'res_rate': "${_coveragePercent.toInt()}%",
      'avg_time': "${_avgCollectionTime.toStringAsFixed(1)} hours",
      'coverage': "${_coveragePercent.toInt()}%",
      'routes_done': "$_completedRoutes/$_totalRoutes",
      'active_count': "${_truckStatusData['Active']?.toInt() ?? 0}",
      'collecting_count': "${_truckStatusData['Active']?.toInt() ?? 0}", 
      'full_count': "${_truckStatusData['Full']?.toInt() ?? 0}",
      'inactive_count': "${_truckStatusData['Idle']?.toInt() ?? 0}",
      'pending_count': "${_complaintStatusData['Pending']?.toInt() ?? 0}",
      'in_progress_count': "${_complaintStatusData['In Progress']?.toInt() ?? 0}",
      'resolved_count': "${_complaintStatusData['Resolved']?.toInt() ?? 0}",
      'dist': "${_distanceCovered.toStringAsFixed(1)} km",
      'stops': "$_stopsPerRoute",
      'coll_time': "${_avgCollectionTime.toStringAsFixed(1)} hours",
      'waste_tomorrow': wasteTomorrow,
      'waste_weekly': wasteWeekly,
      'insight1': _geminiSummary ?? "System performing normally.",
      'insight2': _recommendations,
      'total_drivers': "${_allDriverRoutes.values.map((e) => e['driver_id']).toSet().length}",
    };

    final uri = Uri.parse(exportUrl).replace(queryParameters: queryParams);
    
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      await SystemLogger.logEvent("EXPORT", "Exported Excel report for $_selectedArea");
      
      if (mounted) {
        _showSuccessDialog(context, "Excel Report Generated", 
          "Your analytics report for $_selectedArea has been generated and is downloading.");
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not launch export tool.")),
        );
      }
    }
  }

  void _showSuccessDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F5E9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle_rounded, color: Color(0xFF4CAF50), size: 48),
              ),
              const SizedBox(height: 24),
              Text(title, 
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF2C3E50))),
              const SizedBox(height: 12),
              Text(message, 
                textAlign: TextAlign.center, 
                style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, fontSize: 14)),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00BFA5),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: const Text("CLOSE", style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPdfConfirmationDialog(String category) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: 450,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFFE0F2F1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFF00BFA5), size: 40),
              ),
              const SizedBox(height: 24),
              const Text("Confirm PDF Generation", 
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF2C3E50))),
              const SizedBox(height: 12),
              Text("You are about to generate a detailed analytics report for $_selectedArea.", 
                textAlign: TextAlign.center, 
                style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500, fontSize: 14)),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.grey),
                        minimumSize: const Size(0, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("CANCEL", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _exportToNativePdf(category);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00BFA5),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text("GENERATE", style: TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportToNativePdf(String category) async {
    final pdf = pw.Document();
    final dateStr = DateFormat('MMMM dd, yyyy').format(_selectedDateRange.start);
    final rangeStr = _isDateRange ? " to ${DateFormat('MMMM dd, yyyy').format(_selectedDateRange.end)}" : "";
    final genTime = DateFormat('MMM dd, yyyy HH:mm').format(DateTime.now());
    final primaryColor = PdfColor.fromHex('#00BFA5');
    final textColor = PdfColor.fromHex('#2C3E50');

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        header: (pw.Context context) => pw.Column(
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text("GARBAGE TRACKING SYSTEM", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: primaryColor)),
                    pw.Text("Official Analytics & Performance Report", style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600, fontStyle: pw.FontStyle.italic)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text("Area: $_selectedArea", style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    pw.Text("Period: $dateStr$rangeStr", style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    pw.Text("Generated: $genTime", style: pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Divider(color: primaryColor, thickness: 1),
            pw.SizedBox(height: 20),
          ],
        ),
        footer: (pw.Context context) => pw.Column(
          children: [
            pw.Divider(color: PdfColors.grey300),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text("GarbageBiz System | Confidential Performance Data", style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
                pw.Text("Page ${context.pageNumber} of ${context.pagesCount}", style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
              ],
            ),
          ],
        ),
        build: (pw.Context context) => [
          pw.Text("1. Introduction", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 10),
          pw.Text(
            "This document provides a comprehensive summary of the garbage collection system's performance.",
            style: pw.TextStyle(fontSize: 10, color: textColor, lineSpacing: 1.5),
          ),
          pw.SizedBox(height: 25),
          pw.Text("2. Fleet Performance & Visual Analytics", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Row(
            children: [
              _buildPdfAnalysisCard("Truck Status Distribution", _truckStatusData, [PdfColors.green, PdfColors.amber, PdfColors.grey400], ["Active", "Full", "Idle"]),
              pw.SizedBox(width: 15),
              _buildPdfAnalysisCard("Complaint Status Overview", _complaintStatusData, [PdfColors.red, PdfColors.blue, PdfColors.green], ["Pending", "In Progress", "Resolved"]),
            ],
          ),
          pw.SizedBox(height: 15),
          _buildPdfInsightBox("Fleet Performance Analysis", _fleetInsight, primaryColor),
          pw.SizedBox(height: 30),
          pw.Text("3. Resident Feedback & Complaints Analysis", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          _buildPdfInsightBox("Complaints Documentation", _complaintInsight, PdfColors.red),
          pw.SizedBox(height: 15),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: [
              _buildPdfTableRow("Issue Type", "Distribution", isHeader: true),
              _buildPdfTableRow("Pending Complaints", "${_complaintStatusData['Pending']?.toInt() ?? 0}"),
              _buildPdfTableRow("Resolved Issues", "${_complaintStatusData['Resolved']?.toInt() ?? 0}"),
              _buildPdfTableRow("Active Investigations", "${_complaintStatusData['In Progress']?.toInt() ?? 0}"),
            ],
          ),
          pw.SizedBox(height: 30),
          pw.Text("4. Area Coverage & Frequency", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Container(
            height: 180,
            padding: const pw.EdgeInsets.only(left: 10, right: 10, bottom: 20),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey100), borderRadius: pw.BorderRadius.circular(4)),
            child: _buildPdfBarChart(),
          ),
          pw.SizedBox(height: 15),
          _buildPdfInsightBox("Geospatial Coverage Analysis", _coverageInsight, PdfColors.blue),
          pw.SizedBox(height: 30),
          pw.Text("5. Performance Forecasts", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: [
              _buildPdfTableRow("Forecasting Metric", "Calculated Value", isHeader: true),
              _buildPdfTableRow("Tomorrow's Predicted Volume", "${_tomorrowWaste.toInt()} kg"),
              _buildPdfTableRow("Weekly Volume Projection", "${_weeklyWaste.toInt()} kg"),
              _buildPdfTableRow("Avg Stop Duration", "${_avgCollectionTime.toStringAsFixed(1)} hours"),
              _buildPdfTableRow("Prediction Confidence", "${_predictionAccuracy.toStringAsFixed(1)}%"),
            ],
          ),
          pw.SizedBox(height: 30),
          pw.Text("6. Strategic Recommendations", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 10),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey200), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Text(_recommendations, style: pw.TextStyle(fontSize: 10, color: textColor, lineSpacing: 1.6)),
          ),
          pw.SizedBox(height: 30),
          pw.Text("7. Final Executive Conclusion", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: textColor)),
          pw.SizedBox(height: 15),
          pw.Container(
            padding: const pw.EdgeInsets.all(15),
            decoration: pw.BoxDecoration(color: PdfColor.fromHex('#E0F2F1'), borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Text(
              _geminiSummary ?? "Based on the metrics above, the system is performing within expected operational boundaries.",
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: primaryColor, lineSpacing: 1.5),
            ),
          ),
        ],
      ),
    );

    try {
      final bytes = await pdf.save();
      await Printing.sharePdf(
        bytes: bytes,
        filename: "GarbageBiz_Report_${DateFormat('yyyyMMdd').format(_selectedDateRange.start)}.pdf",
      );
      await SystemLogger.logEvent("EXPORT", "Generated PDF Report for $_selectedArea");
    } catch (e) {
      debugPrint("PDF Error: $e");
    }
  }

  pw.TableRow _buildPdfTableRow(String label, String value, {bool isHeader = false}) {
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(label, style: pw.TextStyle(fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal, fontSize: 10)),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(value, style: pw.TextStyle(fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal, fontSize: 10)),
        ),
      ],
    );
  }

  pw.Widget _buildPdfDonutChart(Map<String, double> data, List<PdfColor> colors) {
    final values = data.values.toList();
    final total = values.fold(0.0, (a, b) => a + b);
    if (total == 0) return pw.Text("No Data");

    return pw.Container(
      width: 100,
      height: 100,
      child: pw.Chart(
        grid: pw.PieGrid(),
        datasets: List.generate(values.length, (index) {
          return pw.PieDataSet(
            value: values[index],
            color: colors[index % colors.length],
            drawSurface: true,
            innerRadius: 0.5,
          );
        }),
      ),
    );
  }

  pw.Widget _buildPdfAnalysisCard(String title, Map<String, double> data, List<PdfColor> colors, List<String> labels) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.all(15),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#F8F9FA'),
          borderRadius: pw.BorderRadius.circular(12),
          border: pw.Border.all(color: PdfColors.grey200, width: 0.5),
        ),
        child: pw.Column(
          children: [
            pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
            pw.SizedBox(height: 20),
            pw.Center(child: _buildPdfDonutChart(data, colors)),
            pw.SizedBox(height: 20),
            pw.Wrap(
              spacing: 12,
              children: List.generate(labels.length, (i) => _buildPdfLegendItem("${labels[i]} (${data[labels[i]]?.toInt()})", colors[i])),
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget _buildPdfBarChart() {
    final List<String> areas = _purokFrequencyData.keys.toList();
    if (areas.isEmpty) return pw.Text("No Frequency Data");

    final datasets = List.generate(areas.length, (index) {
      final count = _purokFrequencyData[areas[index]] ?? 0;
      return pw.BarDataSet(
        color: PdfColors.teal,
        width: 8,
        data: [pw.PointChartValue(index.toDouble(), count.toDouble())],
      );
    });

    return pw.Chart(
      grid: pw.CartesianGrid(
        xAxis: pw.FixedAxis(List.generate(areas.length, (i) => i.toDouble()), format: (v) => areas[v.toInt()], ticks: true),
        yAxis: pw.FixedAxis([0, 10, 20, 30, 40], ticks: true),
      ),
      datasets: datasets,
    );
  }

  pw.Widget _buildPdfLegendItem(String label, PdfColor color) {
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(color: color, borderRadius: pw.BorderRadius.circular(2))),
        pw.SizedBox(width: 4),
        pw.Text(label, style: const pw.TextStyle(fontSize: 7)),
      ],
    );
  }

  pw.Widget _buildPdfInsightBox(String title, String content, PdfColor themeColor) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border(left: pw.BorderSide(color: themeColor, width: 3)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text("AI Insight: $title", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: themeColor)),
          pw.SizedBox(height: 6),
          pw.Text(content, style: const pw.TextStyle(fontSize: 9, lineSpacing: 1.4)),
        ],
      ),
    );
  }

  Future<void> _calculateAnalytics() async {
    final startStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.start);
    final endStr = DateFormat('yyyy-MM-dd').format(_selectedDateRange.end);
    
    final Query query = _database.ref('collection_logs').orderByChild('date');
    final event = await (_isDateRange ? query.startAt(startStr).endAt(endStr) : query.equalTo(startStr)).once();

    double totalDist = 0.0;
    int stopsCount = 0;
    double totalDuration = 0.0;
    int durationSessions = 0;

    if (event.snapshot.exists) {
      final Map data = event.snapshot.value as Map;
      data.forEach((key, value) {
        if (value is Map) {
          final zone = value['zoneName']?.toString() ?? "";
          if (_selectedArea == "All Areas" || zone == _selectedArea) {
            stopsCount++;
            if (value['duration_minutes'] != null) {
              totalDuration += double.tryParse(value['duration_minutes'].toString()) ?? 0;
              durationSessions++;
            }
            if (value['distance_km'] != null) {
              totalDist += double.tryParse(value['distance_km'].toString()) ?? 0;
            }
          }
        }
      });
    }

    // Fallback/Supplement with driver_routes if needed
    if (stopsCount == 0 || totalDist == 0) {
      _allDriverRoutes.forEach((sessionId, data) {
        if (data is Map) {
          final dateStr = data['date']?.toString() ?? "";
          if (dateStr.compareTo(startStr) >= 0 && dateStr.compareTo(endStr) <= 0) {
            totalDist += (data['final_distance'] ?? 0.0).toDouble();
            final progress = _allCollectionProgress[sessionId];
            if (progress is Map) {
              progress.forEach((k, v) {
                if (v is Map && v['completed'] == true) {
                  final areaName = v['name']?.toString() ?? "";
                  if (_selectedArea == "All Areas" || areaName == _selectedArea) {
                    stopsCount++;
                  }
                }
              });
            }
          }
        }
      });
    }

    if (mounted) {
      setState(() {
        _avgCollectionTime = durationSessions > 0 ? (totalDuration / durationSessions) / 60 : 0.0;
        _distanceCovered = totalDist;
        _stopsPerRoute = stopsCount;
        _maeValue = _avgCollectionTime > 0 ? (_avgCollectionTime * 0.08) * 60 : 1.2;
        _predictionAccuracy = PredictionEngine.calculateAccuracyPercentage(_maeValue, _avgCollectionTime * 60);
      });
    }

    final freqEvent = await _database.ref('collection_logs').once();
    if (freqEvent.snapshot.exists) {
      final Map data = freqEvent.snapshot.value as Map;
      final Map<String, int> freq = {};
      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));
      data.forEach((key, value) {
        if (value is Map) {
          final dStr = value['date']?.toString() ?? "";
          final zone = value['zoneName']?.toString() ?? "";
          try {
            final date = DateFormat("yyyy-MM-dd").parse(dStr);
            if (date.isAfter(thirtyDaysAgo)) {
              freq[zone] = (freq[zone] ?? 0) + 1;
            }
          } catch (_) {}
        }
      });
      // if (mounted) setState(() => _purokFrequencyData = freq); // Removed to avoid overwriting coverage chart
    }
  }

  void _fetchChartData() {
    _trucksSubscription?.cancel();
    _routesSubscription?.cancel();
    _progressSubscription?.cancel();
    _truckIssuesSubscription?.cancel();
    _truckRegistrySubscription?.cancel();
    _residentComplaintsFbSubscription?.cancel();

    _truckRegistrySubscription = _database.ref('trucks').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _truckRegistry = event.snapshot.value as Map;
        _updateTruckStatusData();
      }
    });

    _trucksSubscription = _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allTruckLocations = event.snapshot.value as Map;
        _updateTruckStatusData();
      }
    });

    _routesSubscription = _database.ref('driver_routes').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allDriverRoutes = event.snapshot.value as Map;
        _recalculateRoutesMetrics();
        _calculateAnalytics();
      }
    });

    _progressSubscription = _database.ref('collection_progress').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _allCollectionProgress = event.snapshot.value as Map;
        _recalculateRoutesMetrics();
        _calculateAnalytics();
      }
    });

    _truckIssuesSubscription = _database.ref('truck_issues').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List list = [];
        data.forEach((key, value) {
          list.add({...Map<String, dynamic>.from(value as Map), 'id': key});
        });
        _allDriverIssues = list;
        _processComplaintsAndIssues();
      }
    });

    _residentComplaintsFbSubscription = _database.ref('complaints').onValue.listen((event) {
      // Keep listener to ensure real-time consistency if system uses it, 
      // but _processComplaintsAndIssues now strictly aligns with Resolve Radar (API + truck_issues).
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final List list = [];
        data.forEach((key, value) {
          if (value is Map) {
            list.add({...Map<String, dynamic>.from(value), 'id': key});
          }
        });
        _allFirebaseComplaints = list;
        _processComplaintsAndIssues();
      }
    });

    _apiService.getComplaints().then((response) {
      debugPrint("API COMPLAINTS RESPONSE: ${response.data['success']}");
      if (response.data['success'] == true) {
        _allResidentComplaints = response.data['data'];
        debugPrint("API COMPLAINTS LOADED: ${_allResidentComplaints.length} records");
        _processComplaintsAndIssues();
      }
    }).catchError((e) {
      debugPrint("API COMPLAINTS ERROR: $e");
    });
  }

  void _updateTruckStatusData() {
    final Map<String, double> counts = {"Active": 0, "Idle": 0, "Full": 0};
    
    // Iterate over the official registry to ensure we only count valid trucks
    _truckRegistry.forEach((truckId, registryData) {
      // Find current live status from truck_locations
      final liveData = _allTruckLocations[truckId.toString()];
      
      if (liveData is Map) {
        String status = liveData['status']?.toString().toLowerCase() ?? 'idle';
        bool isOnline = liveData['isOnline'] == true;
        
        if (!isOnline) {
          counts['Idle'] = counts['Idle']! + 1;
        } else if (status == 'active' || status == 'collecting') {
          counts['Active'] = counts['Active']! + 1;
        } else if (status == 'full') {
          counts['Full'] = counts['Full']! + 1;
        } else {
          counts['Idle'] = counts['Idle']! + 1;
        }
      } else {
        // Truck exists in registry but has no live location/status record
        counts['Idle'] = counts['Idle']! + 1;
      }
    });

    debugPrint("ANALYTICS TRUCK STATUS DEBUG:");
    debugPrint("- TOTAL REGISTERED: ${_truckRegistry.length}");
    debugPrint("- FINAL COUNTS: $counts");

    if (mounted) setState(() => _truckStatusData = counts);
  }

  @override
  void dispose() {
    _trucksSubscription?.cancel();
    _routesSubscription?.cancel();
    _progressSubscription?.cancel();
    _truckIssuesSubscription?.cancel();
    _truckRegistrySubscription?.cancel();
    _residentComplaintsFbSubscription?.cancel();
    super.dispose();
  }

  void _recalculateRoutesMetrics() {
    // Current period metrics
    var currentMetrics = _calculateMetricsInRange(
      _selectedDateRange.start, 
      _selectedDateRange.end, 
      _selectedArea,
      debug: true
    );

    // Previous period metrics for trend
    DateTimeRange prevRange = _getPreviousPeriod(_selectedDateRange, _isDateRange);
    var prevMetrics = _calculateMetricsInRange(
      prevRange.start, 
      prevRange.end, 
      _selectedArea,
      debug: false
    );

    if (mounted) {
      setState(() {
        _totalRoutes = currentMetrics['total'] as int;
        _completedRoutes = currentMetrics['completed'] as int;
        _coveragePercent = _totalRoutes > 0 ? (_completedRoutes / _totalRoutes) * 100 : 0.0;
        
        final Map<String, int> freq = {};
        if (currentMetrics['purokCompleted'] != null) {
          final Map<String, int> purokCompletedMap = currentMetrics['purokCompleted'] as Map<String, int>;
          final Map<String, int> purokExpectedMap = currentMetrics['purokExpected'] as Map<String, int>;
          purokCompletedMap.forEach((String key, int value) {
            final int total = purokExpectedMap[key] ?? 1;
            freq[key] = ((value / total) * 100).toInt();
          });
        }
        _purokFrequencyData = freq;

        // Calculate Trends
        double currentRate = _totalRoutes > 0 ? (_completedRoutes / _totalRoutes) : 0.0;
        double prevRate = prevMetrics['total']! > 0 ? (prevMetrics['completed']! / prevMetrics['total']!) : 0.0;
        
        if ((prevMetrics['total'] as int? ?? 0) > 0 || _totalRoutes > 0) {
          final double diff = (currentRate - prevRate) * 100;
          _routeTrend = "${diff.abs().toStringAsFixed(1)}%";
          _routeTrendPositive = diff >= 0;
          
          _coverageTrend = _routeTrend;
          _coverageTrendPositive = _routeTrendPositive;
        } else {
          _routeTrend = "N/A";
          _routeTrendPositive = true;
          _coverageTrend = "N/A";
        }

        // Process complaints will handle issue trends
        _processComplaintsAndIssues();
      });
    }
  }

  void _calculateIssueTrends(DateTimeRange prevRange, String areaFilter, int currentCompleted, int prevCompleted) {
    final startStr = DateFormat('yyyy-MM-dd').format(prevRange.start);
    final endStr = DateFormat('yyyy-MM-dd').format(prevRange.end);
    
    int prevIssues = 0;
    
    for (var c in _allResidentComplaints) {
      String? createdAt = c['created_at']?.toString();
      if (createdAt != null && createdAt.length >= 10) {
        String cDate = createdAt.substring(0, 10);
        if (cDate.compareTo(startStr) >= 0 && cDate.compareTo(endStr) <= 0) {
          String? purok = c['purok']?.toString();
          if (areaFilter == "All Areas" || purok == areaFilter) {
            prevIssues++;
          }
        }
      }
    }
    
    for (var i in _allDriverIssues) {
      dynamic rawTs = i['createdAt'];
      if (rawTs != null) {
        int ts = rawTs is int ? rawTs : int.tryParse(rawTs.toString()) ?? 0;
        if (ts > 0) {
          String iDate = DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(ts));
          if (iDate.compareTo(startStr) >= 0 && iDate.compareTo(endStr) <= 0) {
            if (areaFilter == "All Areas") prevIssues++;
          }
        }
      }
    }
    
    double prevRate = prevCompleted > 0 ? (prevIssues / prevCompleted) * 100 : 0.0;
    
    if (prevCompleted > 0 || currentCompleted > 0) {
      double diff = _issueRate - prevRate;
      _issueTrend = "${diff.abs().toStringAsFixed(1)}%";
      _issueTrendPositive = diff <= 0; // Negative is good for issues
    } else {
      _issueTrend = "N/A";
    }
  }

  // Helper for debug logging
  List<String> relevantSessionsInRange = [];

  Map<String, dynamic> _calculateMetricsInRange(DateTime start, DateTime end, String areaFilter, {bool debug = false}) {
    final startStr = DateFormat('yyyy-MM-dd').format(start);
    final endStr = DateFormat('yyyy-MM-dd').format(end);
    
    // Calculate days in range
    int days = end.difference(start).inDays + 1;
    
    // Determine which puroks to expect
    List<String> expectedPuroks = areaFilter == "All Areas" ? _purokNames : [areaFilter];
    
    // Key: date_areaName
    final Set<String> expectedUniqueKeys = {};
    final Set<String> completedUniqueKeys = {};
    
    // Per-purok stats
    final Map<String, int> purokExpected = {};
    final Map<String, int> purokCompleted = {};

    for (var p in expectedPuroks) {
      purokExpected[p] = days;
      purokCompleted[p] = 0;
      for (int i = 0; i < days; i++) {
        String dStr = DateFormat('yyyy-MM-dd').format(start.add(Duration(days: i)));
        expectedUniqueKeys.add("${dStr}_$p");
      }
    }

    int duplicatesRemoved = 0;
    int rawSessionsFound = 0;

    _allDriverRoutes.forEach((sessionId, data) {
      if (data is Map) {
        final String sId = sessionId.toString();
        final dateStr = data['date']?.toString() ?? "";
        bool inRange = dateStr.compareTo(startStr) >= 0 && dateStr.compareTo(endStr) <= 0;
        
        if (inRange) {
          rawSessionsFound++;
          // Check collection progress for this session
          final progress = _allCollectionProgress[sId];
          if (progress is Map) {
            progress.forEach((purokKey, purokData) {
              if (purokData is Map) {
                final areaName = purokData['name']?.toString() ?? "";
                if (areaName.isNotEmpty) {
                  // Apply area filter
                  if (areaFilter == "All Areas" || areaName == areaFilter) {
                    final String uniqueKey = "${dateStr}_$areaName";
                    
                    if (purokData['completed'] == true) {
                      if (!completedUniqueKeys.contains(uniqueKey)) {
                        completedUniqueKeys.add(uniqueKey);
                        if (purokCompleted.containsKey(areaName)) {
                          purokCompleted[areaName] = purokCompleted[areaName]! + 1;
                        }
                      } else {
                        duplicatesRemoved++;
                      }
                    }
                    
                    // In case a driver does a route not in our default expected set
                    if (!expectedUniqueKeys.contains(uniqueKey)) {
                       expectedUniqueKeys.add(uniqueKey);
                       purokExpected[areaName] = (purokExpected[areaName] ?? 0) + 1;
                    }
                  }
                }
              }
            });
          }
        }
      }
    });

    if (debug) {
      debugPrint("==================================================");
      debugPrint("ANALYTICS ROUTE DEBUG:");
      debugPrint("- SELECTED AREA: $areaFilter");
      debugPrint("- START DATE: $startStr");
      debugPrint("- END DATE: $endStr");
      debugPrint("- RAW SESSIONS IN RANGE: $rawSessionsFound");
      debugPrint("- TOTAL EXPECTED ASSIGNMENTS: ${expectedUniqueKeys.length}");
      debugPrint("- UNIQUE COMPLETED ROUTES: ${completedUniqueKeys.length}");
      debugPrint("- DUPLICATES REMOVED: $duplicatesRemoved");
      debugPrint("- FINAL: ${completedUniqueKeys.length} / ${expectedUniqueKeys.length}");
      debugPrint("==================================================");
    }

    return {
      'total': expectedUniqueKeys.length,
      'completed': completedUniqueKeys.length,
      'purokExpected': purokExpected,
      'purokCompleted': purokCompleted,
    };
  }

  DateTimeRange _getPreviousPeriod(DateTimeRange current, bool isRange) {
    if (!isRange) {
      // Single day: previous day
      final prevDay = current.start.subtract(const Duration(days: 1));
      return DateTimeRange(start: prevDay, end: prevDay);
    } else {
      // Date range: previous period of same duration
      final duration = current.end.difference(current.start);
      final prevEnd = current.start.subtract(const Duration(days: 1));
      final prevStart = prevEnd.subtract(duration);
      return DateTimeRange(start: prevStart, end: prevEnd);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        bool isMobile = constraints.maxWidth < 900;
        return Scaffold(
          backgroundColor: const Color(0xFFF4F7F9),
          body: SafeArea(
            child: Column(
              children: [
                _buildHeader(isMobile),
                _buildFilterBar(),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24, vertical: 24),
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 1200),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Viewing Dashboard: $_selectedArea", style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF2C3E50))),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                Expanded(child: _buildMetricCard("Routes Completed", "$_completedRoutes/$_totalRoutes", Icons.local_shipping_rounded, const Color(0xFF4CAF50), trend: _routeTrend, isPositive: _routeTrendPositive)),
                                const SizedBox(width: 16),
                                Expanded(child: _buildMetricCard("Total Coverage", "${_coveragePercent.toInt()}%", Icons.map_rounded, const Color(0xFF2196F3), trend: _coverageTrend, isPositive: _coverageTrendPositive)),
                                if (!isMobile) ...[
                                  const SizedBox(width: 16),
                                  Expanded(child: _buildMetricCard("Issue Rate", "${_issueRate.toStringAsFixed(1)}%", Icons.warning_rounded, const Color(0xFFF44336), trend: _issueTrend, isPositive: _issueTrendPositive)),
                                ],
                              ],
                            ),
                            const SizedBox(height: 24),
                            if (isMobile) ...[
                              _buildChartSection("Truck Status", _buildTruckDonutChart(), legend: [
                                _buildLegendItem("Active", (_truckStatusData['Active'] ?? 0).toInt(), Colors.green),
                                _buildLegendItem("Full", (_truckStatusData['Full'] ?? 0).toInt(), Colors.amber),
                                _buildLegendItem("Idle", (_truckStatusData['Idle'] ?? 0).toInt(), Colors.grey.shade300),
                              ]),
                              const SizedBox(height: 24),
                              _buildChartSection("Complaints", Column(
                                children: [
                                  Expanded(child: _buildComplaintsDonutChart()),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                                    child: Column(
                                      children: [
                                        Text("Matched: ${_complaintSourceData['Residents']?.toInt()} Residents, ${_complaintSourceData['Drivers']?.toInt()} Drivers",
                                          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                      ],
                                    ),
                                  ),
                                ],
                              ), legend: [
                                _buildLegendItem("Pending", (_complaintStatusData['Pending'] ?? 0).toInt(), Colors.red),
                                _buildLegendItem("In Progress", (_complaintStatusData['In Progress'] ?? 0).toInt(), Colors.blue),
                                _buildLegendItem("Resolved", (_complaintStatusData['Resolved'] ?? 0).toInt(), Colors.green),
                              ]),
                              const SizedBox(height: 24),
                              _buildPurokChartSection(),
                              const SizedBox(height: 24),
                              _buildInsightsSection(isMobile),
                            ] else ...[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Column(
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(child: _buildChartSection("Truck Status", _buildTruckDonutChart(), legend: [
                                              _buildLegendItem("Active", (_truckStatusData['Active'] ?? 0).toInt(), Colors.green),
                                              _buildLegendItem("Full", (_truckStatusData['Full'] ?? 0).toInt(), Colors.amber),
                                              _buildLegendItem("Idle", (_truckStatusData['Idle'] ?? 0).toInt(), Colors.grey.shade300),
                                            ])),
                                            const SizedBox(width: 24),
                                            Expanded(child: _buildChartSection("Complaints", Column(
                                              children: [
                                                Expanded(child: _buildComplaintsDonutChart()),
                                                const SizedBox(height: 8),
                                                Container(
                                                  padding: const EdgeInsets.all(8),
                                                  decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                                                  child: Column(
                                                    children: [
                                                      Text("Matched: ${_complaintSourceData['Residents']?.toInt()} Residents, ${_complaintSourceData['Drivers']?.toInt()} Drivers",
                                                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ), legend: [
                                              _buildLegendItem("Pending", (_complaintStatusData['Pending'] ?? 0).toInt(), Colors.red),
                                              _buildLegendItem("In Progress", (_complaintStatusData['In Progress'] ?? 0).toInt(), Colors.blue),
                                              _buildLegendItem("Resolved", (_complaintStatusData['Resolved'] ?? 0).toInt(), Colors.green),
                                            ])),
                                          ],
                                        ),
                                        const SizedBox(height: 24),
                                        _buildPurokChartSection(),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  Expanded(
                                    flex: 2,
                                    child: _buildInsightsSection(isMobile),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 48),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(bool isMobile) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          if (!widget.isEmbedded || widget.onBack != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF2C3E50), size: 20),
              onPressed: () {
                if (widget.onBack != null) {
                  widget.onBack!();
                } else {
                  Navigator.pop(context);
                }
              },
            ),
            const SizedBox(width: 8),
          ],
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Analytics & Reports", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF2C3E50))),
                Text("Comprehensive system performance overview", style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: () => _showExportDialog(context),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text("EXPORT", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00BFA5),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    String dateLabel = _isDateRange 
        ? "${DateFormat('MMM dd').format(_selectedDateRange.start)} - ${DateFormat('MMM dd').format(_selectedDateRange.end)}"
        : DateFormat('MMM dd, yyyy').format(_selectedDateRange.start);

    return Container(
      decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Colors.grey.shade100))),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          _filterChip(Icons.location_on_rounded, _selectedArea, onTap: () => _showAreaSelection(context)),
          const SizedBox(width: 24),
          _filterChip(Icons.calendar_today_rounded, dateLabel, onTap: () => _showDateRangePicker(context)),
        ],
      ),
    );
  }

  Future<void> _showDateRangePicker(BuildContext context) async {
    final DateTimeRange? picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => _CuteDateRangePicker(initialRange: _selectedDateRange),
    );
    if (picked != null) {
      setState(() { _selectedDateRange = picked; _isDateRange = picked.start != picked.end; });
      refreshAllData();
    }
  }

  Widget _filterChip(IconData icon, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xFFF1F4F8), borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            Icon(icon, size: 16, color: const Color(0xFF2C3E50)),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF2C3E50))),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down_rounded, size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, IconData icon, Color color, {bool isPositive = true, String? trend}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: color, size: 20),
              ),
              if (trend != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (isPositive ? Colors.green : Colors.red).withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(isPositive ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 12, color: isPositive ? Colors.green : Colors.red),
                      const SizedBox(width: 4),
                      Text(trend, style: TextStyle(color: isPositive ? Colors.green : Colors.red, fontSize: 11, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(title, style: TextStyle(color: Colors.grey.shade600, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF2C3E50))),
        ],
      ),
    );
  }

  Widget _buildChartSection(String title, Widget chart, {List<Widget>? legend}) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 15, offset: const Offset(0, 5))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF2C3E50))),
          const SizedBox(height: 48),
          SizedBox(height: 280, child: chart),
          if (legend != null) ...[
            const SizedBox(height: 32),
            Wrap(spacing: 16, runSpacing: 8, alignment: WrapAlignment.center, children: legend),
          ],
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, int value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 8),
        Text("$label ($value)", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF2C3E50))),
      ],
    );
  }

  Widget _buildPurokChartSection() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 15, offset: const Offset(0, 5))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Purok Coverage (%)", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF2C3E50))),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(color: Color(0xFFE3F2FD), shape: BoxShape.circle),
                child: const Icon(Icons.visibility_rounded, color: Color(0xFF2196F3), size: 18),
              ),
            ],
          ),
          const SizedBox(height: 32),
          SizedBox(height: 350, child: _buildPurokBarChart()),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => _showFullDetailsModal(context),
              child: const Text("VIEW FULL DETAILS", style: TextStyle(color: Color(0xFF2196F3), fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
            ),
          ),
        ],
      ),
    );
  }

  void _showFullDetailsModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
        child: _FullDetailsModal(frequencyData: _purokFrequencyData, complaintData: _purokComplaintData),
      ),
    );
  }

  Widget _buildInsightsSection(bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.auto_awesome_rounded, color: Color(0xFF1A1A1A), size: 24),
            const SizedBox(width: 12),
            const Text("Predictions & Insights", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Color(0xFF1A1A1A))),
            const Spacer(),
            if (_isAiLoading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFA5))),
          ],
        ),
        const SizedBox(height: 24),
        _buildPredictionCard("Waste Volume Prediction", [
          _predictionDetailRow("Tomorrow:", "${_tomorrowWaste.toInt()} kg", themeColor: const Color(0xFF1E88E5)),
          _predictionDetailRow("This Week:", "${_weeklyWaste.toInt()} kg", themeColor: const Color(0xFF1E88E5)),
          _predictionDetailRow("Truck Capacity:", "5000 kg", themeColor: const Color(0xFF1E88E5)),
        ], titleColor: const Color(0xFF1E88E5)),
        const SizedBox(height: 16),
        _buildPredictionCard("Estimated Arrival Times", _etaEstimates.entries.map((e) => _predictionDetailRow("${e.key}:", e.value, themeColor: const Color(0xFF43A047))).toList(), titleColor: const Color(0xFF43A047)),
        const SizedBox(height: 16),
        _buildPredictionCard("Recommendations", [
          Text(_recommendations, style: const TextStyle(fontSize: 13, color: Color(0xFF6A1B9A), fontWeight: FontWeight.w600, height: 1.5)),
          const SizedBox(height: 12),
          const Text("• Note: Waste volume estimation based on Purok area.", style: TextStyle(fontSize: 11, color: Color(0xFF6A1B9A), fontStyle: FontStyle.italic)),
        ], titleColor: const Color(0xFF6A1B9A)),
        const SizedBox(height: 24),
        const Text("System Performance Metrics", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
        const SizedBox(height: 16),
        _buildEfficiencyCard(),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: Colors.green.withAlpha(10), borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.green.withAlpha(20))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [Icon(Icons.insights_rounded, size: 18, color: Colors.green), SizedBox(width: 10), Text("Operational Context", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Colors.green))]),
              const SizedBox(height: 12),
              _isAiLoading ? _buildShimmer(14, 0.8) : Text(_geminiSummary ?? "Analyzing current collection patterns...", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2C3E50), height: 1.5)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPredictionCard(String title, List<Widget> children, {required Color titleColor}) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 15, offset: const Offset(0, 5))], border: Border.all(color: titleColor.withAlpha(15))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: titleColor)), const SizedBox(height: 20), ...children]),
    );
  }

  Widget _predictionDetailRow(String label, String value, {required Color themeColor}) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w700, fontSize: 14)), Text(value, style: TextStyle(color: themeColor, fontWeight: FontWeight.w900, fontSize: 14))]));
  }

  Widget _buildShimmer(double height, double widthFactor) {
    return Container(height: height, width: double.infinity, decoration: BoxDecoration(color: Colors.grey.withAlpha(30), borderRadius: BorderRadius.circular(4)));
  }

  Widget _buildEfficiencyCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade200)),
      child: Column(children: [
        _insightRow("Avg Collection Time", "${_avgCollectionTime.toStringAsFixed(1)}h"),
        _insightRow("Stops per Route", "$_stopsPerRoute"),
        _insightRow("Distance Covered", "${_distanceCovered.toStringAsFixed(1)}km"),
        _insightRow("Prediction Accuracy", "${_predictionAccuracy.toStringAsFixed(1)}%", isSuccess: _predictionAccuracy > 90),
      ]),
    );
  }

  Widget _insightRow(String label, String value, {bool isSuccess = false}) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF2C3E50))), Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: isSuccess ? Colors.green : const Color(0xFF2C3E50)))]));
  }

  Widget _buildTruckDonutChart() {
    final double active = _truckStatusData['Active'] ?? 0;
    final double full = _truckStatusData['Full'] ?? 0;
    final double idle = _truckStatusData['Idle'] ?? 0;
    final double total = active + full + idle;
    if (total == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline_rounded, color: Colors.grey.shade300, size: 40),
            const SizedBox(height: 8),
            const Text("No data matching\nselected filters", 
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }
    return PieChart(PieChartData(sections: [
      if (active > 0) PieChartSectionData(value: active, color: Colors.green, radius: 30, title: '${active.toInt()}\nActive', titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900), titlePositionPercentageOffset: 1.8),
      if (full > 0) PieChartSectionData(value: full, color: Colors.amber, radius: 30, title: '${full.toInt()}\nFull', titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900), titlePositionPercentageOffset: 1.8),
      if (idle > 0) PieChartSectionData(value: idle, color: Colors.grey.shade300, radius: 30, title: '${idle.toInt()}\nIdle', titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900), titlePositionPercentageOffset: 1.8),
    ], centerSpaceRadius: 50, sectionsSpace: 4));
  }

  Widget _buildComplaintsDonutChart() {
    final double pending = _complaintStatusData['Pending'] ?? 0;
    final double inProgress = _complaintStatusData['In Progress'] ?? 0;
    final double resolved = _complaintStatusData['Resolved'] ?? 0;
    
    final double total = pending + inProgress + resolved;
    if (total == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline_rounded, color: Colors.grey.shade300, size: 40),
            const SizedBox(height: 8),
            const Text("No data matching\nselected filters", 
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }

    return PieChart(PieChartData(sections: [
      if (pending > 0) 
        PieChartSectionData(
          value: pending, color: Colors.red, radius: 30, 
          title: '${pending.toInt()}\nPending', titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
          titlePositionPercentageOffset: 1.8,
        ),
      if (inProgress > 0) 
        PieChartSectionData(
          value: inProgress, color: Colors.blue, radius: 30, 
          title: '${inProgress.toInt()}\nIn Progress', titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
          titlePositionPercentageOffset: 1.8,
        ),
      if (resolved > 0) 
        PieChartSectionData(
          value: resolved, color: Colors.green, radius: 30, 
          title: '${resolved.toInt()}\nResolved', titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
          titlePositionPercentageOffset: 1.8,
        ),
    ], centerSpaceRadius: 50, sectionsSpace: 4));
  }

  Widget _buildPurokBarChart() {
    final areas = ["P1", "P2", "P3", "P4", "Riles", "Sentro", "ISIDRO", "PARA", "RIV", "KAL", "HOME", "TANCO"];
    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceAround, maxY: 100,
      titlesData: FlTitlesData(show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (v, m) => Padding(padding: const EdgeInsets.only(top: 12), child: Text(v.toInt() < areas.length ? areas[v.toInt()] : "", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800))))), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 30, getTitlesWidget: (v, m) => Text("${v.toInt()}%", style: const TextStyle(fontSize: 10))))),
      gridData: const FlGridData(show: true, drawVerticalLine: false), borderData: FlBorderData(show: false),
      barGroups: List.generate(areas.length, (index) {
        final count = _purokFrequencyData[_purokNames[index]] ?? 0;
        return BarChartGroupData(x: index, barRods: [BarChartRodData(toY: count.toDouble(), color: const Color(0xFF2196F3), width: 14, borderRadius: const BorderRadius.vertical(top: Radius.circular(4)))]);
      }),
    ));
  }

  void _showAreaSelection(BuildContext context) {
    showDialog(
      context: context, 
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), 
        child: Container(
          width: 400, padding: const EdgeInsets.all(24), 
          child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, 
            children: [
              const Text("Select Area Filter", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)), 
              const SizedBox(height: 16), 
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5), 
                child: ListView(
                  shrinkWrap: true, 
                  children: ["All Areas", ..._purokNames].map((area) => ListTile(
                    title: Text(area, style: TextStyle(fontWeight: area == _selectedArea ? FontWeight.w900 : FontWeight.w600)), 
                    trailing: area == _selectedArea ? const Icon(Icons.check_circle, color: Color(0xFF00BFA5)) : null, 
                    onTap: () { setState(() => _selectedArea = area); refreshAllData(); Navigator.pop(context); }
                  )).toList()
                )
              ), 
              const SizedBox(height: 16), 
              Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL")))
            ]
          )
        )
      )
    );
  }

  void _showExportDialog(BuildContext context) {
    String selectedCategory = "Full System Report";
    String selectedFormat = "PDF Document (.pdf)";
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Container(
            width: 500,
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.description_outlined, color: Color(0xFF00BFA5), size: 48),
                const SizedBox(height: 24),
                const Text("Export Performance Reports",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 32),
                _exportDropdown("Report Category", ["Full System Report", "Truck Performance", "Area Coverage"], selectedCategory, (val) {
                  if (val != null) setDialogState(() => selectedCategory = val);
                }),
                const SizedBox(height: 16),
                _exportDropdown("File Format", ["PDF Document (.pdf)", "Excel Spreadsheet (.xlsx)"], selectedFormat, (val) {
                  if (val != null) setDialogState(() => selectedFormat = val);
                }),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Future.microtask(() {
                      _exportReport(selectedCategory, selectedFormat);
                    });
                  },
                  child: const Text("DOWNLOAD REPORT"),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("CANCEL"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _exportDropdown(String hint, List<String> items, String currentVal, ValueChanged<String?> onChanged) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)), child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: currentVal, hint: Text(hint), isExpanded: true, items: items.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontWeight: FontWeight.w600)))).toList(), onChanged: onChanged)));
  }
}

class _CuteDateRangePicker extends StatefulWidget {
  final DateTimeRange initialRange;
  const _CuteDateRangePicker({required this.initialRange});
  @override State<_CuteDateRangePicker> createState() => _CuteDateRangePickerState();
}

class _CuteDateRangePickerState extends State<_CuteDateRangePicker> {
  late DateTime _currentMonth; DateTime? _rangeStart; DateTime? _rangeEnd;
  @override void initState() { super.initState(); _currentMonth = DateTime(widget.initialRange.start.year, widget.initialRange.start.month); _rangeStart = widget.initialRange.start; _rangeEnd = widget.initialRange.end; }
  @override Widget build(BuildContext context) {
    return Dialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)), child: Container(width: 380, padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Row(children: [Icon(Icons.notes_rounded, color: Colors.grey.shade600), const Spacer(), const Text("Select Date", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)), const Spacer(), const Icon(Icons.calendar_today_rounded, color: Color(0xFF00BFA5))]), const SizedBox(height: 32), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [IconButton(icon: const Icon(Icons.keyboard_double_arrow_left_rounded), onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1))), Text(DateFormat('MMMM, yyyy').format(_currentMonth), style: const TextStyle(fontWeight: FontWeight.w900)), IconButton(icon: const Icon(Icons.keyboard_double_arrow_right_rounded), onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1)))]), const SizedBox(height: 16), _buildDaysGrid(), const SizedBox(height: 32), ElevatedButton(onPressed: () => Navigator.pop(context, DateTimeRange(start: _rangeStart ?? DateTime.now(), end: _rangeEnd ?? _rangeStart ?? DateTime.now())), child: const Text("Apply Filter"))])));
  }
  Widget _buildDaysGrid() {
    final int daysInMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final int firstDayWeekday = DateTime(_currentMonth.year, _currentMonth.month, 1).weekday % 7;
    return GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7), itemCount: daysInMonth + firstDayWeekday, itemBuilder: (context, index) {
      if (index < firstDayWeekday) return const SizedBox.shrink();
      final int day = index - firstDayWeekday + 1; final DateTime date = DateTime(_currentMonth.year, _currentMonth.month, day);
      final bool isSelected = (_rangeStart != null && date.year == _rangeStart!.year && date.month == _rangeStart!.month && date.day == _rangeStart!.day) || (_rangeEnd != null && date.year == _rangeEnd!.year && date.month == _rangeEnd!.month && date.day == _rangeEnd!.day);
      return InkWell(
        onTap: () {
          setState(() {
            if (_rangeStart == null || (_rangeStart != null && _rangeEnd != null)) {
              _rangeStart = date;
              _rangeEnd = null;
            } else if (date.isBefore(_rangeStart!)) {
              _rangeStart = date;
            } else {
              _rangeEnd = date;
            }
          });
        },
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(color: isSelected ? const Color(0xFF00BFA5) : null, shape: BoxShape.circle),
          child: Text(
            day.toString(),
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.black,
              fontWeight: isSelected ? FontWeight.w900 : FontWeight.normal,
            ),
          ),
        ),
      );
    });
  }
}

class _FullDetailsModal extends StatefulWidget {
  final Map<String, int> frequencyData; final Map<String, int> complaintData;
  const _FullDetailsModal({required this.frequencyData, required this.complaintData});
  @override State<_FullDetailsModal> createState() => _FullDetailsModalState();
}

class _FullDetailsModalState extends State<_FullDetailsModal> {
  String? _geminiSummaryLocal; bool _isLoadingLocal = true;
  @override
  void initState() {
    super.initState();
    _generateGeminiSummary();
  }
  Future<void> _generateGeminiSummary() async {
    const apiKey = "PASTE_YOUR_GEMINI_API_KEY_HERE"; 
    final model = GenerativeModel(model: 'gemini-1.5-flash-latest', apiKey: apiKey);
    
    StringBuffer data = StringBuffer("Purok Coverage Data:\n");
    widget.frequencyData.forEach((k, v) => data.writeln("- $k: $v% coverage"));
    data.writeln("\nComplaints per Purok:\n");
    widget.complaintData.forEach((k, v) => data.writeln("- $k: $v issues"));

    try { 
      final content = [Content.text("You are the Balintawak Garbage System AI. Summarize this operational data for the manager and provide a quick conclusion: $data")];
      final response = await model.generateContent(content); 
      if (mounted) {
        setState(() { 
          _geminiSummaryLocal = response.text; 
          _isLoadingLocal = false; 
        }); 
      }
    } catch (e) { 
      if (mounted) {
        setState(() { 
          _isLoadingLocal = false; 
          _geminiSummaryLocal = "AI insights temporarily unavailable."; 
        }); 
      }
    }
  }
  @override Widget build(BuildContext context) {
    return Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32)), child: Column(mainAxisSize: MainAxisSize.min, children: [Text("Operational Insights", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)), const SizedBox(height: 24), _isLoadingLocal ? const CircularProgressIndicator() : Text(_geminiSummaryLocal ?? ""), const SizedBox(height: 24), ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text("DISMISS"))]));
  }
}
