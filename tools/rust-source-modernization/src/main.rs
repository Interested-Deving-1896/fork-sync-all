use serde::Deserialize;
use std::{env, fs, path::PathBuf, process};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema_version: u32,
    project: String,
    source_root: PathBuf,
    languages: Vec<String>,
    target: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
struct PlanItem {
    component: String,
    strategy: &'static str,
    status: &'static str,
    reason: String,
}

fn usage() {
    eprintln!("Usage: rsm <plan|validate-manifest> <manifest.json> [--json]");
}

fn parse_manifest(raw: &str) -> Result<Manifest, String> {
    let manifest: Manifest = serde_json::from_str(raw)
        .map_err(|e| format!("invalid manifest JSON/schema: {e}"))?;
    if manifest.schema_version != 1 {
        return Err(format!("unsupported schema_version {}; expected 1", manifest.schema_version));
    }
    if manifest.project.trim().is_empty() {
        return Err("project must not be empty".into());
    }
    if manifest.source_root.as_os_str().is_empty() {
        return Err("source_root must not be empty".into());
    }
    if manifest.target.trim().is_empty() {
        return Err("target must not be empty".into());
    }
    if manifest.languages.is_empty() {
        return Err("languages must contain at least one entry".into());
    }
    if manifest.languages.iter().any(|l| l.trim().is_empty()) {
        return Err("languages entries must not be empty".into());
    }
    Ok(manifest)
}

fn make_plan(manifest: &Manifest) -> Vec<PlanItem> {
    let mut languages = manifest.languages.clone();
    languages.sort_by_key(|s| s.to_ascii_lowercase());
    languages.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
    languages.into_iter().map(|lang| {
        let strategy = match lang.to_ascii_lowercase().as_str() {
            "c" | "c89" | "c90" | "c99" | "c11" | "c17" | "c23" =>
                "translation-candidate",
            "c++" | "cpp" | "cxx" | "c++03" | "c++11" | "c++14" | "c++17" | "c++20" | "c++23" =>
                "translation-candidate-or-hybrid",
            "rust" => "native-rust",
            _ => "unsupported",
        };
        let (status, reason) = match strategy {
            "unsupported" => ("blocked", "No adapter registered; preserve source and require explicit decision"),
            "native-rust" => ("ready-for-validation", "Already Rust; baseline compile and tests are still required"),
            _ => ("needs-backend-selection", "Planner does not execute translators; select and pin an audited adapter"),
        };
        PlanItem { component: lang, strategy, status, reason: reason.into() }
    }).collect()
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let command = args.next().ok_or_else(|| "missing command".to_string())?;
    let file = args.next().ok_or_else(|| "missing manifest path".to_string())?;
    let json = match args.next().as_deref() {
        None => false,
        Some("--json") => true,
        Some(other) => return Err(format!("unknown argument: {other}")),
    };
    if args.next().is_some() {
        return Err("too many arguments".into());
    }
    if command != "plan" && command != "validate-manifest" {
        return Err(format!("unknown command: {command}"));
    }
    let path = PathBuf::from(file);
    let raw = fs::read_to_string(&path)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let manifest = parse_manifest(&raw)?;
    if command == "validate-manifest" {
        println!("Manifest valid (schema v1).");
        return Ok(());
    }
    let plan = make_plan(&manifest);
    if json {
        let output = serde_json::json!({
            "schema_version": manifest.schema_version,
            "project": manifest.project,
            "source_root": manifest.source_root,
            "target": manifest.target,
            "plan": plan
        });
        println!("{}", serde_json::to_string_pretty(&output).map_err(|e| e.to_string())?);
    } else {
        println!("Project: {}\nSource root: {}\nTarget: {}", manifest.project, manifest.source_root.display(), manifest.target);
        for item in plan {
            println!("- {} | {} | {} | {}", item.component, item.strategy, item.status, item.reason);
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        usage();
        process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = r#"{
      "schema_version": 1,
      "project": "fixture",
      "source_root": "./src",
      "languages": ["C", "Rust", "Fortran"],
      "target": "x86_64-unknown-linux-gnu"
    }"#;

    #[test]
    fn parses_valid_manifest() {
        let parsed = parse_manifest(VALID).unwrap();
        assert_eq!(parsed.project, "fixture");
        assert_eq!(parsed.languages.len(), 3);
    }

    #[test]
    fn rejects_invalid_json() {
        assert!(parse_manifest("{").unwrap_err().contains("invalid manifest"));
    }

    #[test]
    fn rejects_unsupported_schema() {
        let raw = VALID.replace("\"schema_version\": 1", "\"schema_version\": 2");
        assert!(parse_manifest(&raw).unwrap_err().contains("unsupported schema_version"));
    }

    #[test]
    fn rejects_empty_languages() {
        let raw = VALID.replace("\"C\", \"Rust\", \"Fortran\"", "");
        let raw = raw.replace("\"languages\": []", "\"languages\": []");
        assert!(parse_manifest(&raw).unwrap_err().contains("at least one"));
    }

    #[test]
    fn plan_classifies_and_is_deterministic() {
        let parsed = parse_manifest(VALID).unwrap();
        let first = make_plan(&parsed);
        let second = make_plan(&parsed);
        assert_eq!(first, second);
        assert!(first.iter().any(|p| p.component == "C" && p.status == "needs-backend-selection"));
        assert!(first.iter().any(|p| p.component == "Rust" && p.status == "ready-for-validation"));
        assert!(first.iter().any(|p| p.component == "Fortran" && p.status == "blocked"));
    }
}
