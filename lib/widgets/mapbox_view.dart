import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size, Visibility;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbox show Visibility;
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart' as geo;

class MapboxView extends StatefulWidget {
  final String mode; 
  final String? selectedTruckId;
  final VoidCallback? onTap;

  const MapboxView({super.key, required this.mode, this.selectedTruckId, this.onTap});

  @override
  State<MapboxView> createState() => _MapboxViewState();
}

class _MapboxViewState extends State<MapboxView> {
  MapboxMap? _map;
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  geo.Position? _residentPosition;
  bool _truckLayersCreated = false;
  bool _managersReady = false;
  bool _isUpdatingMarkers = false;
  bool _isFollowLocked = false;

  @override
  void initState() {
    super.initState();
    _getResidentLocation();
  }

  Future<void> _getResidentLocation() async {
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) permission = await geo.Geolocator.requestPermission();
    if (permission == geo.LocationPermission.always || permission == geo.LocationPermission.whileInUse) {
      final pos = await geo.Geolocator.getCurrentPosition();
      if (mounted) setState(() => _residentPosition = pos);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GestureDetector(
          onTap: widget.onTap,
          child: MapWidget(
            key: const ValueKey("mapbox_map"),
            onMapCreated: (map) => _map = map,
            onStyleLoadedListener: (data) async {
               if (_map == null) return;
               _map!.location.updateSettings(LocationComponentSettings(enabled: true, pulsingEnabled: true));
               if (mounted) setState(() => _managersReady = true);
               _setupFirebaseSync();
            },
            viewport: CameraViewportState(center: Point(coordinates: Position(121.1623, 13.9413)), zoom: 14.5),
          ),
        ),
        if (widget.mode == 'dashboard')
          Positioned(
            bottom: 12,
            right: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildMiniMapAction(
                  icon: _isFollowLocked ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
                  isActive: _isFollowLocked,
                  onTap: () {
                    setState(() => _isFollowLocked = !_isFollowLocked);
                    if (_isFollowLocked && _residentPosition != null) {
                      _map?.setCamera(CameraOptions(center: Point(coordinates: Position(_residentPosition!.longitude, _residentPosition!.latitude)), zoom: 16.5));
                      _map?.gestures.updateSettings(GesturesSettings(scrollEnabled: false, rotateEnabled: false, pitchEnabled: false));
                    } else {
                      _map?.gestures.updateSettings(GesturesSettings(scrollEnabled: true, rotateEnabled: true, pitchEnabled: true));
                    }
                  },
                ),
                const SizedBox(height: 8),
                _buildMiniMapAction(
                  icon: Icons.map_outlined,
                  onTap: () {
                    _map?.setCamera(CameraOptions(center: Point(coordinates: Position(121.1623, 13.9413)), zoom: 14.5));
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMiniMapAction({required IconData icon, required VoidCallback onTap, bool isActive = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF00C853) : Colors.white,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, color: isActive ? Colors.white : const Color(0xFF1A1A1A), size: 24),
      ),
    );
  }

  void _setupFirebaseSync() {
    _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists) {
        final Map data = event.snapshot.value as Map;
        final Map<String, Map<dynamic, dynamic>> trucks = {};
        data.forEach((key, value) {
          final val = value as Map;
          final status = (val['status'] ?? '').toString().toUpperCase();
          if (val['isOnline'] == true && (status == 'ACTIVE' || status == 'COLLECTING')) {
            trucks[key.toString()] = val;
          }
        });
        _updateTruckMarkers(trucks);
      }
    });
  }

  void _updateTruckMarkers(Map<String, Map<dynamic, dynamic>> trucksData) async {
    if (_map == null || !_managersReady || _isUpdatingMarkers) return;
    _isUpdatingMarkers = true;
    final String sourceId = "trucks-source";
    final String layerId = "trucks-layer";

    final featureCollection = {
      "type": "FeatureCollection",
      "features": trucksData.entries.map((e) => {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [e.value['longitude'], e.value['latitude']]},
        "properties": {"truckId": e.key, "label": "DRIVER\n${e.key}"}
      }).toList()
    };

    try {
      final style = _map!.style;
      if (!_truckLayersCreated || !(await style.styleLayerExists(layerId))) {
        try { await style.removeStyleLayer(layerId); } catch (_) {}
        try { await style.removeStyleSource(sourceId); } catch (_) {}
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));
        await style.addLayer(CircleLayer(id: layerId, sourceId: sourceId, circleRadius: 8.0, circleColor: Colors.green.toARGB32(), circleStrokeWidth: 2.0, circleStrokeColor: Colors.white.toARGB32(), visibility: mbox.Visibility.VISIBLE));
        if (mounted) setState(() => _truckLayersCreated = true);
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection));
      }
    } catch (e) {
      debugPrint("Map Error: $e");
      if (mounted) setState(() => _truckLayersCreated = false);
    } finally { _isUpdatingMarkers = false; }
  }
}
