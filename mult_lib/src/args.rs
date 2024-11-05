use crate::{
    error::{MultError, MultErrorTuple},
    proc::ForkFlagTuple,
};

#[derive(Debug)]
pub struct ParsedArgs {
    pub flags: Vec<String>,
    pub value_flags: Vec<(String, Option<String>)>,
    pub values: Vec<String>,
}

pub const MEMORY_LIMIT_FLAG: &str = "-m";
pub const CPU_LIMIT_FLAG: &str = "-c";
pub const INTERACTIVE_FLAG: &str = "-i";

// flags is an array of the name of the flag like --watch and if the flag has a value
pub fn parse_args(
    args: &[String],
    flags: &[(&str, bool)],
    allow_values: bool,
) -> Result<ParsedArgs, MultErrorTuple> {
    let mut parsed_args = ParsedArgs {
        flags: Vec::new(),
        value_flags: Vec::new(),
        values: Vec::new(),
    };
    if args.len() == 0 {
        return Ok(parsed_args);
    }
    let mut arg_idx = 0;
    let mut arg = &args[arg_idx];
    if let Some(flag) = flags.iter().find(|val| val.0 == arg) {
        if flag.1 {
            parsed_args
                .value_flags
                .push((arg.to_string(), Some(args[arg_idx + 1].to_string())));
            // Skipping next arg since it's a value
            arg_idx += 1;
        }
        parsed_args.flags.push(arg.to_string());
    } else {
        if !allow_values {
            return Err((MultError::InvalidArgument, Some(arg.to_string())));
        }
        parsed_args.values.push(arg.to_string());
    }
    loop {
        arg_idx += 1;
        if arg_idx >= args.len() {
            break;
        }
        arg = &args[arg_idx];
        if let Some(flag) = flags.iter().find(|val| val.0 == arg) {
            if flag.1 {
                parsed_args
                    .value_flags
                    .push((arg.to_string(), Some(args[arg_idx + 1].to_string())));
                // Skipping next arg since it's a value
                arg_idx += 1;
                continue;
            }
            parsed_args.flags.push(arg.to_string());
            continue;
        }
        if !allow_values {
            return Err((MultError::InvalidArgument, Some(arg.to_string())));
        }
        parsed_args.values.push(arg.to_string());
        continue;
    }
    Ok(parsed_args)
}

pub fn parse_string_to_bytes(val: String) -> Option<i64> {
    let chars = val.chars();
    let mut number_str = String::new();
    let mut factor_str = String::new();
    for char in chars {
        if char.is_numeric() && factor_str == String::new() {
            number_str.push(char);
        } else {
            factor_str.push(char);
        }
    }
    let number: i64 = number_str.parse().unwrap();
    if factor_str.len() > 2 {
        return None;
    }
    if factor_str == "B" {
        return Some(number);
    }
    let multiplier = match factor_str.to_lowercase().chars().nth(0) {
        //Some('b') => return Some(number / 8),
        Some('b') => number,
        Some('k') => 1000,
        Some('m') => 1e+6 as i64,
        Some('g') => 1e+9 as i64,
        Some('t') => 1e+12 as i64,
        _ => return None,
    };
    //multiplier *= match factor_str.chars().nth(1) {
    //    Some('b') => 8,
    //    Some('B') => 1,
    //    _ => return None,
    //};

    return Some(number as i64 * multiplier);
}

pub fn get_fork_flag_values(parsed_args: &ParsedArgs) -> Result<ForkFlagTuple, MultErrorTuple> {
    let mut memory_limit: i64 = -1;
    if let Some(memory_limit_flag) = parsed_args
        .value_flags
        .clone()
        .into_iter()
        .find(|(flag, _)| flag == MEMORY_LIMIT_FLAG)
    {
        if memory_limit_flag.1.is_some() {
            memory_limit = match parse_string_to_bytes(memory_limit_flag.1.unwrap()) {
                None => {
                    return Err((
                        MultError::InvalidArgument,
                        Some(format!(
                            "{} value must have a valid format (B, kB, mB, gB) at the end",
                            MEMORY_LIMIT_FLAG.to_string()
                        )),
                    ))
                }
                Some(val) => val,
            };
            if memory_limit < 1 {
                return Err((
                    MultError::InvalidArgument,
                    Some(format!(
                        "{} value must be over 1",
                        CPU_LIMIT_FLAG.to_string()
                    )),
                ));
            }
        }
    }
    let mut cpu_limit: i32 = -1;
    if let Some(cpu_limit_flag) = parsed_args
        .value_flags
        .clone()
        .into_iter()
        .find(|(flag, _)| flag == CPU_LIMIT_FLAG)
    {
        if cpu_limit_flag.1.is_some() {
            cpu_limit = match cpu_limit_flag.1.unwrap().parse::<i32>() {
                Err(_) => {
                    return Err((MultError::InvalidArgument, Some(CPU_LIMIT_FLAG.to_string())))
                }
                Ok(val) => val,
            };
            if cpu_limit > 100 || cpu_limit < 1 {
                return Err((
                    MultError::InvalidArgument,
                    Some(format!(
                        "{} valid values are between 1 and 100",
                        CPU_LIMIT_FLAG.to_string()
                    )),
                ));
            }
        }
    }
    let interactive = parsed_args.flags.contains(&INTERACTIVE_FLAG.to_owned());
    Ok((memory_limit, cpu_limit, interactive))
}

#[cfg(test)]
mod tests {
    use crate::args::parse_string_to_bytes;

    use super::parse_args;

    #[test]
    fn parses_strings_to_bytes() {
        let gb_string = String::from("12Gb");
        let gbytes_string = String::from("12GB");
        let mbytes_string = String::from("12mB");
        let bytes_string = String::from("12B");
        let invalid_string = String::from("12LB");
        assert_eq!(
            (12e+9 * 8.0) as i64,
            parse_string_to_bytes(gb_string).unwrap()
        );
        assert_eq!(12e+9 as i64, parse_string_to_bytes(gbytes_string).unwrap());
        assert_eq!(12e+6 as i64, parse_string_to_bytes(mbytes_string).unwrap());
        assert_eq!(12, parse_string_to_bytes(bytes_string).unwrap());
        assert_eq!(None, parse_string_to_bytes(invalid_string));
    }

    #[test]
    fn parses_args_allow_values() {
        let flags = [("--test-flag", false), ("--test-value-flag", true)];
        let sorted_args = parse_args(
            &[
                "--test-flag".to_string(),
                "value with space".to_string(),
                "--test-value-flag".to_string(),
                "test-value-flag-value".to_string(),
            ],
            &flags,
            true,
        )
        .unwrap();
        assert_eq!(
            sorted_args.value_flags,
            vec![(
                "--test-value-flag".to_string(),
                Some("test-value-flag-value".to_string())
            )]
        );
        assert_eq!(sorted_args.flags, vec!["--test-flag"]);
        assert_eq!(sorted_args.values, vec!["value with space"]);
    }
}
