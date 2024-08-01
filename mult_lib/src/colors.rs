pub const OK_GREEN: [i32; 3] = [0, 204, 102];
pub const ERR_RED: [i32; 3] = [204, 0, 0];
pub const INFO_BLUE: [i32; 3] = [0, 51, 255];
pub const WARNING_ORANGE: [i32; 3] = [204, 102, 0];

pub fn color_string(rgb: [i32; 3], text: &str) -> String {
    return format!("\x1B[38;2;{};{};{}m{}\x1B[0m", rgb[0], rgb[1], rgb[2], text);
}
pub fn bold_string(text: &str) -> String {
    return format!("\x1B[1m{}\x1B[0m", text);
}
