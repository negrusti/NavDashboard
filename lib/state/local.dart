// Copyright Jody M Sankey 2022
// This software may be modified and distributed under the terms
// of the MIT license. See the LICENCE.md file for details.

import 'dart:async';

import 'package:async/async.dart';
import 'package:nmea_dashboard/state/values.dart';
import 'package:geolocator/geolocator.dart';
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
  final sensorManager = SensorManager();

  return Stream.periodic(_interval, (_) async {
    // Initialize the barometric pressure sensor
    final sensor = await sensorManager.getDefaultSensor(SensorType.PRESSURE);

    if (sensor == null) {
      throw Exception('Pressure sensor not available on this device.');
    }

    // Get the latest pressure reading from the sensor
    final pressureStream = sensorManager.getSensorStream(sensor);
    final pressure = await pressureStream.first;

    return BoundValue<SingleValue<double>>(
      Source.local,
      Property.barometricPressure,
      SingleValue(pressure), // Pressure in hPa (hectopascals)
    );
  }).asyncMap((event) async => await event); // Ensure we handle futures inside the periodic stream
}