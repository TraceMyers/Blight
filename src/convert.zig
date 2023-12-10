pub inline fn nanoToMicro(x: anytype) @TypeOf(x) {
    return nano_to_micro * x;
}
pub inline fn nanoToMilli(x: anytype) @TypeOf(x) {
    return nano_to_milli * x;
}
pub inline fn nanoToCenti(x: anytype) @TypeOf(x) {
    return nano_to_centi * x;
}
pub inline fn nanoToDeci(x: anytype) @TypeOf(x) {
    return nano_to_deci * x;
}
pub inline fn nanoToBase(x: anytype) @TypeOf(x) {
    return nano_to_base * x;
}
pub inline fn nanoToKilo(x: anytype) @TypeOf(x) {
    return nano_to_kilo * x;
}
pub inline fn nano100ToMilli(x: anytype) @TypeOf(x) {
    return nano100_to_milli * x;
}
pub inline fn nano100ToBase(x: anytype) @TypeOf(x) {
    return nano100_to_base * x;
}

pub inline fn microToNano(x: anytype) @TypeOf(x) {
    return micro_to_nano * x;
}
pub inline fn microToMilli(x: anytype) @TypeOf(x) {
    return micro_to_milli * x;
}
pub inline fn microToCenti(x: anytype) @TypeOf(x) {
    return micro_to_centi * x;
}
pub inline fn microToDeci(x: anytype) @TypeOf(x) {
    return micro_to_deci * x;
}
pub inline fn microToBase(x: anytype) @TypeOf(x) {
    return micro_to_base * x;
}
pub inline fn microToKilo(x: anytype) @TypeOf(x) {
    return micro_to_kilo * x;
}

pub inline fn milliToNano(x: anytype) @TypeOf(x) {
    return milli_to_nano * x;
}
pub inline fn milliToNano100(x: anytype) @TypeOf(x) {
    return milli_to_nano100 * x;
}
pub inline fn milliToMicro(x: anytype) @TypeOf(x) {
    return milli_to_micro * x;
}
pub inline fn milliToCenti(x: anytype) @TypeOf(x) {
    return milli_to_centi * x;
}
pub inline fn milliToDeci(x: anytype) @TypeOf(x) {
    return milli_to_deci * x;
}
pub inline fn milliToBase(x: anytype) @TypeOf(x) {
    return milli_to_base * x;
}
pub inline fn milliToKilo(x: anytype) @TypeOf(x) {
    return milli_to_kilo * x;
}

pub inline fn centoToNano(x: anytype) @TypeOf(x) {
    return centi_to_nano * x;
}
pub inline fn centoToMicro(x: anytype) @TypeOf(x) {
    return centi_to_micro * x;
}
pub inline fn centoToMilli(x: anytype) @TypeOf(x) {
    return centi_to_milli * x;
}
pub inline fn centoToDeci(x: anytype) @TypeOf(x) {
    return centi_to_deci * x;
}
pub inline fn centiToBase(x: anytype) @TypeOf(x) {
    return centi_to_base * x;
}
pub inline fn centiToKilo(x: anytype) @TypeOf(x) {
    return centi_to_kilo * x;
}

pub inline fn deciToNano(x: anytype) @TypeOf(x) {
    return deci_to_nano * x;
}
pub inline fn deciToMicro(x: anytype) @TypeOf(x) {
    return deci_to_micro * x;
}
pub inline fn deciToMilli(x: anytype) @TypeOf(x) {
    return deci_to_milli * x;
}
pub inline fn deciToCenti(x: anytype) @TypeOf(x) {
    return deci_to_centi * x;
}
pub inline fn deciToBase(x: anytype) @TypeOf(x) {
    return deci_to_base * x;
}
pub inline fn deciToKilo(x: anytype) @TypeOf(x) {
    return deci_to_kilo * x;
}

pub inline fn baseToNano(x: anytype) @TypeOf(x) {
    return base_to_nano * x;
}
pub inline fn baseToMicro(x: anytype) @TypeOf(x) {
    return base_to_micro * x;
}
pub inline fn baseToMilli(x: anytype) @TypeOf(x) {
    return base_to_milli * x;
}
pub inline fn baseToCenti(x: anytype) @TypeOf(x) {
    return base_to_centi * x;
}
pub inline fn baseToDeci(x: anytype) @TypeOf(x) {
    return base_to_deci * x;
}
pub inline fn baseToKilo(x: anytype) @TypeOf(x) {
    return base_to_kilo * x;
}

pub inline fn kiloToNano(x: anytype) @TypeOf(x) {
    return kilo_to_nano * x;
}
pub inline fn kiloToMicro(x: anytype) @TypeOf(x) {
    return kilo_to_micro * x;
}
pub inline fn kiloToMilli(x: anytype) @TypeOf(x) {
    return kilo_to_milli * x;
}
pub inline fn kiloToCenti(x: anytype) @TypeOf(x) {
    return kilo_to_centi * x;
}
pub inline fn kiloToDeci(x: anytype) @TypeOf(x) {
    return kilo_to_deci * x;
}
pub inline fn kiloToBase(x: anytype) @TypeOf(x) {
    return kilo_to_base * x;
}

pub const nano_to_micro = 1e-3;
pub const nano_to_milli = 1e-6;
pub const nano_to_centi = 1e-7;
pub const nano_to_deci = 1e-8;
pub const nano_to_base = 1e-9;
pub const nano_to_kilo = 1e-12;
pub const nano100_to_milli = 1e-4;
pub const nano100_to_base = 1e-8;

pub const micro_to_nano = 1e3;
pub const micro_to_milli = 1e-3;
pub const micro_to_centi = 1e-4;
pub const micro_to_deci = 1e-5;
pub const micro_to_base = 1e-6;
pub const micro_to_kilo = 1e-9;

pub const milli_to_nano = 1e6;
pub const milli_to_nano100 = 1e4;
pub const milli_to_micro = 1e3;
pub const milli_to_centi = 1e-1;
pub const milli_to_deci = 1e-2;
pub const milli_to_base = 1e-3;
pub const milli_to_kilo = 1e-6;

pub const centi_to_nano = 1e7;
pub const centi_to_micro = 1e4;
pub const centi_to_milli = 1e1;
pub const centi_to_deci = 1e-1;
pub const centi_to_base = 1e-2;
pub const centi_to_kilo = 1e-5;

pub const deci_to_nano = 1e8;
pub const deci_to_micro = 1e5;
pub const deci_to_milli = 1e2;
pub const deci_to_centi = 1e1;
pub const deci_to_base = 1e-1;
pub const deci_to_kilo = 1e-4;

pub const base_to_nano = 1e9;
pub const base_to_micro = 1e6;
pub const base_to_milli = 1e3;
pub const base_to_centi = 1e2;
pub const base_to_deci = 1e1;
pub const base_to_kilo = 1e-3;

pub const kilo_to_nano = 1e12;
pub const kilo_to_micro = 1e9;
pub const kilo_to_milli = 1e6;
pub const kilo_to_centi = 1e5;
pub const kilo_to_deci = 1e4;
pub const kilo_to_base = 1e3;
