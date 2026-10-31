use std::{env, fs, path::PathBuf, process};

#[derive(Debug, Clone)]
struct Project {
    name: String,
    source_root: PathBuf,
    languages: Vec<String>,
    target: String,
}

#[derive(Debug)]
struct PlanItem {
    component: String,
    strategy: &'static str,
    status: &'static str,
    reason: String,
}

fn usage() {
    eprintln!("Usage: rsm <plan|validate-manifest> <manifest.json> [--json]");
}

fn main() {
    let mut args = env::args().skip(1);
    let command = args.next().unwrap_or_default();
    let manifest = args.next().map(PathBuf::from);
    if command.is_empty() || manifest.is_none() {
        usage();
        process::exit(2);
    }
    let path = manifest.unwrap();
    let raw = match fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => { eprintln!("error: cannot read {}: {e}", path.display()); process::exit(2); }
    };
    // Keep the first release dependency-free. Validate the required manifest keys
    // conservatively; JSON parsing is added with the schema/versioned core next.
    let required = ["schema_version", "project", "source_root", "languages", "target"];
    let missing: Vec<_> = required.iter().filter(|key| !raw.contains(&format!("\\"{key}\\""))).collect();
    if !missing.is_empty() {
        eprintln!("error: manifest is missing required fields: {}", missing.iter().map(|s| **s).collect::<Vec<_>>().join(", "));
        process::exit(2);
    }
    if command == "validate-manifest" {
        println!("manifest contains required keys (structural check only)");
        return;
    }
    if command != "plan" { usage(); process::exit(2); }
    let project = Project { name: extract_string(&raw, "project").unwrap_or_else(|| "unnamed".into()),
        source_root: PathBuf::from(extract_string(&raw, "source_root").unwrap_or_else(|| ".".into())),
        languages: extract_array(&raw, "languages"),
        target: extract_string(&raw, "target").unwrap_or_else(|| "host".into()) };
    let plan = make_plan(&project);
    println!("Project: {}\\nSource root: {}\\nTarget: {}", project.name, project.source_root.display(), project.target);
    for item in plan { println!("- {} | {} | {} | {}", item.component, item.strategy, item.status, item.reason); }
}

fn make_plan(project: &Project) -> Vec<PlanItem> {
    project.languages.iter().map(|lang| {
        let strategy = match lang.to_ascii_lowercase().as_str() {
            "c" | "c99" | "c11" => "translation-candidate",
            "c++" | "cpp" | "cxx" => "translation-candidate-or-hybrid",
            "rust" => "native-rust",
            other => { let _ = other; "unsupported" }
        };
        let (status, reason) = if strategy == "unsupported" {
            ("blocked", "No backend selected; preserve sources and require explicit adapter")
        } else if strategy == "native-rust" {
            ("ready-for-validation", "Already Rust; compile/test baseline before changes")
        } else {
            ("needs-backend-selection", "Planner does not invoke a translator; choose and pin an audited adapter")
        };
        PlanItem { component: lang.clone(), strategy, status, reason: reason.into() }
    }).collect()
}

// Small fixture-only readers; replaced by serde/schema validation in the next
// increment. They intentionally do not pretend to parse arbitrary JSON.
fn extract_string(raw: &str, key: &str) -> Option<String> {
    let needle = format!("\\"{key}\\"");
    let start = raw.find(&needle)? + needle.len();
    let tail = raw[start..].trim_start();
    let tail = tail.strip_prefix(':')?.trim_start().strip_prefix('\\"')?;
    Some(tail.split('\\"').next()?.to_string())
}
fn extract_array(raw: &str, key: &str) -> Vec<String> {
    let needle = format!("\\"{key}\\"");
    let Some(start) = raw.find(&needle).map(|i| i + needle.len()) else { return vec![]; };
    let Some(open) = raw[start..].find('[').map(|i| start + i) else { return vec![]; };
    let Some(close) = raw[open..].find(']').map(|i| open + i) else { return vec![]; };
    raw[open + 1..close].split(',').filter_map(|s| s.trim().trim_matches('\\"').to_string().into()).collect()
}
