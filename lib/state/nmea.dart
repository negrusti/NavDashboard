// Copyright Jody M Sankey 2022
// This software may be modified and distributed under the terms
// of the MIT license. See the LICENCE.md file for details.

import 'dart:collection';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:nmea_dashboard/state/settings.dart';
import 'package:nmea_dashboard/state/values.dart';

import 'common.dart';

/// A marker exception for message types that are neither supported nor ignored.
class UnsupportedMessageException implements Exception {}

/// The list of message types that are silently ignored.
const _ignoredMessages = {
  // Ignore most things related to waypoints and routes except active waypoint.
  'AAM', 'BOD', 'BRW', 'BWW', 'R00', 'RTE', 'WCV', 'WNC',
  'WPL', 'XTR', 'WDC', 'WDR', 'WFM', 'WNR',
  // Ignore autopilot control messages.
  'APA', 'APB',
  // Ignore detailed satellite information and GPS datum.
  'ALM', 'GBS', 'GSA', 'GSV', 'DTM', 'GRS',
  // Ignore other messages that haven't been explicitly requested.
  'DBK', 'DBS', 'HDT', 'VWT', 'VWR',
};

/// The time between count events.
const Duration _logInterval = Duration(minutes: 5);

/// Tracks the count for some set of message types.
@visibleForTesting
class MessageCounts {
  int _total = 0;
  final _map = SplayTreeMap<String, int>();

  /// Increments the count of the supplied type, returning the new count.
  int increment(String type) {
    _total += 1;
    final count = (_map[type] ?? 0) + 1;
    _map[type] = count;
    return count;
  }

  /// Resets all message counts to zero.
  void clear() {
    _total = 0;
    _map.clear();
  }

  /// Returns true iff no messages have been received.
  bool get isEmpty {
    return _total == 0;
  }

  /// Returns the total count across all types.
  int get total {
    return _total;
  }

  /// Returns a string description of the counts for each type.
  String get summary {
    return _map.entries.map((e) => '${e.key}:${e.value}').join(', ');
  }
}

/// Parses strings into nmea messages, keeping track of the count for each
/// message type.
class NmeaParser {
  static final _log = Logger('NmeaParser');
  @visibleForTesting
  final ignoredCounts = MessageCounts();
  @visibleForTesting
  final unsupportedCounts = MessageCounts();
  @visibleForTesting
  final successCounts = MessageCounts();
  @visibleForTesting
  final emptyCounts = MessageCounts();
  final bool _requireChecksum;
  final NetworkProtocol protocol;
  DateTime _lastLog;

  /// Constructs a new parser for NMEA messages
  NmeaParser(this._requireChecksum,
      [this.protocol = NetworkProtocol.nmea0183])
      : _lastLog = DateTime.now();

  /// Logs the current message counts then resets them if sufficient time has
  /// passed since the last log.
  void logAndClearIfNeeded() {
    final now = DateTime.now();
    if (now.difference(_lastLog) > _logInterval) {
      logAndClearCounts();
      _lastLog = now;
    }
  }

  /// Logs the current message counts then resets them.
  void logAndClearCounts() {
    final lastLogString = DateFormat('Hms').format(_lastLog);
    if (successCounts.isEmpty) {
      _log.info('No messages received since $lastLogString');
    } else {
      _log.info(
          'Sucessfully parsed ${successCounts.total} messages: ${successCounts.summary}');
      successCounts.clear();
    }
    if (!emptyCounts.isEmpty) {
      _log.info(
          'Received ${emptyCounts.total} messages without data: ${emptyCounts.summary}');
      emptyCounts.clear();
    }
    if (!unsupportedCounts.isEmpty) {
      _log.info(
          'Received ${unsupportedCounts.total} unsupported messages: ${unsupportedCounts.summary}');
      unsupportedCounts.clear();
    }
    if (!ignoredCounts.isEmpty) {
      _log.info(
          'Received ${ignoredCounts.total} ignored messages: ${ignoredCounts.summary}');
      ignoredCounts.clear();
    }
  }

