//! HTTP-date parsing, including both obsolete wire formats required by RFC 9110.

const std = @import("std");
const epoch = std.time.epoch;
const log = std.log.scoped(.http_date);

const weekdays = [_][]const u8{
    "Sun",
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
    "Sat",
};
const long_weekdays = [_][]const u8{
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
};
const months = [_][]const u8{
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
};

/// Returns Unix seconds, or null for invalid syntax or calendar dates. Leap
/// seconds map to the following Unix second. `now` resolves RFC 850 years;
/// asserts it lies between 1970 and 9949, inclusive.
pub fn parse(bytes: []const u8, now: u64) ?i64 {
    std.debug.assert(now < (calendarDays(9950, 1, 1) orelse unreachable) * 86400);
    var year: u16 = undefined;
    var month: u8 = undefined;
    var day: u16 = undefined;
    var weekday: usize = undefined;
    var time: []const u8 = undefined;
    if (bytes.len == 29 and bytes[3] == ',') {
        if (!std.mem.eql(u8, bytes[3..5], ", ") or bytes[7] != ' ' or
            bytes[11] != ' ' or bytes[16] != ' ' or !std.mem.eql(u8, bytes[25..], " GMT")) return null;
        weekday = lookup(&weekdays, bytes[0..3]) orelse return null;
        day = number(bytes[5..7]) orelse return null;
        month = @intCast((lookup(&months, bytes[8..11]) orelse return null) + 1);
        year = number(bytes[12..16]) orelse return null;
        time = bytes[17..25];
    } else if (bytes.len == 24 and bytes[3] == ' ') {
        if (bytes[7] != ' ' or bytes[10] != ' ' or bytes[19] != ' ') return null;
        weekday = lookup(&weekdays, bytes[0..3]) orelse return null;
        month = @intCast((lookup(&months, bytes[4..7]) orelse return null) + 1);
        day = number(if (bytes[8] == ' ') bytes[9..10] else bytes[8..10]) orelse return null;
        year = number(bytes[20..24]) orelse return null;
        time = bytes[11..19];
    } else {
        const comma = std.mem.indexOfScalar(u8, bytes, ',') orelse return null;
        weekday = lookup(&long_weekdays, bytes[0..comma]) orelse return null;
        const rest = bytes[comma..];
        if (rest.len != 24 or rest[1] != ' ' or rest[4] != '-' or rest[8] != '-' or
            rest[11] != ' ' or !std.mem.eql(u8, rest[20..], " GMT")) return null;
        day = number(rest[2..4]) orelse return null;
        month = @intCast((lookup(&months, rest[5..8]) orelse return null) + 1);
        const short_year = number(rest[9..11]) orelse return null;
        time = rest[12..20];
        const current: epoch.EpochSeconds = .{ .secs = now };
        const current_year = current.getEpochDay().calculateYearDay();
        const current_month = current_year.calculateMonthDay();
        const future_year = current_year.year + 50;
        const future_day = @min(current_month.day_index + @as(u16, 1), epoch.getDaysInMonth(future_year, current_month.month));
        const cutoff = (calendarDays(future_year, current_month.month.numeric(), future_day) orelse unreachable) * 86400 +
            current.getDaySeconds().secs;
        year = future_year / 100 * 100 + short_year;
        const candidate = (calendarDays(year, month, day) orelse return null) * 86400 + (parseTime(time) orelse return null);
        if (candidate > cutoff) year -= 100;
    }
    const days = calendarDays(year, month, day) orelse return null;
    if (@mod(days + 4, 7) != weekday) return null;
    return days * 86400 + (parseTime(time) orelse return null);
}

fn number(bytes: []const u8) ?u16 {
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u16, bytes, 10) catch null;
}

fn lookup(list: []const []const u8, bytes: []const u8) ?usize {
    for (list, 0..) |name, index| if (std.mem.eql(u8, name, bytes)) return index;
    return null;
}

fn parseTime(bytes: []const u8) ?u32 {
    if (bytes[2] != ':' or bytes[5] != ':') return null;
    const hour = number(bytes[0..2]) orelse return null;
    const minute = number(bytes[3..5]) orelse return null;
    const second = number(bytes[6..8]) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    return @as(u32, hour) * 3600 + @as(u32, minute) * 60 + second;
}

fn calendarDays(year: u16, month: u8, day: u16) ?i64 {
    if (year < 1601 or year > 9999 or month < 1 or month > 12 or day < 1 or
        day > epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    const before: i64 = year - 1;
    var days = (before - 1969) * 365 + @divFloor(before, 4) - @divFloor(before, 100) +
        @divFloor(before, 400) - 477;
    var m: u8 = 1;
    while (m < month) : (m += 1) days += epoch.getDaysInMonth(year, @enumFromInt(m));
    return days + day - 1;
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
    try std.testing.expectEqual(@as(?i64, 315532800), parse("Tuesday, 01-Jan-80 00:00:00 GMT", 1789096284));
    // In 2040, that same suffix instead denotes 2080, whose weekday is Monday.
    try std.testing.expectEqual(@as(?i64, 3471292800), parse("Monday, 01-Jan-80 00:00:00 GMT", 2208988800));
}
