use crate::error::{MultError, MultErrorTuple};

#[derive(Debug)]
pub struct ParsedArgs {
    pub flags: Vec<String>,
    pub value_flags: Vec<(String, Option<String>)>,
    pub values: Vec<String>,
}

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


pub fn parse_string_to_bytes(val: String) -> Option<u64> {
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
    let number: u64 = number_str.parse().unwrap();
    if factor_str.len() > 2 {
        return None;
    }
    if factor_str == "B" {
        return Some(number);
    }
    let mut multiplier = match factor_str.to_lowercase().chars().nth(0) {
        Some('b') => { return Some(number / 8) },
        Some('k') => 1000,
        Some('m') => 1e+6 as u64,
        Some('g') => 1e+9 as u64,
        Some('t') => 1e+12 as u64,
        _ => { return None }
    };
    multiplier *= match factor_str.chars().nth(1) {
        Some('b') => 8,
        Some('B') => 1,
        _ => { return None }
    };

    return Some(number as u64 * multiplier);
}

#[cfg(test)]
mod tests {
    use crate::args::parse_string_to_bytes;

    use super::parse_args;

    #[test]
    fn parses_valid_string_to_bytes() {
        let gb_string = String::from("12Gb");
        let gbytes_string = String::from("12GB");
        let mbytes_string = String::from("12mB");
        let bytes_string = String::from("12B");
        assert_eq!((12e+9 * 8.0) as u64, parse_string_to_bytes(gb_string).unwrap());
        assert_eq!(12e+9 as u64, parse_string_to_bytes(gbytes_string).unwrap());
        assert_eq!(12e+6 as u64, parse_string_to_bytes(mbytes_string).unwrap());
        assert_eq!(12, parse_string_to_bytes(bytes_string).unwrap());
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