  /// Attempts to parse the supplied string as a NMEA0183 message, returning
  /// one or more bound values if parsing the message contents was successful or
  /// zero values if parsing was unsucessful but the failure mode should not be
  /// logged (e.g. a benign problem that has already been logged). Throws an
  /// exception if parsing errors were encountered and the first time a new
  /// unsupported message or a message with no data is received.
  /// If requireChecksum is true messages without a checksum are rejected.
  List<BoundValue> parseString(String string) {
    if (protocol != NetworkProtocol.nmea0183) {
      throw const FormatException('Protocol expects binary NMEA2000 packets');
    }
    if (string.startsWith('!')) {
      // Silently discard the encapsulated (e.g. AIS) sentences which are often
      // on the network.
      return [];
    } else if (!string.startsWith('\$')) {
      // Thow an exception for any other prefix, its potentially a network
      // parsing problem.
      throw const FormatException('Message is not marked with \$');
    }

    // Try to validate a checksum if there is one, throw an error if there
    // isn't but we require checksums.
    if (string.length > 3 && string[string.length - 3] == '*') {
      _validateChecksum(string.substring(1, string.length - 3),
          string.substring(string.length - 2));
      string = string.substring(0, string.length - 3);
    } else if (_requireChecksum) {
      throw const FormatException('Message did not end in a checksum');
    }

    // Pull out the salient peices of whats left.
    if (string.length < 7) {
      throw const FormatException('Message is truncated');
    }
    final type = string.substring(3, 6);
    final fields = string.substring(7).split(',');

    // Skip ignored messages.
    if (_ignoredMessages.contains(type)) {
      ignoredCounts.increment(type);
      return [];
    }

    // Pass everything else to the helper that understands message types.
    late final List<BoundValue> values;
    try {
      values = _createNmeaValues(type, fields);
    } on UnsupportedMessageException {
      // Only cause logging of unsupported types once each interval.
      if (unsupportedCounts.increment(type) <= 1) {
        throw const FormatException('Unsupported message type');
      }
      return [];
    }

    if (values.isEmpty) {
      // Only cause logging of empty types once each interval.
      if (emptyCounts.increment(type) <= 1) {
        throw const FormatException('No data found');
      }
      return [];
    }

    successCounts.increment(type);
    return values;
  }

  /// Attempts to parse a binary NMEA2000 assembled packet.
  List<BoundValue> parsePacket(Uint8List packet) {
    if (protocol != NetworkProtocol.nmea2000Assembled) {
      throw const FormatException('Protocol expects ASCII NMEA0183 sentences');
    }
    if (packet.length < 16) {
      throw const FormatException('Packet is shorter than the 16-byte header');
    }

    final byteData = ByteData.sublistView(packet);
    final pgn = byteData.getUint32(11, Endian.little);
    final payloadLength = packet[15];
    final expectedLength = payloadLength + 16;
    if (payloadLength < 1) {
      throw const FormatException('Packet payload length was zero');
    }
    if (packet.length < expectedLength) {
      throw FormatException(
          'Packet was truncated, expected $expectedLength bytes and got ${packet.length}');
    }

    final payload = Uint8List.sublistView(packet, 16, expectedLength);

    late final List<BoundValue> values;
    try {
      values = _createNmea2000Values(pgn, payload);
    } on UnsupportedMessageException {
      if (unsupportedCounts.increment(pgn.toString()) <= 1) {
        throw FormatException('Unsupported PGN $pgn');
      }
      return [];
    }

    if (values.isEmpty) {
      if (emptyCounts.increment(pgn.toString()) <= 1) {
        throw FormatException('No data found in PGN $pgn');
      }
      return [];
    }

    successCounts.increment(pgn.toString());
    return values;
  }
}

