//! x86_64 VGA Console Driver
//! Early console support for kernel debugging

const std = @import("std");

/// VGA text mode constants
const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;
const VGA_MEMORY: *volatile [VGA_HEIGHT * VGA_WIDTH]u16 = @ptrFromInt(0xB8000);

/// VGA colors
pub const Color = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    light_brown = 14,
    white = 15,
};

/// Console state
var console_state = struct {
    row: usize = 0,
    column: usize = 0,
    color: u8 = makeColor(.light_gray, .black),
    initialized: bool = false,
}{};

/// Initialize the console
pub fn init() !void {
    console_state.row = 0;
    console_state.column = 0;
    console_state.color = makeColor(.light_gray, .black);
    console_state.initialized = true;
    
    // Clear screen
    clear();
}

/// Set console colors
pub fn setColor(fg: Color, bg: Color) void {
    console_state.color = makeColor(fg, bg);
}

/// Write a single character
pub fn writeChar(char: u8) void {
    if (!console_state.initialized) return;
    
    switch (char) {
        '\n' => {
            console_state.column = 0;
            console_state.row += 1;
        },
        '\r' => {
            console_state.column = 0;
        },
        '\t' => {
            const tab_stop = 8;
            const spaces = tab_stop - (console_state.column % tab_stop);
            for (0..spaces) |_| {
                writeChar(' ');
            }
            return;
        },
        '\x08' => { // Backspace
            if (console_state.column > 0) {
                console_state.column -= 1;
                putCharAt(' ', console_state.column, console_state.row);
            }
        },
        else => {
            putCharAt(char, console_state.column, console_state.row);
            console_state.column += 1;
        },
    }
    
    // Handle line wrapping
    if (console_state.column >= VGA_WIDTH) {
        console_state.column = 0;
        console_state.row += 1;
    }
    
    // Handle scrolling
    if (console_state.row >= VGA_HEIGHT) {
        scroll();
        console_state.row = VGA_HEIGHT - 1;
    }
}

/// Write a string
pub fn writeString(str: []const u8) void {
    for (str) |char| {
        writeChar(char);
    }
}

/// Write formatted string
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const str = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    writeString(str);
}

/// Panic print function for kernel panics
pub fn panic_print(comptime fmt: []const u8, args: anytype) void {
    setColor(.red, .black);
    printf(fmt, args);
}

/// Clear the screen
pub fn clear() void {
    const entry = makeVgaEntry(' ', console_state.color);
    for (0..VGA_HEIGHT * VGA_WIDTH) |i| {
        VGA_MEMORY[i] = entry;
    }
    console_state.row = 0;
    console_state.column = 0;
}

/// Scroll the screen up by one line
fn scroll() void {
    // Move all lines up
    for (0..VGA_HEIGHT - 1) |y| {
        for (0..VGA_WIDTH) |x| {
            const src_index = (y + 1) * VGA_WIDTH + x;
            const dst_index = y * VGA_WIDTH + x;
            VGA_MEMORY[dst_index] = VGA_MEMORY[src_index];
        }
    }
    
    // Clear last line
    const last_line_start = (VGA_HEIGHT - 1) * VGA_WIDTH;
    const entry = makeVgaEntry(' ', console_state.color);
    for (0..VGA_WIDTH) |x| {
        VGA_MEMORY[last_line_start + x] = entry;
    }
}

/// Put a character at specific position
fn putCharAt(char: u8, x: usize, y: usize) void {
    if (x >= VGA_WIDTH or y >= VGA_HEIGHT) return;
    
    const index = y * VGA_WIDTH + x;
    VGA_MEMORY[index] = makeVgaEntry(char, console_state.color);
}

/// Make VGA color byte
fn makeColor(fg: Color, bg: Color) u8 {
    return @intFromEnum(fg) | (@as(u8, @intFromEnum(bg)) << 4);
}

/// Make VGA entry (character + color)
fn makeVgaEntry(char: u8, color: u8) u16 {
    return char | (@as(u16, color) << 8);
}

/// Get current cursor position
pub fn getCursorPos() struct { x: usize, y: usize } {
    return .{ .x = console_state.column, .y = console_state.row };
}

/// Set cursor position  
pub fn setCursorPos(x: usize, y: usize) void {
    if (x < VGA_WIDTH and y < VGA_HEIGHT) {
        console_state.column = x;
        console_state.row = y;
    }
}

/// Print hex number
pub fn printHex(value: anytype) void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);
    
    if (type_info != .Int) {
        writeString("0x?");
        return;
    }
    
    writeString("0x");
    const hex_chars = "0123456789ABCDEF";
    const bytes = @sizeOf(T);
    
    var i: usize = bytes;
    while (i > 0) : (i -= 1) {
        const byte = @as(u8, @truncate(value >> @intCast((i - 1) * 8)));
        writeChar(hex_chars[(byte >> 4) & 0xF]);
        writeChar(hex_chars[byte & 0xF]);
    }
}

/// Print decimal number
pub fn printDec(value: anytype) void {
    var buffer: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch "?";
    writeString(str);
}

/// Draw a simple progress bar
pub fn drawProgressBar(progress: u8, width: usize) void {
    writeChar('[');
    
    const filled = (progress * width) / 100;
    
    for (0..width) |i| {
        if (i < filled) {
            writeChar('=');
        } else if (i == filled and progress < 100) {
            writeChar('>');
        } else {
            writeChar(' ');
        }
    }
    
    writeChar(']');
    writeChar(' ');
    printDec(progress);
    writeChar('%');
}

/// Print memory size in human readable format
pub fn printMemorySize(bytes: u64) void {
    if (bytes >= 1024 * 1024 * 1024) {
        const gb = bytes / (1024 * 1024 * 1024);
        const mb = (bytes % (1024 * 1024 * 1024)) / (1024 * 1024);
        printDec(gb);
        writeChar('.');
        printDec(mb / 100);
        writeString("GB");
    } else if (bytes >= 1024 * 1024) {
        const mb = bytes / (1024 * 1024);
        const kb = (bytes % (1024 * 1024)) / 1024;
        printDec(mb);
        writeChar('.');
        printDec(kb / 100);
        writeString("MB");
    } else if (bytes >= 1024) {
        const kb = bytes / 1024;
        const b = bytes % 1024;
        printDec(kb);
        writeChar('.');
        printDec(b / 100);
        writeString("KB");
    } else {
        printDec(bytes);
        writeString("B");
    }
}