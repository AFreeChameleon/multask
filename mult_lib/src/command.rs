use bincode;
use std::{
    fs::{self, File},
    io::Write,
    path::Path,
};

use crate::error::{MultError, MultErrorTuple};

#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct MemStats {
    pub memory_limit: i64,
    pub cpu_limit: i32,
}

#[derive(serde::Serialize, serde::Deserialize)]
pub struct CommandData {
    pub command: String,
    pub pid: u32,
    pub dir: String,
    pub name: String,
    pub starttime: u64,
}

pub struct CommandManager {}

impl CommandManager {
    pub fn read_command_data(task_id: u32) -> Result<CommandData, MultErrorTuple> {
        let data_file = Path::new(&home::home_dir().unwrap())
            .join(".multi-tasker")
            .join("processes")
            .join(task_id.to_string())
            .join("data.bin");
        if data_file.exists() {
            let data_encoded: Vec<u8> = fs::read(data_file).unwrap();
            let data_decoded: CommandData = bincode::deserialize(&data_encoded[..]).unwrap();
            return Ok(data_decoded);
        }
        Err((MultError::TaskNotFound, None))
    }

    pub fn write_command_data(command: CommandData, process_dir: &Path) {
        let encoded_data: Vec<u8> = bincode::serialize::<CommandData>(&command).unwrap();
        let mut process_file = File::create(process_dir.join("data.bin")).unwrap();
        process_file.write_all(&encoded_data).unwrap();
    }
}