List<BoundValue> _createNmea2000Values(int pgn, Uint8List payload) {
  switch (pgn) {
    case 127245:
      _validatePayloadLength(payload, 8);
      return [
        _parseN2kAngle16(payload, 1, Property.rudderAngle),
      ].whereNotNull().toList();
    case 127250:
      _validatePayloadLength(payload, 8);
      final heading = _readUint16(payload, 1);
      final variation = _readInt16(payload, 5);
      final reference = payload[7] & 0x03;
      final headingDegrees = _uint16RadiansToDegrees(heading);
      final variationDegrees =
          (variation == null) ? null : _signedRadiansToDegrees(variation, 0.0001);
      final values = <BoundValue>[];
      if (variationDegrees != null) {
        values.add(_boundSingleValue(variationDegrees, Property.variation));
      }
      if (headingDegrees != null) {
        if (reference == 0) {
          values.add(_boundSingleValue(headingDegrees, Property.heading));
        } else if (reference == 1) {
          values.add(_boundSingleValue(headingDegrees, Property.headingMag));
        }
      }
      return values;
    case 127251:
      _validatePayloadLength(payload, 8);
      final raw = _readInt32(payload, 1);
      if (raw == null) {
        return [];
      }
      return [
        _boundSingleValue(raw * 3.125e-08 * radiansToDegrees,
            Property.rateOfTurn),
      ];
    case 127258:
      _validatePayloadLength(payload, 8);
      return [
        _parseN2kAngle16(payload, 5, Property.variation),
      ].whereNotNull().toList();
    case 128259:
      _validatePayloadLength(payload, 8);
      return [
        _parseN2kSpeed16(payload, 1, Property.speedThroughWater),
      ].whereNotNull().toList();
    case 128267:
      _validatePayloadLength(payload, 8);
      final depthRaw = _readUint32(payload, 1);
      final offsetRaw = _readInt16(payload, 5);
      if (depthRaw == null) {
        return [];
      }
      final depth = depthRaw * 0.01;
      final values = <BoundValue>[
        _boundSingleValue(depth, Property.depthUncalibrated),
      ];
      if (offsetRaw != null) {
        values.add(
            _boundSingleValue(depth + (offsetRaw * 0.001), Property.depthWithOffset));
      } else {
        values.add(_boundSingleValue(depth, Property.depthWithOffset));
      }
      return values;
    case 128275:
      _validatePayloadLength(payload, 14);
      return [
        _parseN2kDistance32(payload, 6, Property.distanceTotal),
        _parseN2kDistance32(payload, 10, Property.distanceTrip),
      ].whereNotNull().toList();
    case 129025:
      _validatePayloadLength(payload, 8);
      final lat = _readInt32(payload, 0);
      final long = _readInt32(payload, 4);
      if (lat == null || long == null) {
        return [];
      }
      return [
        _boundDoubleValue(lat * 1e-7, long * 1e-7, Property.gpsPosition,
            tier: 2),
      ];
    case 129026:
      _validatePayloadLength(payload, 8);
      final reference = payload[1] & 0x03;
      final cog = _uint16RadiansToDegrees(_readUint16(payload, 2));
      final sogRaw = _readUint16(payload, 4);
      final values = <BoundValue>[];
      final trueCog = _normalizeBearingDegrees(_toTrueReference(cog, reference));
      if (trueCog != null) {
        values.add(_boundSingleValue(trueCog, Property.courseOverGround, tier: 2));
      }
      if (sogRaw != null) {
        values.add(
            _boundSingleValue(sogRaw * 0.01, Property.speedOverGround, tier: 2));
      }
      return values;
    case 129029:
      _validatePayloadLength(payload, 31);
      final days = _readUint16(payload, 1);
      final seconds = _readUint32(payload, 3);
      final lat = _readInt64(payload, 7, 8);
      final long = _readInt64(payload, 15, 8);
      final values = <BoundValue>[];
      if (lat != null && long != null) {
        values.add(_boundDoubleValue(
            lat * 1e-16, long * 1e-16, Property.gpsPosition,
            tier: 1));
      }
      if (days != null && seconds != null) {
        final dt = DateTime.utc(1970, 1, 1)
            .add(Duration(days: days, microseconds: seconds * 100));
        values.add(_boundSingleValue(dt, Property.utcTime, tier: 1));
      }
      final hdop = (payload.length >= 35) ? _readUint16(payload, 33) : null;
      if (hdop != null) {
        values.add(_boundSingleValue(hdop * 0.01, Property.gpsHdop));
      }
      return values;
    case 129033:
      _validatePayloadLength(payload, 8);
      final days = _readUint16(payload, 0);
      final seconds = _readUint32(payload, 2);
      if (days == null || seconds == null) {
        return [];
      }
      return [
        _boundSingleValue(
            DateTime.utc(1970, 1, 1)
                .add(Duration(days: days, microseconds: seconds * 100)),
            Property.utcTime),
      ];
    case 129283:
      _validatePayloadLength(payload, 8);
      return [
        _parseN2kDistanceSigned32(payload, 1, Property.crossTrackError),
      ].whereNotNull().toList();
    case 129284:
      _validatePayloadLength(payload, 34);
      final reference = payload[5] & 0x03;
      final values = <BoundValue?>[
        _parseN2kDistance32(payload, 1, Property.waypointRange, tier: 2),
      ].whereNotNull().toList();
      final bearing = _uint16RadiansToDegrees(_readUint16(payload, 14));
      final trueBearing =
          _normalizeBearingDegrees(_toTrueReference(bearing, reference));
      if (trueBearing != null) {
        values.add(
            _boundSingleValue(trueBearing, Property.waypointBearing, tier: 2));
      }
      return values;
    case 129291:
      _validatePayloadLength(payload, 8);
      final reference = payload[1] & 0x03;
      final set = _uint16RadiansToDegrees(_readUint16(payload, 2));
      final trueSet = _normalizeBearingDegrees(_toTrueReference(set, reference));
      final driftRaw = _readUint16(payload, 4);
      final values = <BoundValue>[];
      if (trueSet != null) {
        values.add(_boundSingleValue(trueSet, Property.currentSet));
      }
      if (driftRaw != null) {
        values.add(_boundSingleValue(driftRaw * 0.01, Property.currentDrift));
      }
      return values;
    case 130306:
      _validatePayloadLength(payload, 6);
      final speedRaw = _readUint16(payload, 1);
      final angle = _uint16RadiansToDegrees(_readUint16(payload, 3));
      final reference = payload[5] & 0x07;
      if (speedRaw == null || angle == null) {
        return [];
      }
      switch (reference) {
        case 2:
          return [
            _boundSingleValue(angle, Property.apparentWindAngle),
            _boundSingleValue(speedRaw * 0.01, Property.apparentWindSpeed),
          ];
        case 3:
          return [
            _boundSingleValue(angle, Property.trueWindAngle),
            _boundSingleValue(speedRaw * 0.01, Property.trueWindSpeed),
          ];
        case 0:
        case 1:
        case 4:
          final direction =
              _normalizeBearingDegrees(_toTrueReference(angle, reference == 1 ? 1 : 0));
          if (direction == null) {
            return [];
          }
          return [
            _boundSingleValue(direction, Property.trueWindDirection),
            _boundSingleValue(speedRaw * 0.01, Property.trueWindSpeed, tier: 2),
          ];
        default:
          return [];
      }
    case 130310:
      _validatePayloadLength(payload, 8);
      return [
        _parseN2kTemperatureScaled16(payload, 2, 0.01, Property.waterTemperature),
        _parseN2kTemperatureScaled16(payload, 4, 0.01, Property.airTemperature),
        _parseN2kPressureScaled16(payload, 6, 100, Property.pressure),
      ].whereNotNull().toList();
    case 130312:
    case 130316:
      _validatePayloadLength(payload, 8);
      final source = payload[2];
      final temperature = _readUint24(payload, 3);
      if (temperature == null) {
        return [];
      }
      final celsius = (temperature * 0.001) - kelvinToCelcius;
      switch (source) {
        case 0:
          return [_boundSingleValue(celsius, Property.waterTemperature)];
        case 1:
          return [_boundSingleValue(celsius, Property.airTemperature)];
        case 9:
          return [_boundSingleValue(celsius, Property.dewPoint)];
        default:
          return [];
      }
    case 130313:
      _validatePayloadLength(payload, 8);
      final humidity = _readUint16(payload, 3);
      if (humidity == null) {
        return [];
      }
      return [
        _boundSingleValue(humidity * 0.004, Property.relativeHumidity),
      ];
    case 130314:
      _validatePayloadLength(payload, 8);
      if (payload[2] != 0) {
        return [];
      }
      return [
        _parseN2kPressureScaled32(payload, 3, 0.1, Property.pressure),
      ].whereNotNull().toList();
    case 127505:
      _validatePayloadLength(payload, 8);
      final instance = payload[0] & 0x0F;
      final fluidType = (payload[0] >> 4) & 0x0F;
      final level = _readInt16(payload, 1);
      if (fluidType != 0 || level == null || level < 0) {
        return [];
      }
      final property = _fuelPropertyForInstance(instance);
      if (property == null) {
        return [];
      }
      return [
        _boundSingleValue(level * 0.004, property, tier: 2),
      ];
    default:
      throw UnsupportedMessageException();
  }
}

