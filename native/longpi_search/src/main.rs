//! longpi_search — cross-platform code search for the Longpi grep/find tools.
//!
//! Wraps ripgrep's and fd's own engine crates (`grep-*`, `ignore`, `globset`)
//! so the search runs natively on every platform with no external binary. The
//! Elixir side invokes it as `longpi_search <grep|find> <json-args>` and reads
//! a JSON result from stdout.

use globset::{Glob, GlobSetBuilder};
use grep_regex::RegexMatcherBuilder;
use grep_searcher::{Searcher, SearcherBuilder, Sink, SinkContext, SinkMatch};
use ignore::overrides::OverrideBuilder;
use ignore::WalkBuilder;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Deserialize)]
struct GrepArgs {
    pattern: String,
    path: Option<String>,
    glob: Option<String>,
    #[serde(default)]
    ignore_case: bool,
    #[serde(default)]
    literal: bool,
    #[serde(default)]
    context: usize,
    limit: Option<usize>,
}

#[derive(Deserialize)]
struct FindArgs {
    pattern: String,
    path: Option<String>,
    limit: Option<usize>,
}

#[derive(Serialize)]
struct GrepMatch {
    path: String,
    line: u64,
    text: String,
    kind: &'static str, // "match" | "context"
}

#[derive(Serialize)]
struct GrepResult {
    matches: Vec<GrepMatch>,
    count: usize,
    limit_reached: bool,
}

#[derive(Serialize)]
struct FindResult {
    files: Vec<String>,
    count: usize,
    limit_reached: bool,
}

const GREP_DEFAULT_LIMIT: usize = 100;
const FIND_DEFAULT_LIMIT: usize = 1000;
const MAX_LINE_LEN: usize = 2000;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("");
    let json = args.get(2).map(String::as_str).unwrap_or("{}");

    let result = match cmd {
        "grep" => run_grep(json),
        "find" => run_find(json),
        other => Err(format!("unknown command: {other}")),
    };

    match result {
        Ok(output) => println!("{output}"),
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(1);
        }
    }
}

fn search_root(path: &Option<String>) -> String {
    path.clone().unwrap_or_else(|| ".".to_string())
}

fn relative(root: &Path, entry: &Path) -> String {
    entry
        .strip_prefix(root)
        .unwrap_or(entry)
        .to_string_lossy()
        .into_owned()
}

fn run_grep(json: &str) -> Result<String, String> {
    let args: GrepArgs = serde_json::from_str(json).map_err(|e| format!("bad args: {e}"))?;
    let limit = args.limit.unwrap_or(GREP_DEFAULT_LIMIT).max(1);
    let root = search_root(&args.path);
    let root_path = Path::new(&root);

    let regex = if args.literal {
        regex_escape(&args.pattern)
    } else {
        args.pattern.clone()
    };

    let matcher = RegexMatcherBuilder::new()
        .case_insensitive(args.ignore_case)
        .build(&regex)
        .map_err(|e| format!("invalid pattern: {e}"))?;

    let mut searcher = SearcherBuilder::new()
        .line_number(true)
        .before_context(args.context)
        .after_context(args.context)
        .build();

    // Optional file filter, e.g. "*.ex" or "**/*.spec.ts". OverrideBuilder is
    // exactly what ripgrep's --glob uses, so the semantics match (a bare "*.ex"
    // filters by basename across the whole tree).
    let mut walk = WalkBuilder::new(&root);
    walk.hidden(false);
    if let Some(g) = &args.glob {
        if !g.is_empty() {
            let mut ob = OverrideBuilder::new(&root);
            ob.add(g).map_err(|e| format!("invalid glob: {e}"))?;
            walk.overrides(ob.build().map_err(|e| format!("invalid glob: {e}"))?);
        }
    }

    let mut matches = Vec::new();
    let mut count = 0usize;
    let mut limit_reached = false;

    for entry in walk.build() {
        if count >= limit {
            limit_reached = true;
            break;
        }
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        if !entry.file_type().map_or(false, |t| t.is_file()) {
            continue;
        }
        let path = entry.path();

        let rel = relative(root_path, path);
        let mut sink = CollectSink {
            path: rel,
            matches: &mut matches,
            count: &mut count,
            limit,
            limit_reached: &mut limit_reached,
        };
        // Ignore per-file read errors (binary/unreadable files).
        let _ = searcher.search_path(&matcher, path, &mut sink);
    }

    let result = GrepResult {
        matches,
        count,
        limit_reached,
    };
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

struct CollectSink<'a> {
    path: String,
    matches: &'a mut Vec<GrepMatch>,
    count: &'a mut usize,
    limit: usize,
    limit_reached: &'a mut bool,
}

