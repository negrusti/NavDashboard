// Copyright Jody M Sankey 2023
// This software may be modified and distributed under the terms
// of the MIT license. See the LICENCE.md file for details.

import 'dart:typed_data';

import 'package:nmea_dashboard/state/common.dart';
import 'package:nmea_dashboard/state/nmea.dart';
import 'package:nmea_dashboard/state/settings.dart';
import 'package:nmea_dashboard/state/values.dart';
import 'package:test/test.dart';

import 'utils.dart';

BoundValue<SingleValue<T>> _boundSingleValue<T>(T data, Property property,
    {int tier = 1}) {
  return BoundValue(Source.network, property, SingleValue(data), tier: tier);
}

BoundValue<DoubleValue<T>> _boundDoubleValue<T>(
    T first, T second, Property property,
    {int tier = 1}) {
  return BoundValue(Source.network, property, DoubleValue(first, second),
      tier: tier);
}

BoundValue<StringValue> _boundStringValue(String data, Property property,
    {int tier = 1}) {
  return BoundValue(Source.network, property, StringValue(data), tier: tier);
}

Uint8List _makeNmea2000Packet(int pgn, List<int> payload,
    {int source = 0x23,
    int destination = 0xFF,
    int priority = 3,
    int timestampMs = 0}) {
  final bytes = Uint8List(payload.length + 16);
  final data = ByteData.sublistView(bytes);
  data.setUint64(0, timestampMs, Endian.little);
  bytes[8] = source;
  bytes[9] = destination;
  bytes[10] = priority;
  data.setUint32(11, pgn, Endian.little);
  bytes[15] = payload.length;
  bytes.setRange(16, bytes.length, payload);
  return bytes;
}

List<int> _u16(int value) {
  final bytes = Uint8List(2);
  ByteData.sublistView(bytes).setUint16(0, value, Endian.little);
  return bytes;
}

List<int> _i16(int value) {
  final bytes = Uint8List(2);
  ByteData.sublistView(bytes).setInt16(0, value, Endian.little);
  return bytes;
}

List<int> _u32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
  return bytes;
}

List<int> _i32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setInt32(0, value, Endian.little);
  return bytes;
}

List<int> _i64(int value) {
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setInt64(0, value, Endian.little);
  return bytes;
}

List<int> _lau(String value) {
  final bytes = value.codeUnits;
  return [bytes.length + 2, 1, ...bytes, 0];
}