const double radiansToDegrees = 180.0 / 3.1415926535897932;
const double kelvinToCelcius = 273.15;

void _validatePayloadLength(Uint8List payload, int minimumLength) {
  if (payload.length < minimumLength) {
    throw FormatException(
        'Expected at least $minimumLength payload bytes, found ${payload.length}');
  }
}

int? _readUint16(Uint8List payload, int offset) {
  final value = ByteData.sublistView(payload).getUint16(offset, Endian.little);
  return (value >= 0xFFFE) ? null : value;
}

int? _readInt16(Uint8List payload, int offset) {
  final value = ByteData.sublistView(payload).getInt16(offset, Endian.little);
  return (value >= 0x7FFD) ? null : value;
}

int? _readUint24(Uint8List payload, int offset) {
  final value =
      payload[offset] | (payload[offset + 1] << 8) | (payload[offset + 2] << 16);
  return (value >= 0xFFFFFE) ? null : value;
}

int? _readUint32(Uint8List payload, int offset) {
  final value = ByteData.sublistView(payload).getUint32(offset, Endian.little);
  return (value >= 0xFFFFFFFE) ? null : value;
}

int? _readInt32(Uint8List payload, int offset) {
  final value = ByteData.sublistView(payload).getInt32(offset, Endian.little);
  return (value >= 0x7FFFFFFD) ? null : value;
}

int? _readInt64(Uint8List payload, int offset, int length) {
  int raw = 0;
  for (int i = 0; i < length; i++) {
    raw |= payload[offset + i] << (8 * i);
  }
  final signBit = 1 << ((length * 8) - 1);
  if (raw >= ((1 << (length * 8)) - 2)) {
    return null;
  }
  if ((raw & signBit) != 0) {
    raw -= 1 << (length * 8);
  }
  return raw;
}

double? _uint16RadiansToDegrees(int? raw) {
  return (raw == null) ? null : (raw * 0.0001 * radiansToDegrees);
}

double _signedRadiansToDegrees(int raw, double scale) {
  return raw * scale * radiansToDegrees;
}

double? _normalizeBearingDegrees(double? degrees) {
  if (degrees == null) {
    return null;
  }
  final normalized = degrees % 360.0;
  return (normalized < 0) ? normalized + 360.0 : normalized;
}

double? _toTrueReference(double? degrees, int reference) {
  switch (reference) {
    case 0:
      return degrees;
    case 1:
      return null;
    default:
      return null;
  }
}

BoundValue<SingleValue<double>>? _parseN2kAngle16(
    Uint8List payload, int offset, Property property,
    {int tier = 1}) {
  final raw = _readInt16(payload, offset);
  if (raw == null) {
    return null;
  }
  return _boundSingleValue(_signedRadiansToDegrees(raw, 0.0001), property,
      tier: tier);
}

BoundValue<SingleValue<double>>? _parseN2kSpeed16(
    Uint8List payload, int offset, Property property,
    {int tier = 1}) {
  final raw = _readUint16(payload, offset);
  return (raw == null)
      ? null
      : _boundSingleValue(raw * 0.01, property, tier: tier);
}

