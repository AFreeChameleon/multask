#![cfg(target_family = "unix")]
extern "C" {
    pub fn __error() -> i32;
}

pub fn hi() {

}