void main() {
  test('should fail invalid checksum', () {
    expect(() => NmeaParser(true).parseString(r'$YDDPT,18.56,-1.61,140.0,*00'),
        throwsFormatException);
  });

  test('should accept missing checksum iff checksum not required', () {
    expect(
        NmeaParser(false).parseString(r'$YDDPT,18.56,-1.61,140.0'),
        BoundValueListMatches([
          _boundSingleValue(16.95, Property.depthWithOffset),
          _boundSingleValue(18.56, Property.depthUncalibrated),
        ]));
    expect(() => NmeaParser(true).parseString(r'$YDDPT,18.56,-1.61,140.0'),
        throwsFormatException);
  });

  test('should skip ignored message', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDGSV,5,1,18,65,75,281,19,10,69,352,25,88,65,332,27,87,61,137,15*7C'),
        BoundValueListMatches([]));
  });

  test('should increment message counts', () {
    final parser = NmeaParser(true);
    expect(parser.ignoredCounts.total, 0);
    expect(parser.unsupportedCounts.total, 0);
    expect(parser.successCounts.total, 0);
    parser.parseString(r'$YDDPT,18.56,-1.61,140.0,*67');
    expect(parser.successCounts.total, 1);
    parser.parseString(
        r'$YDGSV,5,1,18,65,75,281,19,10,69,352,25,88,65,332,27,87,61,137,15*7C');
    expect(parser.ignoredCounts.total, 1);
    parser.logAndClearCounts();
    expect(parser.ignoredCounts.total, 0);
    expect(parser.successCounts.total, 0);
  });

  test('should parse BWR', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDBWR,203514.60,3740.2436,N,12222.6994,W,148.0,T,134.9,M,0.11,N,0,A*4C'),
        BoundValueListMatches([
          _boundSingleValue(203.71993, Property.waypointRange),
          _boundSingleValue(148.0, Property.waypointBearing),
        ]));
  });

  test('should support DBT', () {
    expect(
        NmeaParser(true).parseString(r'$SDDBT,58.10,f,17.71,M,,F*24'),
        BoundValueListMatches([
          _boundSingleValue(17.71, Property.depthUncalibrated, tier: 2),
        ]));
  });

  test('should parse DPT', () {
    expect(
        NmeaParser(true).parseString(r'$YDDPT,18.56,-1.61,140.0,*67'),
        BoundValueListMatches([
          _boundSingleValue(16.95, Property.depthWithOffset),
          _boundSingleValue(18.56, Property.depthUncalibrated),
        ]));
  });

  test('should parse DPT without data', () {
    final parser = NmeaParser(true);
    expect(() => parser.parseString(r'$IIDPT,,0.0*6E'), throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.parseString(r'$IIDPT,,0.0*6E'), BoundValueListMatches([]));
    expect(parser.emptyCounts.total, 2);
  });

  test('should parse HDG with variation', () {
    expect(
        NmeaParser(true).parseString(r'$YDHDG,7.3,,,13.1,E*08'),
        BoundValueListMatches([
          _boundSingleValue(-13.1, Property.variation),
          _boundSingleValue(20.4, Property.heading),
        ]));
  });

  test('should parse HDG without variation', () {
    expect(
        NmeaParser(true).parseString(r'$YDHDG,173.8,,,,*59'),
        BoundValueListMatches([
          _boundSingleValue(173.8, Property.headingMag),
        ]));
  });

  test('should parse HDM', () {
    expect(
        NmeaParser(true).parseString(r'$IIHDM,143.3,M*27'),
        BoundValueListMatches([
          _boundSingleValue(143.3, Property.headingMag, tier: 2),
        ]));
  });

  test('should parse GGA with HDOP', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDGGA,170202.60,3749.3097,N,12228.9446,W,1,12,0.86,,M,-29.70,M,,*76'),
        BoundValueListMatches([
          _boundDoubleValue(37.82182833, -122.48241, Property.gpsPosition),
          _boundSingleValue(0.86, Property.gpsHdop),
        ]));
  });

  test('should parse GGA without HDOP', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDGGA,170202.60,3749.3097,N,12228.9446,W,1,12,,,M,-29.70,M,,*66'),
        BoundValueListMatches([
          _boundDoubleValue(37.82183, -122.48241, Property.gpsPosition),
        ]));
  });

  test('should parse GLL', () {
    expect(
        NmeaParser(true)
            .parseString(r'$YDGLL,3748.8322,N,12230.6429,W,171453.24,A,A*7A'),
        BoundValueListMatches([
          _boundDoubleValue(37.81387, -122.51072, Property.gpsPosition,
              tier: 2),
        ]));
  });

  test('should parse MDA with temp and RH', () {
    expect(
        NmeaParser(true)
            .parseString(r'$YDMDA,,I,,B,23.9,C,,C,55.5,,14.4,C,,T,,M,,N,,M*15'),
        BoundValueListMatches([
          _boundSingleValue(23.9, Property.airTemperature),
          _boundSingleValue(55.5, Property.relativeHumidity),
          _boundSingleValue(14.4, Property.dewPoint)
        ]));
  });

  test('should parse MDA with pressure', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDMDA,29.8902,I,1.0122,B,,C,,C,,,,C,,T,,M,,N,,M*3F'),
        BoundValueListMatches([
          _boundSingleValue(101220.0, Property.pressure),
        ]));
  });

  test('should parse MDA with pressure, water temp, and TWD', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDMDA,30.1767,I,1.0219,B,,C,20.4,C,,,,C,315.6,T,302.6,M,9.3,N,4.8,M*20'),
        BoundValueListMatches([
          _boundSingleValue(102190.0, Property.pressure),
          _boundSingleValue(20.4, Property.waterTemperature),
          _boundSingleValue(315.6, Property.trueWindDirection, tier: 2)
        ]));
  });

  test('should parse MWD with direction', () {
    expect(
        NmeaParser(true).parseString(r'$YDMWD,154.7,T,141.8,M,12.1,N,6.2,M*64'),
        BoundValueListMatches([
          _boundSingleValue(154.7, Property.trueWindDirection),
          _boundSingleValue(6.2, Property.trueWindSpeed, tier: 2),
        ]));
  });

  test('should parse MWD with missing direction', () {
    expect(
        NmeaParser(true).parseString(r'$YDMWD,,T,,M,12.1,N,6.2,M*6F'),
        BoundValueListMatches([
          _boundSingleValue(6.2, Property.trueWindSpeed, tier: 2),
        ]));
  });

  test('should parse MWV with apparent in m/s', () {
    expect(
        NmeaParser(true).parseString(r'$YDMWV,354.9,R,0.9,M,A*21'),
        BoundValueListMatches([
          _boundSingleValue(354.9, Property.apparentWindAngle),
          _boundSingleValue(0.9, Property.apparentWindSpeed),
        ]));
  });

  test('should parse MWV with apparent in kmph', () {
    expect(
        NmeaParser(true).parseString(r'$YDMWV,354.9,R,3.24,K,A*1B'),
        BoundValueListMatches([
          _boundSingleValue(354.9, Property.apparentWindAngle),
          _boundSingleValue(0.9, Property.apparentWindSpeed),
        ]));
  });

  test('should parse MWV with true in m/s', () {
    expect(
        NmeaParser(true).parseString(r'$YDMWV,352.5,T,0.6,M,A*22'),
        BoundValueListMatches([
          _boundSingleValue(352.5, Property.trueWindAngle),
          _boundSingleValue(0.6, Property.trueWindSpeed),
        ]));
  });

  test('should parse MWV with true in knots', () {
    expect(
        NmeaParser(true).parseString(r'$YDMWV,352.5,T,20.0,N,A*15'),
        BoundValueListMatches([
          _boundSingleValue(352.5, Property.trueWindAngle),
          _boundSingleValue(10.28891, Property.trueWindSpeed),
        ]));
  });

  test('should parse MTW', () {
    expect(
        NmeaParser(true).parseString(r'$YDMTW,20.4,C*08'),
        BoundValueListMatches([
          _boundSingleValue(20.4, Property.waterTemperature, tier: 2),
        ]));
  });

  test('should parse RMB', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDRMB,A,0.100,L,0,0,3740.2436,N,12222.6994,W,0.11,148.0,0.0,V,A*4F'),
        BoundValueListMatches([
          _boundSingleValue(203.71993, Property.waypointRange, tier: 2),
          _boundSingleValue(148.0, Property.waypointBearing, tier: 2),
          _boundSingleValue(-185.1999, Property.crossTrackError, tier: 2),
        ]));
  });

  test('should parse RMC', () {
    expect(
        NmeaParser(true).parseString(
            r'$GPRMC,230830,A,1755.039,N,06443.653,W,5.50,357.0,250803,3.0,W*4B'),
        BoundValueListMatches([
          _boundDoubleValue(17.917317, -64.72755, Property.gpsPosition,
              tier: 3),
          _boundSingleValue(
              DateTime.utc(2003, 08, 25, 23, 08, 30), Property.utcTime,
              tier: 2),
          _boundSingleValue(2.82945, Property.speedOverGround, tier: 2),
          _boundSingleValue(357.0, Property.courseOverGround, tier: 2),
          _boundSingleValue(3.0, Property.variation, tier: 2),
        ]));
  });

  test('should parse RSA', () {
    expect(
        NmeaParser(true).parseString(r'$YDRSA,2.8,A,,V*6E'),
        BoundValueListMatches([
          _boundSingleValue(2.8, Property.rudderAngle),
        ]));
  });
  test('should parse VDR', () {
    expect(
        NmeaParser(true).parseString(r'$YDVDR,88.4,T,75.3,M,1.6,N*26'),
        BoundValueListMatches([
          _boundSingleValue(88.4, Property.currentSet),
          _boundSingleValue(0.82311, Property.currentDrift),
        ]));
  });
  test('should parse VHW', () {
    expect(
        NmeaParser(true).parseString(r'$YDVHW,339.8,T,326.7,M,1.3,N,2.4,K,*61'),
        BoundValueListMatches([
          _boundSingleValue(0.6667, Property.speedThroughWater),
        ]));
  });

  test('should parse VHW without data', () {
    final parser = NmeaParser(true);
    expect(() => parser.parseString(r'$VWVHW,,T,,M,,N,,K*54'),
        throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.parseString(r'$VWVHW,,T,,M,,N,,K*54'),
        BoundValueListMatches([]));
    expect(parser.emptyCounts.total, 2);
  });

  test('should parse VLW', () {
    expect(
        NmeaParser(true).parseString(r'$YDVLW,363.135,N,181.393,N*50'),
        BoundValueListMatches([
          _boundSingleValue(672525.7752, Property.distanceTotal),
          _boundSingleValue(335939.7137, Property.distanceTrip),
        ]));
  });

  test('should parse VTG', () {
    expect(
        NmeaParser(true)
            .parseString(r'$YDVTG,210.9,T,197.8,M,0.6,N,1.2,K,A*21'),
        BoundValueListMatches([
          _boundSingleValue(210.9, Property.courseOverGround),
          _boundSingleValue(0.33333, Property.speedOverGround),
        ]));
  });

  test('should parse XDR with roll pitch yaw', () {
    expect(
        NmeaParser(true).parseString(
            r'$YDXDR,A,-44.75,D,Yaw,A,1.00,D,Pitch,A,0.25,D,Roll*65'),
        BoundValueListMatches([
          _boundSingleValue(1.0, Property.pitch),
          _boundSingleValue(0.25, Property.roll),
        ]));
  });

  test('should parse XDR with pressure', () {
    expect(
        NmeaParser(true).parseString(r'$YDXDR,P,101080,P,Baro*65'),
        BoundValueListMatches([
          _boundSingleValue(101080.0, Property.pressure, tier: 2),
        ]));
  });

  test('should parse XDR with temperature and RH', () {
    expect(
        NmeaParser(true).parseString(r'$YDXDR,C,23.6,C,Air,H,57.9,P,Air*47'),
        BoundValueListMatches([
          _boundSingleValue(23.6, Property.airTemperature, tier: 2),
          _boundSingleValue(57.9, Property.relativeHumidity, tier: 2),
        ]));
  });

  test('should parse XDR with spelled out barometer and vague temperature', () {
    expect(
        NmeaParser(true).parseString(
            r'$WIXDR,P,1.0282,B,barometer,C,19.7,C,temperature*5D'),
        BoundValueListMatches([
          _boundSingleValue(102820.0, Property.pressure, tier: 2),
        ]));
  });

  test('should parse XTE', () {
    expect(
        NmeaParser(true).parseString(r'$YDXTE,A,A,1.000,R,N,A*26'),
        BoundValueListMatches([
          _boundSingleValue(1851.9993, Property.crossTrackError),
        ]));
  });

  test('should parse ZDA', () {
    expect(
        NmeaParser(true).parseString(r'$YDZDA,171541.56,15,10,2022,,*6F'),
        BoundValueListMatches([
          _boundSingleValue(
              DateTime.utc(2022, 10, 15, 17, 15, 41), Property.utcTime),
        ]));
  });

  test('should reject NMEA2000 packet shorter than header', () {
    expect(
        () => NmeaParser(true, NetworkProtocol.nmea2000Assembled)
            .parsePacket(Uint8List(15)),
        throwsFormatException);
  });

  test('should reject NMEA2000 packet with zero payload length', () {
    final packet = _makeNmea2000Packet(127251, []);
    expect(
        () => NmeaParser(true, NetworkProtocol.nmea2000Assembled)
            .parsePacket(packet),
        throwsFormatException);
  });

  test(
      'should reject NMEA2000 packet whose declared payload length does not '
      'match its size', () {
    final packet = _makeNmea2000Packet(
        127251, [0x04, ..._i32(-5585054), 0xFF, 0xFF, 0xFF]);
    packet[15] = 12;
    expect(
        () => NmeaParser(true, NetworkProtocol.nmea2000Assembled)
            .parsePacket(packet),
        throwsFormatException);
  });

  test('should only throw on first NMEA2000 packet with unsupported PGN', () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(
        60928, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.parsePacket(packet), BoundValueListMatches([]));
    expect(parser.unsupportedCounts.total, 2);
    expect(parser.successCounts.total, 0);
  });

  test('should parse NMEA2000 rate of turn packet', () {
    final packet = _makeNmea2000Packet(
        127251, [0x04, ..._i32(-5585054), 0xFF, 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-10.0, Property.rateOfTurn),
        ]));
  });

  test('should parse NMEA2000 vessel heading packet', () {
    final packet = _makeNmea2000Packet(127250, [
      0x01,
      ..._u16(15708),
      ..._i16(0x7FFF),
      ..._i16(-349),
      0x00,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-1.9996, Property.variation),
          _boundSingleValue(90.0002, Property.heading),
        ]));
  });

  test('should parse NMEA2000 magnetic vessel heading packet', () {
    final packet = _makeNmea2000Packet(127250, [
      0x01,
      ..._u16(15708),
      ..._i16(0x7FFF),
      ..._i16(-349),
      0x01,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-1.9996, Property.variation),
          _boundSingleValue(90.0002, Property.headingMag),
        ]));
  });

  test(
      'should not parse heading from NMEA2000 vessel heading packet with '
      'unknown reference', () {
    final packet = _makeNmea2000Packet(127250, [
      0x01,
      ..._u16(15708),
      ..._i16(0x7FFF),
      ..._i16(-349),
      0x02,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-1.9996, Property.variation),
        ]));
  });

  test('should parse NMEA2000 vessel heading packet with unavailable heading',
      () {
    final packet = _makeNmea2000Packet(127250, [
      0x01,
      0xFF,
      0xFF,
      ..._i16(0x7FFF),
      ..._i16(-349),
      0x00,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-1.9996, Property.variation),
        ]));
  });

  test('should parse NMEA2000 rudder packet within valid range', () {
    final packet = _makeNmea2000Packet(127245, [
      0x01,
      0x00,
      ..._i16(0),
      ..._i16(-5236),
      0xFF,
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-30.0001, Property.rudderAngle),
        ]));
  });

  test('should ignore NMEA2000 rudder packet outside valid range', () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(127245, [
      0x01,
      0x00,
      ..._i16(0),
      ..._i16(17453),
      0xFF,
      0xFF,
    ]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.parsePacket(packet), BoundValueListMatches([]));
    expect(parser.emptyCounts.total, 2);
  });

  test('should parse NMEA2000 rudder position rather than angle order', () {
    final packet = _makeNmea2000Packet(127245, [
      0x01,
      0x00,
      ..._i16(5236),
      ..._i16(-2618),
      0xFF,
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-15.0001, Property.rudderAngle),
        ]));
  });

  test('should parse NMEA2000 magnetic variation packet', () {
    final packet = _makeNmea2000Packet(
        127258, [0xFF, 0xFF, 0xFF, 0xFF, ..._i16(-349), 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-1.9996, Property.variation, tier: 2),
        ]));
  }, skip: 'Implementation pulls from wrong byte offset according to CAN boat');

  test('should parse NMEA2000 fuel level packet', () {
    final packet = _makeNmea2000Packet(
        127505, [0x00, ..._i16(12500), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(50.0, Property.fuel0, tier: 2),
        ]));
  });

  test('should not parse NMEA2000 fluid level packet for unsupported tank',
      () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(
        127505, [0x50, ..._i16(12500), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.successCounts.total, 0);
  });

  test('should reject NMEA2000 fluid level packet outside valid range', () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(
        127505, [0x00, ..._i16(30000), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.successCounts.total, 0);
  }, skip: 'Implementation does not validate percentage between 0 and 100');

  test('should parse NMEA2000 speed packet', () {
    final packet = _makeNmea2000Packet(
        128259, [0xFF, ..._u16(320), 0xFF, 0xFF, ..._u16(510), 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(3.2, Property.speedThroughWater),
          _boundSingleValue(5.1, Property.speedOverGround),
        ]));
  }, skip: 'Implementation does not support SOG from 128259');

  test('should parse NMEA2000 speed packet with unavailable ground speed', () {
    final packet = _makeNmea2000Packet(
        128259, [0xFF, ..._u16(320), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(3.2, Property.speedThroughWater),
        ]));
  });

  test('should parse NMEA2000 speed packet with unavailable water speed', () {
    final packet = _makeNmea2000Packet(
        128259, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, ..._u16(510), 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(5.1, Property.speedOverGround),
        ]));
  }, skip: 'Implementation does not support SOG from 128259');

  test('should parse NMEA2000 COG/SOG packet', () {
    final packet = _makeNmea2000Packet(129026, [
      0x02,
      0x00,
      ..._u16(47124),
      ..._u16(520),
      0xFF,
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(270.0006, Property.courseOverGround, tier: 2),
          _boundSingleValue(5.2, Property.speedOverGround, tier: 2),
        ]));
  });

  test('should parse real NMEA2000 Raymarine COG/SOG payload', () {
    final packet = _makeNmea2000Packet(129026, [
      0xFF,
      0xFC,
      0x76,
      0xDE,
      0x01,
      0x00,
      0xFF,
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(326.2995, Property.courseOverGround, tier: 2),
          _boundSingleValue(0.01, Property.speedOverGround, tier: 2),
        ]));
  });

  test('should not parse COG from magnetic referenced NMEA2000 COG/SOG packet',
      () {
    final packet = _makeNmea2000Packet(
        129026, [0x02, 0x01, ..._u16(47124), ..._u16(520), 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(5.2, Property.speedOverGround, tier: 2),
        ]));
  });

  test('should parse NMEA2000 water depth packet', () {
    final packet = _makeNmea2000Packet(128267, [
      0x03,
      ..._u32(1234),
      ..._i16(-500),
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(12.34, Property.depthUncalibrated),
          _boundSingleValue(11.84, Property.depthWithOffset),
        ]));
  });

  test('should parse NMEA2000 water depth packet with unavailable offset', () {
    final packet = _makeNmea2000Packet(128267, [
      0x03,
      ..._u32(1234),
      0xFF,
      0x7F,
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(12.34, Property.depthUncalibrated),
          _boundSingleValue(12.34, Property.depthWithOffset),
        ]));
  });

  test('should not parse NMEA2000 water depth packet with unavailable depth',
      () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(
        128267, [0x03, 0xFF, 0xFF, 0xFF, 0xFF, ..._i16(-500), 0xFF]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.successCounts.total, 0);
  });

  test('should parse NMEA2000 distance log packet', () {
    final packet = _makeNmea2000Packet(128275, [
      0xFF, 0xFF, // date
      0xFF, 0xFF, 0xFF, 0xFF, // time
      ..._u32(123456), // log
      ..._u32(6543), // trip
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(123456.0, Property.distanceTotal),
          _boundSingleValue(6543.0, Property.distanceTrip),
        ]));
  }, skip: 'Implementation uses wrong scaling according to CAN boat');

  test('should parse NMEA2000 distance log packet with unavailable trip', () {
    final packet = _makeNmea2000Packet(128275, [
      0xFF, 0xFF, // date
      0xFF, 0xFF, 0xFF, 0xFF, // time
      ..._u32(123456), // log
      0xFF, 0xFF, 0xFF, 0xFF, // trip
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(123456.0, Property.distanceTotal),
        ]));
  }, skip: 'Implementation uses wrong scaling according to CAN boat');

  test('should parse NMEA2000 environmental parameters water temperature', () {
    final packet = _makeNmea2000Packet(130310, [
      0x01,
      ..._u16(29355),
      ..._u16(29815),
      ..._u16(1013),
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(20.4, Property.waterTemperature),
          _boundSingleValue(25.0, Property.airTemperature),
          _boundSingleValue(101300.0, Property.pressure),
        ]));
  });

  test(
      'should reject NMEA2000 environmental parameters packet with wrong '
      'length', () {
    final packet = _makeNmea2000Packet(
        130310, [0x01, ..._u16(29355), ..._u16(29815), ..._u16(1013)]);
    expect(
        () => NmeaParser(true, NetworkProtocol.nmea2000Assembled)
            .parsePacket(packet),
        throwsFormatException);
  });

  test('should parse NMEA2000 rapid position packet', () {
    final packet = _makeNmea2000Packet(129025, [
      ..._i32(375000000),
      ..._i32(-1225000000),
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundDoubleValue(37.5, -122.5, Property.gpsPosition, tier: 2),
        ]));
  });

  test('should parse real NMEA2000 Raymarine rapid position payload', () {
    final packet = _makeNmea2000Packet(129025, [
      0x60,
      0x6E,
      0x9E,
      0x08,
      0x00,
      0x72,
      0xB7,
      0xDB,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundDoubleValue(14.4600672, -60.873472, Property.gpsPosition,
          tier: 2),
        ]));
  });

  test(
      'should not parse NMEA2000 rapid position packet with unavailable '
      'latitude', () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(
        129025, [..._i32(0x7FFFFFFF), ..._i32(-1225000000)]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.successCounts.total, 0);
  });

  test('should parse NMEA2000 GNSS position packet', () {
    final packet = _makeNmea2000Packet(129029, [
      0xFF, // SID
      ..._u16(20000), // date
      ..._u32(452960000), // time
      ..._i64(375000000000000000), // latitude
      ..._i64(-1225000000000000000), // longitude
      ...List.filled(8, 0xFF), // altitude
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundDoubleValue(37.5, -122.5, Property.gpsPosition),
          _boundSingleValue(
              DateTime.utc(2024, 10, 4, 12, 34, 56), Property.utcTime),
        ]));
  }, skip: 'Implementation fails due to an integer overflow bug in _readInt64');

  test('should parse NMEA2000 GNSS position packet including HDOP', () {
    final packet = _makeNmea2000Packet(129029, [
      0xFF, // SID
      ..._u16(20000), // date
      ..._u32(452960000), // time
      ..._i64(375000000000000000), // latitude
      ..._i64(-1225000000000000000), // longitude
      ...List.filled(8, 0xFF), // altitude
      0x12, // GNSS type and method
      0xFC, // integrity and reserved
      0x0A, // number of SVs
      ..._i16(123), // HDOP
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundDoubleValue(37.5, -122.5, Property.gpsPosition),
          _boundSingleValue(
              DateTime.utc(2024, 10, 4, 12, 34, 56), Property.utcTime),
          _boundSingleValue(1.23, Property.gpsHdop),
        ]));
  }, skip: 'Implementation fails due to an integer overflow bug in _readInt64');

  test('should parse NMEA2000 cross track error packet', () {
    final packet = _makeNmea2000Packet(
        129283, [0xFF, 0x00, ..._i32(-12345), 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-123.45, Property.crossTrackError),
        ]));

  }, skip: 'Implementation pulls from wrong byte offset according to CAN boat');

  test('should parse NMEA2000 navigation data packet', () {
    final packet = _makeNmea2000Packet(129284, [
      0xFF, // SID
      ..._u32(123456), // distance to waypoint
      0x00, // reference and flags
      0xFF, 0xFF, 0xFF, 0xFF, // ETA time
      0xFF, 0xFF, // ETA date
      0xFF, 0xFF, // bearing, origin to destination
      ..._u16(7854), // bearing, position to destination
      ...List.filled(8, 0xFF), // waypoint numbers
      ...List.filled(8, 0xFF), // destination latitude and longitude
      0xFF, 0xFF, // waypoint closing velocity
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(1234.56, Property.waypointRange, tier: 2),
          _boundSingleValue(45.0001, Property.waypointBearing, tier: 2),
        ]));
  });

  test(
      'should not parse bearing from magnetic referenced NMEA2000 navigation '
      'data packet', () {
    final packet = _makeNmea2000Packet(129284, [
      0xFF, // SID
      ..._u32(123456), // distance to waypoint
      0x01, // reference and flags
      0xFF, 0xFF, 0xFF, 0xFF, // ETA time
      0xFF, 0xFF, // ETA date
      0xFF, 0xFF, // bearing, origin to destination
      ..._u16(7854), // bearing, position to destination
      ...List.filled(8, 0xFF), // waypoint numbers
      ...List.filled(8, 0xFF), // destination latitude and longitude
      0xFF, 0xFF, // waypoint closing velocity
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(1234.56, Property.waypointRange, tier: 2),
        ]));
  });

  test('should parse NMEA2000 set and drift packet', () {
    final packet = _makeNmea2000Packet(
        129291, [0xFF, 0x00, ..._u16(7854), ..._u16(250), 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(45.0001, Property.currentSet),
          _boundSingleValue(2.5, Property.currentDrift),
        ]));
  });

  test(
      'should not parse set from magnetic referenced NMEA2000 set and drift '
      'packet', () {
    final packet = _makeNmea2000Packet(
        129291, [0xFF, 0x01, ..._u16(7854), ..._u16(250), 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(2.5, Property.currentDrift),
        ]));
  });

  test('should parse NMEA2000 date/time packet', () {
    final packet = _makeNmea2000Packet(129033, [
      ..._u16(20000),
      ..._u32(452960000),
      0xFF,
      0xFF,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(
              DateTime.utc(2024, 10, 4, 12, 34, 56), Property.utcTime),
        ]));
  });

  test('should not parse NMEA2000 date/time packet with unavailable date', () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(
        129033, [0xFF, 0xFF, ..._u32(452960000), 0xFF, 0xFF]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.successCounts.total, 0);
  });

  test('should parse NMEA2000 route waypoint name packet', () {
    final packet = _makeNmea2000Packet(129285, [
      ..._u16(0),
      ..._u16(2),
      ..._u16(1),
      ..._u16(99),
      0,
      ..._lau('Route'),
      0xFF,
      ..._u16(10),
      ..._lau('Origin'),
      ..._i32(144600672),
      ..._i32(-608734720),
      ..._u16(11),
      ..._lau('Destination'),
      ..._i32(144700000),
      ..._i32(-608800000),
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundStringValue('Destination', Property.waypointName),
        ]));
  });

  test('should parse NMEA2000 VHF channel packet', () {
    final packet = _makeNmea2000Packet(129799, [
      0x00,
      0x42,
      0xEF,
      0x00,
      0x00,
      0x42,
      0xEF,
      0x00,
      0x31,
      0x36,
      0x00,
      0x00,
      0x00,
      0x00,
      0x19,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(16, Property.vhfChannel),
        ]));
  });

  test('should parse NMEA2000 apparent wind packet', () {
    final packet = _makeNmea2000Packet(130306, [
      0x04,
      ..._u16(1020),
      ..._u16(7854),
      0x02,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(45.0001, Property.apparentWindAngle),
          _boundSingleValue(10.2, Property.apparentWindSpeed),
        ]));
  });

  test('should parse NMEA2000 true ground referenced wind packet', () {
    final packet = _makeNmea2000Packet(130306, [
      0x04,
      ..._u16(1020),
      ..._u16(7854),
      0x00,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(45.0001, Property.trueWindDirection),
          _boundSingleValue(10.2, Property.trueWindSpeed, tier: 2),
        ]));
  });

  test(
      'should parse NMEA2000 boat referenced true wind packet wrapping angle '
      'from bow', () {
    final packet = _makeNmea2000Packet(130306, [
      0x04,
      ..._u16(1020),
      ..._u16(47124),
      0x03,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(-89.9994, Property.trueWindAngle),
          _boundSingleValue(10.2, Property.trueWindSpeed),
        ]));
  }, skip: 'Implementation does not normalize relative angles to +/-180');

  test(
      'should not parse angle from magnetic ground referenced NMEA2000 wind '
      'packet', () {
    final packet = _makeNmea2000Packet(130306, [
      0x04,
      ..._u16(1020),
      ..._u16(7854),
      0x01,
    ]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(10.2, Property.trueWindSpeed, tier: 2),
        ]));
  }, skip: 'Implementation does not support speed when reference is magnetic');

  test('should reject NMEA2000 wind packet with angle outside valid range',
      () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(130306, [
      0x04,
      ..._u16(1020),
      ..._u16(65000),
      0x02,
    ]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.successCounts.total, 0);
  }, skip: 'Implementation does not validate angle between 0 and 360');

  test('should parse NMEA2000 humidity packet', () {
    final packet = _makeNmea2000Packet(
        130313, [0xFF, 0x00, 0x00, ..._i16(12500), 0xFF, 0xFF, 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(50.0, Property.relativeHumidity),
        ]));
  });

  test('should parse NMEA2000 atmospheric pressure packet', () {
    final packet = _makeNmea2000Packet(
        130314, [0xFF, 0x00, 0x00, ..._i32(1013250), 0xFF]);
    expect(
        NmeaParser(true, NetworkProtocol.nmea2000Assembled).parsePacket(packet),
        BoundValueListMatches([
          _boundSingleValue(101325.0, Property.pressure),
        ]));
  });

  test('should not parse NMEA2000 pressure packet for unsupported source', () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final packet = _makeNmea2000Packet(
        130314, [0xFF, 0x00, 0x02, ..._i32(1013250), 0xFF]);
    expect(() => parser.parsePacket(packet), throwsFormatException);
    expect(parser.emptyCounts.total, 1);
    expect(parser.successCounts.total, 0);
  });

  test(
      'should parse NMEA2000 extended temperature packets for each supported '
      'source', () {
    final parser = NmeaParser(true, NetworkProtocol.nmea2000Assembled);
    final waterPacket = _makeNmea2000Packet(
        130316, [0xFF, 0x00, 0x00, 0x1E, 0x79, 0x04, 0xFF, 0xFF]);
    expect(
        parser.parsePacket(waterPacket),
        BoundValueListMatches([
          _boundSingleValue(20.0, Property.waterTemperature),
        ]));
    final airPacket = _makeNmea2000Packet(
        130316, [0xFF, 0x00, 0x01, 0xA6, 0x8C, 0x04, 0xFF, 0xFF]);
    expect(
        parser.parsePacket(airPacket),
        BoundValueListMatches([
          _boundSingleValue(25.0, Property.airTemperature),
        ]));
    final dewPacket = _makeNmea2000Packet(
        130316, [0xFF, 0x00, 0x09, 0x96, 0x65, 0x04, 0xFF, 0xFF]);
    expect(
        parser.parsePacket(dewPacket),
        BoundValueListMatches([
          _boundSingleValue(15.0, Property.dewPoint),
        ]));
  });
}
