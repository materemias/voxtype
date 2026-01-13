//! Transcription worker process for GPU isolation
//!
//! This module implements a subprocess that handles transcription in isolation.
//! When `gpu_isolation = true`, the daemon spawns this worker for each
//! transcription, ensuring the GPU is fully released after transcription
//! completes (the process exits, releasing all GPU resources).
//!
//! Protocol:
//! - stdin: Binary audio data - [u32 sample_count (little-endian)][f32 samples (little-endian)...]
//! - stdout: JSON response - {"ok": true, "text": "..."} or {"ok": false, "error": "..."}
//! - stderr: Log messages (forwarded to parent's log)

use crate::config::WhisperConfig;
use crate::transcribe::Transcriber;
use std::io::{self, Read, Write};
use ureq::serde_json;

/// JSON response from the worker
#[derive(Debug, serde::Serialize)]
#[serde(untagged)]
pub enum WorkerResponse {
    Success { ok: bool, text: String },
    Error { ok: bool, error: String },
}

impl WorkerResponse {
    pub fn success(text: String) -> Self {
        WorkerResponse::Success { ok: true, text }
    }

    pub fn error(msg: impl Into<String>) -> Self {
        WorkerResponse::Error {
            ok: false,
            error: msg.into(),
        }
    }
}

/// Run the transcription worker
///
/// This is the main entry point called from `voxtype transcribe-worker`.
/// It loads the model, reads audio from stdin, transcribes, and writes
/// the result to stdout as JSON.
pub fn run_worker(config: &WhisperConfig) -> anyhow::Result<()> {
    // Lock stdin for binary reading
    let stdin = io::stdin();
    let mut stdin = stdin.lock();

    // Read sample count (u32 little-endian)
    let mut count_buf = [0u8; 4];
    if let Err(e) = stdin.read_exact(&mut count_buf) {
        write_response(WorkerResponse::error(format!(
            "Failed to read sample count: {}",
            e
        )));
        return Ok(());
    }
    let sample_count = u32::from_le_bytes(count_buf) as usize;

    // Validate sample count (prevent OOM from malformed input)
    // Max 10 minutes at 16kHz = 9,600,000 samples = ~38MB
    const MAX_SAMPLES: usize = 16000 * 60 * 10;
    if sample_count > MAX_SAMPLES {
        write_response(WorkerResponse::error(format!(
            "Sample count too large: {} (max {})",
            sample_count, MAX_SAMPLES
        )));
        return Ok(());
    }

    if sample_count == 0 {
        write_response(WorkerResponse::error("Empty audio buffer"));
        return Ok(());
    }

    // Read samples (f32 little-endian)
    let mut samples = vec![0f32; sample_count];
    let samples_bytes = unsafe {
        std::slice::from_raw_parts_mut(
            samples.as_mut_ptr() as *mut u8,
            sample_count * std::mem::size_of::<f32>(),
        )
    };

    if let Err(e) = stdin.read_exact(samples_bytes) {
        write_response(WorkerResponse::error(format!(
            "Failed to read audio samples: {}",
            e
        )));
        return Ok(());
    }

    // Log to stderr (will be captured by parent)
    eprintln!(
        "[worker] Received {} samples ({:.2}s)",
        sample_count,
        sample_count as f32 / 16000.0
    );

    // Create transcriber and load model
    eprintln!("[worker] Loading model: {}", config.model);
    let transcriber = match super::whisper::WhisperTranscriber::new(config) {
        Ok(t) => t,
        Err(e) => {
            write_response(WorkerResponse::error(format!(
                "Failed to load model: {}",
                e
            )));
            return Ok(());
        }
    };

    // Transcribe
    eprintln!("[worker] Starting transcription...");
    let result = transcriber.transcribe(&samples);

    match result {
        Ok(text) => {
            eprintln!("[worker] Transcription complete: {} chars", text.len());
            write_response(WorkerResponse::success(text));
        }
        Err(e) => {
            eprintln!("[worker] Transcription failed: {}", e);
            write_response(WorkerResponse::error(e.to_string()));
        }
    }

    Ok(())
}

/// Write a JSON response to stdout
fn write_response(response: WorkerResponse) {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();

    if let Ok(json) = serde_json::to_string(&response) {
        let _ = writeln!(stdout, "{}", json);
        let _ = stdout.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_worker_response_serialization() {
        let success = WorkerResponse::success("Hello world".to_string());
        let json = serde_json::to_string(&success).unwrap();
        assert!(json.contains(r#""ok":true"#));
        assert!(json.contains(r#""text":"Hello world""#));

        let error = WorkerResponse::error("Something went wrong");
        let json = serde_json::to_string(&error).unwrap();
        assert!(json.contains(r#""ok":false"#));
        assert!(json.contains(r#""error":"Something went wrong""#));
    }
}
