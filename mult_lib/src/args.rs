use crate::error::{MultError, MultErrorTuple};

pub struct ParsedArgs {
    pub flags: Vec<String>,
    pub value_flags: Vec<(String, Option<String>)>,
    pub values: Vec<String>
}

// flags is an array of the name of the flag like --watch and if the flag has a value
pub fn parse_args(
    args: &[String], 
    flags: &[(&str, bool)], 
    allow_values: bool
) -> Result<ParsedArgs, MultErrorTuple> {
    let mut parsed_args = ParsedArgs {
        flags: Vec::new(),
        value_flags: Vec::new(),
        values: Vec::new()
    };
    if args.len() == 0 {
        return Ok(parsed_args);
    }
    let mut arg_idx = 0;
    let mut arg = &args[arg_idx];
    if let Some(flag) = flags.iter().find(|val| val.0 == arg) {
        if flag.1 {
            parsed_args.value_flags.push(
                (arg.to_string(), Some(args[arg_idx + 1].to_string()))
            );
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
                parsed_args.value_flags.push(
                    (arg.to_string(), Some(args[arg_idx + 1].to_string()))
                );
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

#[cfg(test)]
mod tests {
    use super::parse_args;

    #[test]
    fn parses_args_allow_values() {
        let flags = [
            ("--test-flag", false),
            ("--test-value-flag", true),
        ];
        let sorted_args = parse_args(&[
            "--test-flag".to_string(),
            "--test-value-flag".to_string(),
            "test-value-flag-value".to_string(),
            "value with space".to_string()
        ], &flags, true).unwrap();
        assert_eq!(
            sorted_args.value_flags,
            vec![("--test-value-flag".to_string(), Some("test-value-flag-value".to_string()))]
        );
        assert_eq!(sorted_args.flags, vec!["--test-flag"]);
        assert_eq!(sorted_args.values, vec!["value with space"]);
    }
}

