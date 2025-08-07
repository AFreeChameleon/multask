use crate::proc::PID;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TreeNode {
    pub pid: PID,
    pub utime: u64,
    pub stime: u64,
    pub children: Vec<TreeNode>,
}

pub fn search_tree(tree: &TreeNode, cb: &impl Fn(&TreeNode)) {
    cb(tree);
    for child_node in tree.children.iter() {
        search_tree(child_node, cb);
    }
}

pub fn compress_tree(tree: &TreeNode, processes: &mut Vec<PID>) {
    processes.push(tree.pid);
    for child_node in tree.children.iter() {
        compress_tree(child_node, processes);
    }
}

impl TreeNode {
    pub fn empty() -> TreeNode {
        TreeNode {
            pid: 0,
            utime: 0,
            stime: 0,
            children: Vec::new(),
        }
    }
}