BoundValue<SingleValue<double>>? _parseN2kDistance32(
    Uint8List payload, int offset, Property property,
    {int tier = 1}) {
  final raw = _readUint32(payload, offset);
  return (raw == null)
      ? null
      : _boundSingleValue(raw * 0.01, property, tier: tier);
}

BoundValue<SingleValue<double>>? _parseN2kDistanceSigned32(
    Uint8List payload, int offset, Property property,
    {int tier = 1}) {
  final raw = _readInt32(payload, offset);
  return (raw == null)
      ? null
      : _boundSingleValue(raw * 0.01, property, tier: tier);
}

BoundValue<SingleValue<double>>? _parseN2kTemperatureScaled16(
    Uint8List payload, int offset, double scale, Property property,
    {int tier = 1}) {
  final raw = _readUint16(payload, offset);
  return (raw == null)
      ? null
      : _boundSingleValue((raw * scale) - kelvinToCelcius, property, tier: tier);
}

BoundValue<SingleValue<double>>? _parseN2kPressureScaled16(
    Uint8List payload, int offset, double scale, Property property,
    {int tier = 1}) {
  final raw = _readUint16(payload, offset);
  return (raw == null)
      ? null
      : _boundSingleValue(raw * scale, property, tier: tier);
}

BoundValue<SingleValue<double>>? _parseN2kPressureScaled32(
    Uint8List payload, int offset, double scale, Property property,
    {int tier = 1}) {
  final raw = _readInt32(payload, offset);
  return (raw == null)
      ? null
      : _boundSingleValue(raw * scale, property, tier: tier);
}

Property? _fuelPropertyForInstance(int instance) {
  switch (instance) {
    case 0:
      return Property.fuel0;
    case 1:
      return Property.fuel1;
    case 2:
      return Property.fuel2;
    case 3:
      return Property.fuel3;
    default:
      return null;
  }
}

/// Validates that the supplied payload matches the expected ASCII checksum, throwing
/// a FormatException if not.
void _validateChecksum(payload, checksumString) {
  final int checksum = int.parse(checksumString, radix: 16);
  int xor = 0;
  for (final codeUnit in payload.codeUnits) {
    xor ^= codeUnit;
  }
  if (xor != checksum) {
    throw FormatException(
        'Invalid checksum: expected 0x${checksum.toRadixString(16)}, '
        'got 0x${xor.toRadixString(16)}');
  }
}

