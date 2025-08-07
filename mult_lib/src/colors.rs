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

#[cfg(windows)]
pub fn set_virtual_terminal(use_virtual: bool) -> Result<(), ()> {
    use windows_sys::Win32::System::Console::{
        GetConsoleMode, GetStdHandle, SetConsoleMode, ENABLE_VIRTUAL_TERMINAL_PROCESSING,
        STD_OUTPUT_HANDLE,
    };

    unsafe {
        let handle = GetStdHandle(STD_OUTPUT_HANDLE);
        let mut original_mode = 0;
        GetConsoleMode(handle, &mut original_mode);

        let enabled = original_mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING
            == ENABLE_VIRTUAL_TERMINAL_PROCESSING;

        match (use_virtual, enabled) {
            // not enabled, should be enabled
            (true, false) => {
                SetConsoleMode(handle, ENABLE_VIRTUAL_TERMINAL_PROCESSING | original_mode)
            }
            // already enabled, should be disabled
            (false, true) => {
                SetConsoleMode(handle, ENABLE_VIRTUAL_TERMINAL_PROCESSING ^ original_mode)
            }
            _ => 0,
        };
    }

    Ok(())
}
