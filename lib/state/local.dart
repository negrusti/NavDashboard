// Copyright Jody M Sankey 2022
// This software may be modified and distributed under the terms
// of the MIT license. See the LICENCE.md file for details.

import 'dart:async';

import 'package:async/async.dart';
import 'package:nmea_dashboard/state/values.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'common.dart';

const _interval = Duration(seconds: 1);

/// Returns an infinite stream of valid values read from the local device
/// network port, logging any errors.
Stream<BoundValue> valuesFromLocalDevice() {
  return StreamGroup.merge([
    Stream.periodic(_interval, (_) {
      return BoundValue<SingleValue<DateTime>>(
          Source.local, Property.localTime, SingleValue(DateTime.now()));
    }),
    Stream.periodic(_interval, (_) {
      return BoundValue<SingleValue<DateTime>>(
          Source.local, Property.utcTime, SingleValue(DateTime.now().toUtc()));
    }),
    // GPS data (coordinates, COG, SOG)
    _gpsDataStream(),

    // Barometric pressure stream
    _pressureDataStream(),    
  ]);
}

Stream<BoundValue> _gpsDataStream() {
  return Stream.periodic(_interval, (_) async {
    // Ensure location permissions are granted
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permissions are denied.');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

    // Get the latest position
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    // Create a list of BoundValue objects for all GPS-related properties
    return [
      BoundValue<SingleValue<Map<String, double>>>(
        Source.local,
        Property.gpsPosition,
        SingleValue({
          'latitude': position.latitude,
          'longitude': position.longitude,
        }),
      ),
      BoundValue<SingleValue<double>>(
        Source.local,
        Property.courseOverGround,
        SingleValue(position.heading), // Heading (COG)
      ),
      BoundValue<SingleValue<double>>(
        Source.local,
        Property.speedOverGround,
        SingleValue(position.speed), // Speed (SOG)
      ),
    ];
  })
      .asyncMap((values) async => await values) // Handle futures in the periodic stream
      .expand((values) => values); // Flatten the list of BoundValue into individual stream events
}

Stream<BoundValue> _pressureDataStream() {
  // Access the barometer sensor stream
  return Stream.periodic(_interval, (_) async {
    // Retrieve pressure data from sensors_plus
    double? barometricPressure;

    try {
      // Listen to the barometer readings
      barometricPressure = await barometerEvents.first.then((event) => event.pressure);
    } catch (e) {
      throw Exception('Error accessing barometer data: $e');
    }

    // Ensure we return a BoundValue for the pressure
    return BoundValue<SingleValue<double>>(
      Source.local,
      Property.barometricPressure,
      SingleValue(barometricPressure ?? 0.0), // Default to 0.0 if null
    );
  }).asyncMap((event) async => await event); // Resolve futures in the periodic stream
}
