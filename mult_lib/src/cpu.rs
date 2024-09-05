#![cfg(target_family = "unix")]
use std::{thread, time::Duration};

use libc;

#[cfg(target_family = "unix")]
use crate::linux::cpu::linux_split_limit_cpu;
use crate::{
    proc,
    tree::{search_tree, TreeNode},
};

static MILS_IN_SECOND: f32 = 1000.0;

pub fn split_limit_cpu(pid: i32, limit: f32) {
    #[cfg(target_os = "linux")]
    return linux_split_limit_cpu(pid, limit);
}

pub fn get_cpu_usage(pid: usize, node: TreeNode, old_total_time: u32) -> f32 {
    #[cfg(target_os = "linux")]
    return linux_get_cpu_usage(pid, node, old_total_time);
}
