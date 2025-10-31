// Zig bindings for Clay's termbox2 renderer

const clay = @import("zclay");

// Termbox2 types and constants
pub const Event = extern struct {
    type: u8,
    mod: u8,
    key: u16,
    ch: u32,
    w: i32,
    h: i32,
    x: i32,
    y: i32,
};

// Event types
pub const EVENT_KEY: u8 = 1;
pub const EVENT_RESIZE: u8 = 2;
pub const EVENT_MOUSE: u8 = 3;

// Keys
pub const KEY_CTRL_C: u16 = 0x03;
pub const KEY_CTRL_S: u16 = 0x13;
// Backspace has two codes for terminal compatibility:
// 0x08 (^H/BS) - sent by some terminals
// 0x7F (DEL) - sent by other terminals
// Always check both to ensure backspace works across different systems
pub const KEY_BACKSPACE: u16 = 0x08;
pub const KEY_BACKSPACE2: u16 = 0x7F;
pub const KEY_ENTER: u16 = 0x0d;
pub const KEY_ESC: u16 = 0x1b;
pub const KEY_DELETE: u16 = (0xFFFF - 22);
pub const KEY_ARROW_UP: u16 = (0xFFFF - 18);
pub const KEY_ARROW_DOWN: u16 = (0xFFFF - 19);
pub const KEY_ARROW_LEFT: u16 = (0xFFFF - 20);
pub const KEY_ARROW_RIGHT: u16 = (0xFFFF - 21);
pub const KEY_MOUSE_LEFT: u16 = 0xFFED;
pub const KEY_MOUSE_RIGHT: u16 = 0xFFEE;
pub const KEY_MOUSE_MIDDLE: u16 = 0xFFEF;
pub const KEY_MOUSE_RELEASE: u16 = 0xFFF0;
pub const KEY_MOUSE_WHEEL_UP: u16 = 0xFFF1;
pub const KEY_MOUSE_WHEEL_DOWN: u16 = 0xFFF2;

// Error codes
pub const OK: c_int = 0;
pub const ERR_NO_EVENT: c_int = -1;
pub const ERR_POLL: c_int = -2;

// Color modes
pub const OUTPUT_NORMAL: c_int = 0;
pub const OUTPUT_256: c_int = 1;
pub const OUTPUT_216: c_int = 2;
pub const OUTPUT_GRAYSCALE: c_int = 3;
pub const OUTPUT_TRUECOLOR: c_int = 4;

// Border modes
pub const BorderMode = enum(c_int) {
    default = 0,
    round = 1,
    minimum = 2,
};

// Border characters
pub const BorderChars = enum(c_int) {
    default = 0,
    ascii = 1,
    unicode = 2,
    blank = 3,
    none = 4,
};

// Image modes
pub const ImageMode = enum(c_int) {
    default = 0,
    placeholder = 1,
    bg = 2,
    ascii_fg = 3,
    ascii_fg_fast = 4,
    ascii = 5,
    ascii_fast = 6,
    unicode = 7,
    unicode_fast = 8,
};

// C function declarations
extern fn Clay_Termbox_Initialize_With_MeasureText(
    color_mode: c_int,
    border_mode: c_int,
    border_chars: c_int,
    image_mode: c_int,
    transparency: bool,
) void;

extern fn Clay_Termbox_Close() void;
extern fn Clay_Termbox_Render(commands: clay.ClayArray(clay.RenderCommand)) void;
extern fn Clay_Termbox_Waitfor_Event() void;
extern fn Clay_Termbox_Width() f32;
extern fn Clay_Termbox_Height() f32;
extern fn Clay_Termbox_Cell_Width() f32;
extern fn Clay_Termbox_Cell_Height() f32;
extern fn Clay_Termbox_SetMeasureText() void;

extern fn tb_present() c_int;
extern fn tb_clear() c_int;
extern fn tb_peek_event(event: *Event, timeout_ms: c_int) c_int;
extern fn tb_last_errno() c_int;

// Wrapper functions
pub fn initialize(
    color_mode: c_int,
    border_mode: BorderMode,
    border_chars: BorderChars,
    image_mode: ImageMode,
    transparency: bool,
) void {
    Clay_Termbox_Initialize_With_MeasureText(
        color_mode,
        @intFromEnum(border_mode),
        @intFromEnum(border_chars),
        @intFromEnum(image_mode),
        transparency,
    );
}

pub const close = Clay_Termbox_Close;

pub fn render(commands: []clay.RenderCommand) void {
    const clay_array = clay.ClayArray(clay.RenderCommand){
        .capacity = @intCast(commands.len),
        .length = @intCast(commands.len),
        .internal_array = commands.ptr,
    };
    Clay_Termbox_Render(clay_array);
}

pub const waitforEvent = Clay_Termbox_Waitfor_Event;
pub const width = Clay_Termbox_Width;
pub const height = Clay_Termbox_Height;
pub const cellWidth = Clay_Termbox_Cell_Width;
pub const cellHeight = Clay_Termbox_Cell_Height;

pub const present = tb_present;
pub const clear = tb_clear;
pub const peekEvent = tb_peek_event;
pub const lastErrno = tb_last_errno;
pub const setMeasureText = Clay_Termbox_SetMeasureText;
