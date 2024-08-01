#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct TreeNode {
    pub pid: usize,
    pub children: Vec<TreeNode>
}

pub fn search_tree(tree: &TreeNode, cb: &impl Fn(usize)) {
    cb(tree.pid);
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
