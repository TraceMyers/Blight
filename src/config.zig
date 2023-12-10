const std = @import("std");

// ---------------------------------------------------------------------------------------------------------------------

pub const run_scope_timers: bool = true;

pub const disable_load_bmp: bool = false;
pub const disable_load_tga: bool = false;
pub const disable_load_png: bool = false;
pub const disable_load_jpg: bool = false;

pub const disable_save_bmp: bool = false;
pub const disable_save_tga: bool = false;
pub const disable_save_png: bool = false;
pub const disable_save_jpg: bool = false;

pub const max_alloc_sz: usize = std.math.maxInt(usize);

pub var dbg_verbose: bool = false;
