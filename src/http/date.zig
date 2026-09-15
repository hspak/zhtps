//! Strict HTTP-date grammar with UTC calendar conversion supplied by zeit.

const std = @import("std");
const zeit = @import("zeit");
const log = std.log.scoped(.http_date);

/// Returns Unix seconds, or null for invalid syntax or calendar dates. Leap
/// seconds map to the following Unix second. `now` resolves RFC 850 years;
/// asserts it lies between 1970 and 9949, inclusive.
pub fn parse(bytes: []const u8, now: u64) ?i64 {
    std.debug.assert(now < (zeit.Time{ .year = 9950 }).instant().unixTimestamp());
    var year: u16 = undefined;
    var month: zeit.Month = undefined;
    var day: u16 = undefined;
    var weekday: zeit.Weekday = undefined;
    var time: zeit.Time = undefined;
    if (bytes.len == 29 and bytes[3] == ',') {
        if (!std.mem.eql(
            u8,
            bytes[3..5],
            ", ",
        ) or bytes[7] != ' ' or
            bytes[11] != ' ' or bytes[16] != ' ' or !std.mem.eql(
            u8,
            bytes[25..],
            " GMT",
        )) return null;
        weekday = parseWeekday(bytes[0..3], false) orelse return null;
        day = number(bytes[5..7]) orelse return null;
        month = parseMonth(bytes[8..11]) orelse return null;
        year = number(bytes[12..16]) orelse return null;
        time = parseTime(bytes[17..25]) orelse return null;
    } else if (bytes.len == 24 and bytes[3] == ' ') {
        if (bytes[7] != ' ' or bytes[10] != ' ' or bytes[19] != ' ') return null;
        weekday = parseWeekday(bytes[0..3], false) orelse return null;
        month = parseMonth(bytes[4..7]) orelse return null;
        day = number(if (bytes[8] == ' ') bytes[9..10] else bytes[8..10]) orelse return null;
        year = number(bytes[20..24]) orelse return null;
        time = parseTime(bytes[11..19]) orelse return null;
    } else {
        const comma = std.mem.indexOfScalar(
            u8,
            bytes,
            ',',
        ) orelse return null;
        weekday = parseWeekday(bytes[0..comma], true) orelse return null;
        const rest = bytes[comma..];
        if (rest.len != 24 or rest[1] != ' ' or rest[4] != '-' or rest[8] != '-' or
            rest[11] != ' ' or !std.mem.eql(
            u8,
            rest[20..],
            " GMT",
        )) return null;
        day = number(rest[2..4]) orelse return null;
        month = parseMonth(rest[5..8]) orelse return null;
        const short_year = number(rest[9..11]) orelse return null;
        time = parseTime(rest[12..20]) orelse return null;
        const current = zeit.instant(.{ .unix_timestamp = @intCast(now) }, &zeit.utc).time();
        const future_year: u16 = @intCast(current.year + 50);
        const future_day = @min(current.day, current.month.lastDay(future_year));
        year = future_year / 100 * 100 + short_year;
        // Compare civil components before calendar validation: 29-Feb-2100
        // can denote valid 29-Feb-2000 after the RFC 850 century adjustment.
        const candidate = [_]u16{
            year,
            @intFromEnum(month),
            day,
            time.hour,
            time.minute,
            time.second,
        };
        const cutoff = [_]u16{
            future_year,
            @intFromEnum(current.month),
            future_day,
            current.hour,
            current.minute,
            current.second,
        };
        if (std.mem.order(
            u16,
            &candidate,
            &cutoff,
        ) == .gt) year -= 100;
    }
    if (year < 1601 or year > 9999 or day < 1 or day > month.lastDay(year)) return null;
    time.year = year;
    time.month = month;
    time.day = @intCast(day);
    const days = zeit.daysFromCivil(.{
        .year = year,
        .month = month,
        .day = time.day,
    });
    if (zeit.weekdayFromDays(days) != weekday) return null;
    return time.instant().unixTimestamp();
}

fn number(bytes: []const u8) ?u16 {
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(
        u16,
        bytes,
        10,
    ) catch null;
}

fn parseMonth(bytes: []const u8) ?zeit.Month {
    inline for (std.meta.tags(zeit.Month)) |month| {
        if (std.mem.eql(
            u8,
            month.shortName(),
            bytes,
        )) return month;
    }
    return null;
}

fn parseWeekday(bytes: []const u8, long: bool) ?zeit.Weekday {
    inline for (std.meta.tags(zeit.Weekday)) |weekday| {
        if (std.mem.eql(
            u8,
            if (long) weekday.name() else weekday.shortName(),
            bytes,
        )) return weekday;
    }
    return null;
}

fn parseTime(bytes: []const u8) ?zeit.Time {
    if (bytes[2] != ':' or bytes[5] != ':') return null;
    const hour = number(bytes[0..2]) orelse return null;
    const minute = number(bytes[3..5]) orelse return null;
    const second = number(bytes[6..8]) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    return .{
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
    };
}

test "HTTP dates accept three formats and reject invalid calendar values" {
    const testing = std.testing;
    const now = 1789096284;
    for ([_][]const u8{
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
    }) |bytes| try testing.expectEqual(@as(?i64, 784111777), parse(bytes, now));
    try testing.expectEqual(@as(?i64, 0), parse("Thu, 01 Jan 1970 00:00:00 GMT", now));
    try testing.expectEqual(@as(?i64, -1), parse("Wed, 31 Dec 1969 23:59:59 GMT", now));
    try testing.expectEqual(@as(?i64, 1483228800), parse("Sat, 31 Dec 2016 23:59:60 GMT", now));
    for ([_][]const u8{
        "Thu, 29 Feb 2023 00:00:00 GMT",
        "Sun, 06 Nov 1994 25:49:37 GMT",
        "Mon, 06 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "Sun Nov  6 08:49:37 1994 extra",
        "Sun, 06 Nov 1994 08:49:37 GMT, Sun, 06 Nov 1994 08:49:37 GMT",
    }) |bytes| try testing.expectEqual(@as(?i64, null), parse(bytes, now));
}

test "RFC 850 rolls future years into the preceding century" {
    try std.testing.expectEqual(
        @as(?i64, 315532800),
        parse("Tuesday, 01-Jan-80 00:00:00 GMT", 1789096284),
    );
    // In 2040, that same suffix instead denotes 2080, whose weekday is Monday.
    try std.testing.expectEqual(
        @as(?i64, 3471292800),
        parse("Monday, 01-Jan-80 00:00:00 GMT", 2208988800),
    );
}

test "RFC 850 selects the century before validating leap days" {
    const testing = std.testing;
    try testing.expectEqual(
        @as(?i64, 951782400),
        parse("Tuesday, 29-Feb-00 00:00:00 GMT", 2524608000),
    );
    try testing.expectEqual(@as(?i64, null), parse("Tuesday, 29-Feb-00 00:00:00 GMT", 2556144000));
    try testing.expectEqual(@as(?i64, null), parse("Tuesday, 30-Feb-00 00:00:00 GMT", 2524608000));
}

test "RFC 850 fifty-year cutoff includes the time of day" {
    const testing = std.testing;
    const now = 2524608000;
    try testing.expectEqual(@as(?i64, 4102444800), parse("Friday, 01-Jan-00 00:00:00 GMT", now));
    try testing.expectEqual(@as(?i64, 946684801), parse("Saturday, 01-Jan-00 00:00:01 GMT", now));
}
