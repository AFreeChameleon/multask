#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TreeNode {
    pub pid: usize,
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

pub fn compress_tree(tree: &TreeNode, processes: &mut Vec<usize>) {
    processes.push(tree.pid);
    for child_node in tree.children.iter() {
        compress_tree(child_node, processes);
    }
}

impl TreeNode {
    pub fn empty() -> TreeNode {
        TreeNode {
            pid: usize::MIN,
            utime: u64::MIN,
            stime: u64::MIN,
            children: Vec::new(),
        }
    }
}
