use prettytable::{format, Cell, Row, Table};

use crate::colors::{color_string, ERR_RED};

pub struct MainHeaders {
    pub id: u32,
    pub command: String,
    pub dir: String,
}

pub struct ProcessHeaders {
    pub pid: String,
    pub memory: String,
    pub cpu: String,
    pub runtime: String,
    pub status: String,
}

pub struct TableManager {
    pub ascii_table: Table,
    pub table_data: Vec<Vec<String>>,
}

impl TableManager {
    pub fn create_headers(&mut self) {
        self.ascii_table.set_format(
            format::FormatBuilder::new()
                .column_separator('│')
                .borders('│')
                .separators(
                    &[format::LinePosition::Top],
                    format::LineSeparator::new('─', '┬', '┌', '┐'),
                )
                .separators(
                    &[format::LinePosition::Title],
                    format::LineSeparator::new('─', '┼', '├', '┤'),
                )
                .separators(
                    &[format::LinePosition::Bottom],
                    format::LineSeparator::new('─', '┴', '└', '┘'),
                )
                .padding(1, 1)
                .build(),
        );
        self.ascii_table.set_titles(Row::new(vec![
            Cell::new("id").style_spec("b"),
            Cell::new("command").style_spec("b"),
            Cell::new("location").style_spec("b"),
            Cell::new("pid").style_spec("b"),
            Cell::new("status").style_spec("b"),
            Cell::new("memory").style_spec("b"),
            Cell::new("cpu").style_spec("b"),
            Cell::new("runtime").style_spec("b"),
        ]));
    }

    pub fn insert_row(&mut self, headers: MainHeaders, process: Option<ProcessHeaders>) {
        let mut row: Vec<Cell> = vec![
            Cell::new(&headers.id.to_string()),
            Cell::new(&headers.command),
            Cell::new(&headers.dir),
        ];
        if let Some(p) = process {
            row.extend(vec![
                Cell::new(&p.pid),
                Cell::new(&p.status),
                Cell::new(&p.memory),
                Cell::new(&p.cpu),
                Cell::new(&p.runtime),
            ]);
        } else {
            row.extend(vec![
                Cell::new("N/A"),
                Cell::new(&color_string(ERR_RED, "Stopped")),
                Cell::new("N/A"),
                Cell::new("N/A"),
                Cell::new("N/A"),
            ]);
        }

        self.ascii_table.add_row(Row::new(row));
    }

    pub fn print(&mut self) -> usize {
        self.ascii_table.print_tty(false).unwrap()
    }
}

const SUFFIX: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
const UNIT: f64 = 1000.0;
pub fn format_bytes(bytes: f64) -> String {
    if bytes <= 0.0 {
        return "0 B".to_string();
    }
    let base = bytes.log10() / UNIT.log10();

    let result = format!("{:.1}", UNIT.powf(base - base.floor()),)
        .trim_end_matches(".0")
        .to_owned();

    [&result, SUFFIX[base.floor() as usize]].join(" ")
}