impl<'a> Sink for CollectSink<'a> {
    type Error = std::io::Error;

    fn matched(&mut self, _searcher: &Searcher, mat: &SinkMatch) -> Result<bool, std::io::Error> {
        let line = mat.line_number().unwrap_or(0);
        self.matches.push(GrepMatch {
            path: self.path.clone(),
            line,
            text: clean_line(mat.bytes()),
            kind: "match",
        });
        *self.count += 1;
        if *self.count >= self.limit {
            *self.limit_reached = true;
            return Ok(false);
        }
        Ok(true)
    }

    fn context(
        &mut self,
        _searcher: &Searcher,
        ctx: &SinkContext,
    ) -> Result<bool, std::io::Error> {
        let line = ctx.line_number().unwrap_or(0);
        self.matches.push(GrepMatch {
            path: self.path.clone(),
            line,
            text: clean_line(ctx.bytes()),
            kind: "context",
        });
        Ok(true)
    }
}

fn clean_line(bytes: &[u8]) -> String {
    let mut s = String::from_utf8_lossy(bytes).into_owned();
    while s.ends_with('\n') || s.ends_with('\r') {
        s.pop();
    }
    if s.len() > MAX_LINE_LEN {
        let mut end = MAX_LINE_LEN;
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        s.truncate(end);
        s.push_str(" …[truncated]");
    }
    s
}

fn run_find(json: &str) -> Result<String, String> {
    let args: FindArgs = serde_json::from_str(json).map_err(|e| format!("bad args: {e}"))?;
    let limit = args.limit.unwrap_or(FIND_DEFAULT_LIMIT).max(1);
    let root = search_root(&args.path);
    let root_path = Path::new(&root);

    // fd matches the basename unless the pattern contains a slash, in which case
    // it matches the full path (so "src/**/*.ex" needs a leading **/).
    let has_slash = args.pattern.contains('/');
    let pattern = if has_slash && !args.pattern.starts_with("**/") && !args.pattern.starts_with('/')
    {
        format!("**/{}", args.pattern)
    } else {
        args.pattern.clone()
    };

    let mut b = GlobSetBuilder::new();
    b.add(Glob::new(&pattern).map_err(|e| format!("invalid glob: {e}"))?);
    let glob_set = b.build().map_err(|e| format!("invalid glob: {e}"))?;

    let mut files = Vec::new();
    let mut limit_reached = false;

    let walk = WalkBuilder::new(&root).hidden(false).build();
    for entry in walk {
        if files.len() >= limit {
            limit_reached = true;
            break;
        }
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        if path == root_path {
            continue;
        }

        let candidate = if has_slash {
            path.strip_prefix(root_path).unwrap_or(path).to_path_buf()
        } else {
            match path.file_name() {
                Some(name) => Path::new(name).to_path_buf(),
                None => continue,
            }
        };

        if glob_set.is_match(&candidate) {
            files.push(relative(root_path, path));
        }
    }

    let count = files.len();
    let result = FindResult {
        files,
        count,
        limit_reached,
    };
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// Escapes regex metacharacters so a pattern is matched literally.
fn regex_escape(pattern: &str) -> String {
    let mut out = String::with_capacity(pattern.len());
    for c in pattern.chars() {
        if "\\.+*?()|[]{}^$#&-~".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}
