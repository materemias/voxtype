//! Subprocess-based transcription for GPU isolation
//!
//! This module provides a transcriber that spawns a subprocess for each
//! transcription. When the subprocess exits, all GPU resources are fully
//! released. This solves the problem of GPU memory staying allocated
//! between transcriptions when using ggml-vulkan.
//!
//! Key benefits:
//! - GPU memory fully released after each transcription
//! - No GPU power draw between transcriptions (important for laptops)
//! - Clean separation of concerns
//!
//! Trade-offs:
//! - Model loading happens once per transcription
//! - Slightly higher latency (but model loads while user speaks)

use super::Transcriber;
use crate::config::WhisperConfig;
use crate::error::TranscribeError;
use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use ureq::serde_json;

/// Response from the transcription worker process
#[derive(Debug, serde::Deserialize)]
struct WorkerResponse {
    ok: bool,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// Subprocess-based transcriber for GPU isolation
///
/// Spawns a fresh `voxtype transcribe-worker` process for each transcription.
/// The worker loads the model, transcribes, returns the result, and exits.
/// This ensures all GPU resources are released after transcription.
pub struct SubprocessTranscriber {
    /// Config to pass to the worker
    config: WhisperConfig,
    /// Path to the config file (if any)
    config_path: Option<std::path::PathBuf>,
}

impl SubprocessTranscriber {
    /// Create a new subprocess transcriber
    pub fn new(
        config: &WhisperConfig,
        config_path: Option<std::path::PathBuf>,
    ) -> Result<Self, TranscribeError> {
        Ok(Self {
            config: config.clone(),
            config_path,
        })
    }

    /// Get the path to the voxtype executable
    fn get_executable_path() -> Result<std::path::PathBuf, TranscribeError> {
        std::env::current_exe()
            .map_err(|e| TranscribeError::InitFailed(format!("Cannot find voxtype executable: {}", e)))
    }

    /// Spawn a worker process
    fn spawn_worker(&self) -> Result<Child, TranscribeError> {
        let exe_path = Self::get_executable_path()?;

        let mut cmd = Command::new(&exe_path);
        cmd.arg("transcribe-worker")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        // Pass config path if we have one
        if let Some(ref config_path) = self.config_path {
            cmd.arg("--config").arg(config_path);
        }

        // Pass essential config via command-line arguments
        cmd.arg("--model").arg(&self.config.model);
        cmd.arg("--language").arg(&self.config.language);
        if self.config.translate {
            cmd.arg("--translate");
        }
        if let Some(threads) = self.config.threads {
            cmd.arg("--threads").arg(threads.to_string());
        }

        cmd.spawn().map_err(|e| {
            TranscribeError::InitFailed(format!("Failed to spawn transcribe-worker: {}", e))
        })
    }

    /// Write audio samples to the worker's stdin
    fn write_audio_to_worker(
        stdin: &mut std::process::ChildStdin,
        samples: &[f32],
    ) -> Result<(), TranscribeError> {
        // Write sample count (u32 little-endian)
        let count = samples.len() as u32;
        stdin
            .write_all(&count.to_le_bytes())
            .map_err(|e| TranscribeError::InferenceFailed(format!("Failed to write sample count: {}", e)))?;

        // Write samples (f32 little-endian)
        let samples_bytes = unsafe {
            std::slice::from_raw_parts(
                samples.as_ptr() as *const u8,
                samples.len() * std::mem::size_of::<f32>(),
            )
        };
        stdin.write_all(samples_bytes).map_err(|e| {
            TranscribeError::InferenceFailed(format!("Failed to write audio samples: {}", e))
        })?;

        stdin.flush().map_err(|e| {
            TranscribeError::InferenceFailed(format!("Failed to flush stdin: {}", e))
        })?;

        Ok(())
    }

    /// Read the response from the worker's stdout
    fn read_worker_response(
        stdout: &mut std::process::ChildStdout,
    ) -> Result<WorkerResponse, TranscribeError> {
        let mut output = String::new();
        stdout.read_to_string(&mut output).map_err(|e| {
            TranscribeError::InferenceFailed(format!("Failed to read worker output: {}", e))
        })?;

        // Parse the last line as JSON (worker may have written multiple lines)
        let last_line = output.lines().last().unwrap_or("");

        serde_json::from_str(last_line).map_err(|e| {
            TranscribeError::InferenceFailed(format!(
                "Failed to parse worker response: {} (output: {:?})",
                e, output
            ))
        })
    }
}

impl Transcriber for SubprocessTranscriber {
    fn transcribe(&self, samples: &[f32]) -> Result<String, TranscribeError> {
        if samples.is_empty() {
            return Err(TranscribeError::AudioFormat("Empty audio buffer".to_string()));
        }

        let duration_secs = samples.len() as f32 / 16000.0;
        tracing::debug!(
            "Spawning subprocess for {:.2}s of audio ({} samples)",
            duration_secs,
            samples.len()
        );

        // Spawn worker process
        let start = std::time::Instant::now();
        let mut child = self.spawn_worker()?;

        // Get handles to stdin/stdout
        let mut stdin = child.stdin.take().ok_or_else(|| {
            TranscribeError::InitFailed("Worker stdin not available".to_string())
        })?;

        let mut stdout = child.stdout.take().ok_or_else(|| {
            TranscribeError::InitFailed("Worker stdout not available".to_string())
        })?;

        // Write audio to worker
        Self::write_audio_to_worker(&mut stdin, samples)?;
        drop(stdin); // Close stdin to signal EOF

        // Read response
        let response = Self::read_worker_response(&mut stdout)?;

        // Wait for process to exit
        let status = child.wait().map_err(|e| {
            TranscribeError::InferenceFailed(format!("Failed to wait for worker: {}", e))
        })?;

        if !status.success() {
            // Try to get stderr for error details
            if let Some(mut stderr) = child.stderr.take() {
                let mut err_output = String::new();
                let _ = stderr.read_to_string(&mut err_output);
                if !err_output.is_empty() {
                    tracing::warn!("Worker stderr: {}", err_output.trim());
                }
            }
        }

        tracing::debug!(
            "Subprocess transcription completed in {:.2}s",
            start.elapsed().as_secs_f32()
        );

        // Handle response
        if response.ok {
            response.text.ok_or_else(|| {
                TranscribeError::InferenceFailed("Worker returned ok but no text".to_string())
            })
        } else {
            Err(TranscribeError::InferenceFailed(
                response.error.unwrap_or_else(|| "Unknown worker error".to_string()),
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_worker_response_parsing() {
        let success: WorkerResponse =
            serde_json::from_str(r#"{"ok": true, "text": "Hello world"}"#).unwrap();
        assert!(success.ok);
        assert_eq!(success.text, Some("Hello world".to_string()));

        let error: WorkerResponse =
            serde_json::from_str(r#"{"ok": false, "error": "Model not found"}"#).unwrap();
        assert!(!error.ok);
        assert_eq!(error.error, Some("Model not found".to_string()));
    }
}