/// Attempts to create zero or more value containing NMEA0183 message contents
/// from the supplied type string and field list, throwing a FormatException
/// if unsuccessful or an UnsupportedMessageException if the message type is
/// not recognized.
List<BoundValue> _createNmeaValues(String type, List<String> fields) {
  switch (type) {
    case 'BWR':
    case 'BWC':
      _validateMinFieldCount(fields, 12);
      _validateFieldValue(fields, index: 6, expected: 'T');
      _validateFieldValue(fields, index: 10, expected: 'N');
      return [
        _parseSingleValue(fields[9], Property.waypointRange,
            divisor: metersToNauticalMiles),
        _parseSingleValue(fields[5], Property.waypointBearing),
      ].whereNotNull().toList();
    case 'DBT':
      _validateFieldCount(fields, 6);
      _validateFieldValue(fields, index: 3, expected: 'M');
      return [
        _parseSingleValue(fields[2], Property.depthUncalibrated, tier: 2),
      ].whereNotNull().toList();
    case 'DPT':
      _validateMinFieldCount(fields, 2);
      if (fields[0].isEmpty) {
        return [];
      }
      final depth = double.parse(fields[0]);
      final offset = fields[1].isEmpty ? 0.0 : double.parse(fields[1]);
      return [
        _boundSingleValue(depth + offset, Property.depthWithOffset),
        _boundSingleValue(depth, Property.depthUncalibrated),
      ];
    case 'HDG':
      _validateFieldCount(fields, 5);
      // TODO: Currently we support mag-only but not true-only. Consider
      //       supporting mag heading being missing if this ever arises.
      final magHdg = double.parse(fields[0]);
      if (fields[3].isEmpty) {
        // Support equipment which does not know variation.
        return [_boundSingleValue(magHdg, Property.headingMag)];
      }
      final variation = _parseVariation(fields[3], fields[4]);
      final trueHdg = (magHdg - variation) % 360.0;
      return [
        _boundSingleValue(variation, Property.variation),
        _boundSingleValue(trueHdg, Property.heading),
      ];
    case 'HDM':
      _validateFieldCount(fields, 2);
      _validateFieldValue(fields, index: 1, expected: 'M');
      return [
        _parseSingleValue(fields[0], Property.headingMag, tier: 2),
      ].whereNotNull().toList();
    case 'GGA':
      _validateFieldCount(fields, 14);
      // Note we do not support messages where the position is missing.
      final lat = _parseLatitude(fields[1], fields[2]);
      final long = _parseLongitude(fields[3], fields[4]);
      final position = _boundDoubleValue(lat, long, Property.gpsPosition);
      final hdop = _parseSingleValue(fields[7], Property.gpsHdop);
      if (hdop == null) {
        return [position];
      } else {
        return [position, hdop];
      }
    case 'GLL':
      _validateMinFieldCount(fields, 6);
      // Note we do not support messages where the position is missing.
      _validateValidityIndicator(fields, index: 5);
      final lat = _parseLatitude(fields[0], fields[1]);
      final long = _parseLongitude(fields[2], fields[3]);
      return [_boundDoubleValue(lat, long, Property.gpsPosition, tier: 2)];
    case 'MDA':
      _validateFieldCount(fields, 20);
      var ret = <BoundValue<SingleValue<double>>?>[];
      if (fields[2].isNotEmpty) {
        _validateFieldValue(fields, index: 3, expected: 'B');
        ret.add(_parseSingleValue(fields[2], Property.pressure,
            divisor: 1 / barToPascals));
      }
      if (fields[4].isNotEmpty) {
        _validateFieldValue(fields, index: 5, expected: 'C');
        ret.add(_parseSingleValue(fields[4], Property.airTemperature));
      }
      if (fields[6].isNotEmpty) {
        _validateFieldValue(fields, index: 7, expected: 'C');
        ret.add(_parseSingleValue(fields[6], Property.waterTemperature));
      }
      if (fields[8].isNotEmpty) {
        ret.add(_parseSingleValue(fields[8], Property.relativeHumidity));
      }
      if (fields[10].isNotEmpty) {
        _validateFieldValue(fields, index: 11, expected: 'C');
        ret.add(_parseSingleValue(fields[10], Property.dewPoint));
      }
      if (fields[12].isNotEmpty) {
        _validateFieldValue(fields, index: 13, expected: 'T');
        ret.add(
            _parseSingleValue(fields[12], Property.trueWindDirection, tier: 2));
      }
      return ret.whereNotNull().toList();
    case 'MWD':
      _validateFieldCount(fields, 8);
      var ret = <BoundValue<SingleValue<double>>?>[];
      if (fields[0].isNotEmpty) {
        _validateFieldValue(fields, index: 1, expected: 'T');
        ret.add(_parseSingleValue(fields[0], Property.trueWindDirection));
      }
      if (fields[6].isNotEmpty) {
        _validateFieldValue(fields, index: 7, expected: 'M');
        ret.add(_parseSingleValue(fields[6], Property.trueWindSpeed, tier: 2));
      }
      return ret.whereNotNull().toList();
    case 'MWV':
      _validateFieldCount(fields, 5);
      _validateValidityIndicator(fields, index: 4);
      final relative = (fields[1] == 'R');
      final angle = double.parse(fields[0]);
      // Dart switch expressions failing to compile when I wrote these (even
      // though I'm above the required Dart v3.0)
      // TODO: Rewrite as a switch expression when possible.
      late double divisor;
      switch (fields[3]) {
        case 'N':
          divisor = metersPerSecondToKnots;
          break;
        case 'K':
          divisor = metersPerSecondToKmph;
          break;
        default:
          divisor = 1.0;
      }
      final speed = double.parse(fields[2]) / divisor;
      return [
        _boundSingleValue(angle,
            relative ? Property.apparentWindAngle : Property.trueWindAngle),
        _boundSingleValue(speed,
            relative ? Property.apparentWindSpeed : Property.trueWindSpeed),
      ];
    case 'MTW':
      _validateFieldCount(fields, 2);
      _validateFieldValue(fields, index: 1, expected: 'C');
      return [_parseSingleValue(fields[0], Property.waterTemperature, tier: 2)]
          .whereNotNull()
          .toList();
    case 'ROT':
      _validateFieldCount(fields, 2);
      _validateValidityIndicator(fields, index: 1);
      return [_parseSingleValue(fields[0], Property.rateOfTurn, divisor: 60)]
          .whereNotNull()
          .toList();
    case 'RMB':
      _validateMinFieldCount(fields, 13);
      _validateValidityIndicator(fields, index: 0);
      // Note we don't support messages that are marked valid but missing data.
      final range = double.parse(fields[9]) / metersToNauticalMiles;
      final bearing = double.parse(fields[10]);
      final xte = _parseCrossTrackError(fields[1], fields[2]);
      return [
        _boundSingleValue(range, Property.waypointRange, tier: 2),
        _boundSingleValue(bearing, Property.waypointBearing, tier: 2),
        _boundSingleValue(xte, Property.crossTrackError, tier: 2),
      ];
    case 'RMC':
      _validateMinFieldCount(fields, 11);
      _validateValidityIndicator(fields, index: 1);
      final lat = _parseLatitude(fields[2], fields[3]);
      final long = _parseLongitude(fields[4], fields[5]);
      if (fields[0].length < 6) {
        throw FormatException('Time field too short: ${fields[0]}');
      }
      final hour = int.parse(fields[0].substring(0, 2));
      final minute = int.parse(fields[0].substring(2, 4));
      final second = int.parse(fields[0].substring(4, 6));
      if (fields[8].length != 6) {
        throw FormatException('Date field not 6 characters: ${fields[0]}');
      }
      final day = int.parse(fields[8].substring(0, 2));
      final month = int.parse(fields[8].substring(2, 4));
      final year = 2000 + int.parse(fields[8].substring(4, 6));
      final dt = DateTime.utc(year, month, day, hour, minute, second);
      var ret = <BoundValue?>[
        _boundDoubleValue(lat, long, Property.gpsPosition, tier: 3),
        _boundSingleValue(dt, Property.utcTime, tier: 2),
      ];
      ret.add(_parseSingleValue(fields[6], Property.speedOverGround,
          divisor: metersPerSecondToKnots, tier: 2));
      ret.add(_parseSingleValue(fields[7], Property.courseOverGround, tier: 2));
      if (fields[9].isNotEmpty) {
        final variation = _parseVariation(fields[9], fields[10]);
        ret.add(_boundSingleValue(variation, Property.variation, tier: 2));
      }
      return ret.whereNotNull().toList();
    case 'RSA':
      _validateFieldCount(fields, 4);
      _validateValidityIndicator(fields, index: 1);
      return [_parseSingleValue(fields[0], Property.rudderAngle)]
          .whereNotNull()
          .toList();
    case 'VDR':
      _validateFieldCount(fields, 6);
      _validateFieldValue(fields, index: 1, expected: 'T');
      _validateFieldValue(fields, index: 5, expected: 'N');
      return [
        _parseSingleValue(fields[0], Property.currentSet),
        _parseSingleValue(fields[4], Property.currentDrift,
            divisor: metersPerSecondToKnots)
      ].whereNotNull().toList();
    case 'VHW':
      _validateMinFieldCount(fields, 8);
      _validateFieldValue(fields, index: 7, expected: 'K');
      return [
        // Need to convert from kmph (sigh).
        _parseSingleValue(fields[6], Property.speedThroughWater, divisor: 3.6)
      ].whereNotNull().toList();
    case 'VLW':
      _validateMinFieldCount(fields, 4);
      _validateFieldValue(fields, index: 1, expected: 'N');
      _validateFieldValue(fields, index: 3, expected: 'N');
      return [
        _parseSingleValue(fields[0], Property.distanceTotal,
            divisor: metersToNauticalMiles),
        _parseSingleValue(fields[2], Property.distanceTrip,
            divisor: metersToNauticalMiles)
      ].whereNotNull().toList();
    case 'VTG':
      _validateMinFieldCount(fields, 8);
      _validateFieldValue(fields, index: 1, expected: 'T');
      _validateFieldValue(fields, index: 7, expected: 'K');
      return [
        _parseSingleValue(fields[0], Property.courseOverGround),
        // Need to convert from kmph (sigh).
        _parseSingleValue(fields[6], Property.speedOverGround, divisor: 3.6)
      ].whereNotNull().toList();
    case 'XDR':
      _validateMinFieldCount(fields, 4);
      final List<BoundValue> values = [];
      for (int i = 0; i < fields.length - 3; i += 4) {
        values.addAll(_parseXdrMeasurement(fields, i));
      }
      return values;
    case 'XTE':
      _validateMinFieldCount(fields, 5);
      _validateValidityIndicator(fields, index: 0);
      _validateValidityIndicator(fields, index: 1);
      _validateFieldValue(fields, index: 4, expected: 'N');
      final xte = _parseCrossTrackError(fields[2], fields[3]);
      return [
        _boundSingleValue(xte, Property.crossTrackError),
      ];
    case 'ZDA':
      _validateFieldCount(fields, 6);
      if (fields[0].length < 6) {
        throw FormatException('Time field too short: ${fields[0]}');
      }
      final hour = int.parse(fields[0].substring(0, 2));
      final minute = int.parse(fields[0].substring(2, 4));
      final second = int.parse(fields[0].substring(4, 6));
      final day = int.parse(fields[1]);
      final month = int.parse(fields[2]);
      final year = int.parse(fields[3]);
      final dt = DateTime.utc(year, month, day, hour, minute, second);
      return [_boundSingleValue(dt, Property.utcTime)];
    default:
      throw UnsupportedMessageException();
  }
}

