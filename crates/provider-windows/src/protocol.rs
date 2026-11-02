use std::collections::BTreeMap;

use quirewire_domain::BridgeError;

pub const HEADER: &str = "QUIREWIRE_WINDOWS_V1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderRecord {
    fields: BTreeMap<String, String>,
}

impl ProviderRecord {
    pub fn parse(value: &str) -> Result<Self, BridgeError> {
        Self::parse_with_header(value, HEADER)
    }

    pub fn parse_with_header(value: &str, header: &str) -> Result<Self, BridgeError> {
        let normalized = value.replace("\r\n", "\n");
        let mut lines = normalized.lines();
        if lines.next() != Some(header) {
            return Err(protocol_error("missing protocol header"));
        }
        let mut fields = BTreeMap::new();
        for line in lines {
            if line.trim().is_empty() {
                continue;
            }
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| protocol_error("malformed protocol field"))?;
            if key.is_empty()
                || !key
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte == b'_')
            {
                return Err(protocol_error("invalid protocol field name"));
            }
            if fields.insert(key.into(), value.into()).is_some() {
                return Err(protocol_error("duplicate protocol field"));
            }
        }
        Ok(Self { fields })
    }

    pub fn text(&self, key: &str) -> Result<String, BridgeError> {
        let bytes = decode_base64(self.required(key)?)?;
        String::from_utf8(bytes).map_err(|_| protocol_error("field was not UTF-8"))
    }

    pub fn optional_text(&self, key: &str) -> Result<Option<String>, BridgeError> {
        match self.fields.get(key) {
            Some(value) if !value.is_empty() => {
                let bytes = decode_base64(value)?;
                String::from_utf8(bytes)
                    .map(Some)
                    .map_err(|_| protocol_error("field was not UTF-8"))
            }
            _ => Ok(None),
        }
    }

    pub fn boolean(&self, key: &str) -> Result<bool, BridgeError> {
        match self.required(key)? {
            "true" => Ok(true),
            "false" => Ok(false),
            _ => Err(protocol_error("boolean field was invalid")),
        }
    }

    pub fn optional_u32(&self, key: &str) -> Result<Option<u32>, BridgeError> {
        match self.fields.get(key) {
            Some(value) if !value.is_empty() => value
                .parse::<u32>()
                .map(Some)
                .map_err(|_| protocol_error("numeric field was invalid")),
            _ => Ok(None),
        }
    }

    pub fn raw(&self, key: &str) -> Option<&str> {
        self.fields.get(key).map(String::as_str)
    }

    fn required(&self, key: &str) -> Result<&str, BridgeError> {
        self.fields
            .get(key)
            .map(String::as_str)
            .ok_or_else(|| protocol_error("required protocol field was absent"))
    }
}

fn decode_base64(value: &str) -> Result<Vec<u8>, BridgeError> {
    if value.len() % 4 != 0 {
        return Err(protocol_error("base64 field length was invalid"));
    }
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(value.len() / 4 * 3);
    for chunk in bytes.chunks_exact(4) {
        let a = sextet(chunk[0])?;
        let b = sextet(chunk[1])?;
        let c = if chunk[2] == b'=' {
            0
        } else {
            sextet(chunk[2])?
        };
        let d = if chunk[3] == b'=' {
            0
        } else {
            sextet(chunk[3])?
        };
        if chunk[2] == b'=' && chunk[3] != b'=' {
            return Err(protocol_error("base64 padding was invalid"));
        }
        decoded.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            decoded.push((b << 4) | (c >> 2));
        }
        if chunk[3] != b'=' {
            decoded.push((c << 6) | d);
        }
    }
    Ok(decoded)
}

fn sextet(byte: u8) -> Result<u8, BridgeError> {
    match byte {
        b'A'..=b'Z' => Ok(byte - b'A'),
        b'a'..=b'z' => Ok(byte - b'a' + 26),
        b'0'..=b'9' => Ok(byte - b'0' + 52),
        b'+' => Ok(62),
        b'/' => Ok(63),
        _ => Err(protocol_error("base64 field contained an invalid byte")),
    }
}

fn protocol_error(detail: &str) -> BridgeError {
    BridgeError::Internal {
        detail: format!("invalid Windows provider response: {detail}"),
    }
}

#[cfg(test)]
mod tests {
    use super::ProviderRecord;

    #[test]
    fn parses_typed_and_utf8_fields() {
        let record = ProviderRecord::parse(
            "QUIREWIRE_WINDOWS_V1\nok=true\nname=QnJvdGhlciB2aWEgUXVpcmVXaXJl\ncount=42\n",
        )
        .expect("record");
        assert!(record.boolean("ok").expect("bool"));
        assert_eq!(record.text("name").expect("text"), "Brother via QuireWire");
        assert_eq!(record.optional_u32("count").expect("number"), Some(42));
    }

    #[test]
    fn rejects_duplicate_fields_and_invalid_encoding() {
        assert!(ProviderRecord::parse("QUIREWIRE_WINDOWS_V1\nok=true\nok=false\n").is_err());
        let invalid = ProviderRecord::parse("QUIREWIRE_WINDOWS_V1\nname=***=\n").expect("syntax");
        assert!(invalid.text("name").is_err());
    }
}
