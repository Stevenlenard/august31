import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'utils/app_localizations.dart';
import 'screens/login_screen.dart';
import 'screens/admin_dashboard.dart';
import 'screens/resident_dashboard.dart';
import 'screens/driver_dashboard.dart';
import 'screens/register_choice_screen.dart';
import 'screens/resident_register.dart';
import 'screens/driver_register.dart';
import 'screens/complaints_screen.dart';
import 'screens/analytics_screen.dart';
import 'screens/user_management_screen.dart';
import 'screens/file_complaint_screen.dart';
import 'screens/resident_track_truck_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/verify_2fa_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Localizations
  await AppLocalizations.init();

  // Set Mapbox Access Token
  MapboxOptions.setAccessToken("pk.eyJ1IjoicHJpbmNlNjcwMyIsImEiOiJjbW9zeHB2ODIwNDFnMnRwdWxsam9sYWJmIn0.8DQhyf9Z9-yP8lCuP2WS3g");

  // Initialize Firebase with the config from google-services.json
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyAMvvefK0z-cpBLdWQaNpRvDfGtqv0GFe4",
      appId: "1:410975851749:android:56415852013793e1b2300c", // Using Android App ID for compatibility
      messagingSenderId: "410975851749",
      projectId: "garbagesis-78d39",
      databaseURL: "https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app",
    ),
  );
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Garbage Tracker',
      theme: ThemeData(
        primarySwatch: Colors.green,
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const LoginScreen(),
        '/admin_dashboard': (context) => const AdminDashboard(),
        '/resident_dashboard': (context) => const ResidentDashboard(),
        '/driver_dashboard': (context) => const DriverDashboard(),
        '/register': (context) => const RegisterChoiceScreen(),
        '/register_resident': (context) => const ResidentRegisterScreen(),
        '/register_driver': (context) => const DriverRegisterScreen(),
        '/complaints': (context) => const ComplaintsScreen(),
        '/analytics': (context) => const AnalyticsScreen(),
        '/user_management': (context) => const UserManagementScreen(),
        '/file_complaint': (context) => const FileComplaintScreen(),
        '/track_trucks': (context) => const ResidentTrackTruckScreen(),
        '/forgot_password': (context) => const ForgotPasswordScreen(),
        '/verify_2fa': (context) {
          final args = ModalRoute.of(context)!.settings.arguments;
          if (args is Map<String, dynamic>) {
            return Verify2FAScreen(userData: args);
          }
          return const LoginScreen(); // Fallback if arguments are missing
        },
      },
    );
  }
}