// Parse a BoundValue<SingleValue<double>> from the supplied input, returning
// null if the input was empty and throwing a FormatException if it was not a
// valid number. Optionally divides the parsed input by the supplied divisor.
BoundValue<SingleValue<double>>? _parseSingleValue(
    String input, Property property,
    {double? divisor, int tier = 1}) {
  if (input.isEmpty) {
    return null;
  }
  double number = double.parse(input);
  if (divisor != null) {
    number = number / divisor;
  }
  return _boundSingleValue(number, property, tier: tier);
}

// Created a BoundValue<SingleValue<double>> from the supplied input.
BoundValue<SingleValue<T>> _boundSingleValue<T>(T number, Property property,
    {int tier = 1}) {
  return BoundValue(Source.network, property, SingleValue(number), tier: tier);
}

// Created a BoundValue<DoubleValue<double>> from the supplied input.
BoundValue<DoubleValue<double>> _boundDoubleValue(
    double first, double second, Property property,
    {int tier = 1}) {
  return BoundValue(Source.network, property, DoubleValue(first, second),
      tier: tier);
}

/// Validates fields contains the expected number of entries.
void _validateFieldCount(List<String> fields, int expectedCount) {
  if (fields.length != expectedCount) {
    throw FormatException(
        'Expected $expectedCount fields, found ${fields.length}');
  }
}

/// Validates fields contains at least the expected number of entries.
void _validateMinFieldCount(List<String> fields, int minimumCount) {
  if (fields.length < minimumCount) {
    throw FormatException(
        'Expected at least $minimumCount fields, found ${fields.length}');
  }
}

/// Validates a field contains the supplied value.
void _validateFieldValue(List<String> fields,
    {required int index, required String expected, String? message}) {
  if (fields[index] != expected) {
    throw FormatException(
        message ?? 'Expected $expected in field $index, got ${fields[index]}');
  }
}

/// Validates a validity indicator fields is set to 'A'.
void _validateValidityIndicator(fields, {required index}) {
  _validateFieldValue(fields,
      index: index, expected: 'A', message: 'Data marked invalid');
}

/// Parses a decimal encoded latitude and direction indicator.
double _parseLatitude(String valueString, String direction) {
  if (valueString.length < 7) {
    throw const FormatException('Latitude value wrong length');
  }
  final value = double.parse(valueString.substring(0, 2)) +
      (double.parse(valueString.substring(2)) / 60.0);
  switch (direction) {
    case 'N':
      return value;
    case 'S':
      return -value;
    default:
      throw FormatException('Invalid longitude direction $direction');
  }
}

/// Parses a decimal encoded latitude and direction indicator.
double _parseLongitude(String valueString, String direction) {
  if (valueString.length < 8) {
    throw const FormatException('Longitude value wrong length');
  }
  final value = double.parse(valueString.substring(0, 3)) +
      (double.parse(valueString.substring(3)) / 60.0);
  switch (direction) {
    case 'E':
      return value;
    case 'W':
      return -value;
    default:
      throw FormatException('Invalid longitude direction $direction');
  }
}

/// Parses a decimal encoded latitude and direction indicator.
double _parseCrossTrackError(String valueString, String direction) {
  if (valueString.isEmpty) {
    throw const FormatException('Offset not populated');
  }
  final meters = double.parse(valueString) / metersToNauticalMiles;
  switch (direction) {
    case 'L':
      return -meters;
    case 'R':
      return meters;
    default:
      throw FormatException('Invalid XTE direction $direction');
  }
}

/// Parses a variation magniture and sign, returning a positive value for West.
double _parseVariation(String valueString, String direction) {
  if (valueString.isEmpty) {
    throw const FormatException('Varation not populated');
  }
  final value = double.parse(valueString);
  switch (direction) {
    case 'E':
      return -value;
    case 'W':
      return value;
    default:
      throw FormatException('Invalid varation direction $direction');
  }
}

/// Parses a single transducer measurement, ignoring unknown properties.
List<BoundValue> _parseXdrMeasurement(List<String> fields, int startIndex) {
  switch ('${fields[startIndex]}-${fields[startIndex + 3].toLowerCase()}') {
    case 'A-pitch':
      _validateFieldValue(fields, index: startIndex + 2, expected: 'D');
      final value = double.parse(fields[startIndex + 1]);
      return [_boundSingleValue(value, Property.pitch)];
    case 'A-roll':
      _validateFieldValue(fields, index: startIndex + 2, expected: 'D');
      final value = double.parse(fields[startIndex + 1]);
      return [_boundSingleValue(value, Property.roll)];
    case 'P-baro':
    case 'P-barometer':
      final dataType = fields[startIndex + 2];
      var value = double.parse(fields[startIndex + 1]);
      if (dataType == 'P') {
        // Already in pascals
      } else if (dataType == 'B') {
        value *= barToPascals;
      } else {
        throw FormatException('Invalid pressure datatype: $dataType');
      }
      return [_boundSingleValue(value, Property.pressure, tier: 2)];
    case 'C-air':
      _validateFieldValue(fields, index: startIndex + 2, expected: 'C');
      final value = double.parse(fields[startIndex + 1]);
      return [_boundSingleValue(value, Property.airTemperature, tier: 2)];
    case 'H-air':
      _validateFieldValue(fields, index: startIndex + 2, expected: 'P');
      final value = double.parse(fields[startIndex + 1]);
      return [_boundSingleValue(value, Property.relativeHumidity, tier: 2)];
    case 'L-FUEL_0':
      _validateFieldValue(fields, index: startIndex + 2, expected: 'P');
      final value = double.parse(fields[startIndex + 1]);
      return [_boundSingleValue(value, Property.fuel0, tier: 2)];
    default:
      return [];
  }
}
