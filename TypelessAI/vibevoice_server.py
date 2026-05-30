#!/usr/bin/env python3
"""
TypelessPlus VibeVoice ASR 服务端
- Microsoft VibeVoice-ASR-4bit (7B 参数语音大模型)
- 通过 GGUF 量化模型实现本地推理
- 支持说话人分离、词级时间戳、50+ 语言
- 通过 stdin/stdout JSON 协议与 Swift 主进程通信
"""

import sys
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

MODEL_DIR = Path(__file__).parent.parent / "models"
os.makedirs(MODEL_DIR, exist_ok=True)

DEFAULT_MODEL = "vibevoice-asr-q4_k.gguf"
CRISPARS_BIN = None


def find_crispasr_bin():
    global CRISPARS_BIN
    if CRISPARS_BIN is not None:
        return CRISPARS_BIN

    candidates = [
        MODEL_DIR / "crispasr",
        MODEL_DIR / "bin" / "crispasr",
        Path("/usr/local/bin/crispasr"),
        Path("/opt/homebrew/bin/crispasr"),
    ]

    project_root = Path(__file__).parent.parent
    for candidate in candidates:
        if candidate.exists():
            CRISPARS_BIN = str(candidate)
            return CRISPARS_BIN

    try:
        result = subprocess.run(
            ["which", "crispasr"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            CRISPARS_BIN = result.stdout.strip()
            return CRISPARS_BIN
    except Exception:
        pass

    return None


def find_model_path(model_name: str = DEFAULT_MODEL) -> str:
    model_path = MODEL_DIR / model_name
    if model_path.exists():
        return str(model_path)

    alt_path = MODEL_DIR / "gguf" / model_name
    if alt_path.exists():
        return str(alt_path)

    return str(model_path)


def preprocess_audio(input_path: str, output_path: str = None) -> str:
    if output_path is None:
        fd, output_path = tempfile.mkstemp(suffix=".wav", prefix="vv_")
        os.close(fd)

    try:
        cmd = [
            "ffmpeg", "-y", "-i", input_path,
            "-ar", "24000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            output_path
        ]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {result.stderr}")
        return output_path
    except FileNotFoundError:
        raise RuntimeError("ffmpeg not found. Please install ffmpeg: brew install ffmpeg")


class VibeVoiceTranscriber:
    def __init__(self, model_name: str = DEFAULT_MODEL):
        self.model_name = model_name
        self.model_path = find_model_path(model_name)
        self.crispasr_bin = find_crispasr_bin()
        self._validate_environment()

    def _validate_environment(self):
        errors = []

        if not Path(self.model_path).exists():
            errors.append(f"Model file not found: {self.model_path}")

        if self.crispasr_bin is None or not Path(self.crispasr_bin).exists():
            errors.append("crispasr binary not found. Build from https://github.com/CrispStrobe/CrispASR")

        if errors:
            raise EnvironmentError("; ".join(errors))

    def transcribe(self, audio_path: str, language: str = "auto",
                   hotwords: str = "") -> dict:
        processed_audio = None
        try:
            processed_audio = preprocess_audio(audio_path)

            cmd = [
                self.crispasr_bin,
                "--model", self.model_path,
                "--file", processed_audio,
                "--backend", "vibevoice",
                "--output-format", "json",
            ]

            if language and language != "auto":
                cmd.extend(["--language", language])

            if hotwords:
                cmd.extend(["--context", hotwords])

            env = os.environ.copy()
            env["PYTHONUNBUFFERED"] = "1"

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,
                env=env
            )

            if result.returncode != 0:
                error_msg = result.stderr.strip() or "Unknown error"
                if "timeout" in error_msg.lower():
                    raise TimeoutError(f"VibeVoice inference timeout: {error_msg}")
                raise RuntimeError(f"crispasr error: {error_msg}")

            output_text = result.stdout.strip()

            try:
                segments = json.loads(output_text)
            except json.JSONDecodeError:
                if output_text:
                    segments = [{"text": output_text}]
                else:
                    segments = []

            combined_text = " ".join(
                seg.get("text", "") for seg in segments if seg.get("text")
            ).strip()

            speaker_info = ""
            if len(segments) > 1:
                speakers = set(seg.get("speaker_id", "Speaker_0") for seg in segments)
                if len(speakers) > 1:
                    speaker_info = f" [多说话人: {', '.join(sorted(speakers))}]"

            detected_lang = self._detect_language(combined_text)

            return {
                "text": combined_text,
                "raw_segments": segments,
                "model": self.model_name,
                "detected_lang": detected_lang,
                "speaker_info": speaker_info,
                "segment_count": len(segments),
            }

        finally:
            if processed_audio and Path(processed_audio).exists():
                try:
                    Path(processed_audio).unlink()
                except OSError:
                    pass

    @staticmethod
    def _detect_language(text: str) -> str:
        if not text:
            return "unknown"
        chinese_chars = sum(1 for c in text if '\u4e00' <= c <= '\u9fff')
        total_alpha = sum(1 for c in text if c.isalpha())
        if chinese_chars > total_alpha:
            return "zh"
        elif total_alpha > chinese_chars:
            return "en"
        else:
            return "mixed"


class IPCServer:
    def __init__(self):
        self.transcriber = None

    def handle(self, request: dict) -> dict:
        cmd = request.get("command", "")

        if cmd == "init":
            model = request.get("model", DEFAULT_MODEL)
            try:
                self.transcriber = VibeVoiceTranscriber(model)
                return {
                    "status": "ok",
                    "model": model,
                    "engine": "vibevoice-asr-4bit",
                    "model_path": self.transcriber.model_path,
                }
            except Exception as e:
                return {"status": "error", "message": str(e)}

        elif cmd == "transcribe":
            if not self.transcriber:
                return {"status": "error", "message": "Not initialized"}

            audio_path = request.get("audio_path", "")
            language = request.get("language", "auto")
            hotwords = request.get("hotwords", "")
            post_process = request.get("post_process", True)

            if not audio_path or not os.path.exists(audio_path):
                return {"status": "error", "message": f"File not found: {audio_path}"}

            try:
                result = self.transcriber.transcribe(
                    audio_path, language=language, hotwords=hotwords
                )
                text = result["text"]
                raw = text

                if post_process:
                    text = self._post_process(text, language)

                return {
                    "status": "ok",
                    "text": text,
                    "raw": raw,
                    "lang": result["detected_lang"],
                    "segments": result["segment_count"],
                    "speaker_info": result.get("speaker_info", ""),
                }
            except TimeoutError as e:
                return {"status": "error", "message": f"Timeout: {e}"}
            except Exception as e:
                return {"status": "error", "message": str(e)}

        elif cmd == "ping":
            return {"status": "ok", "pong": True, "engine": "vibevoice"}

        elif cmd == "info":
            if not self.transcriber:
                return {"status": "error", "message": "Not initialized"}
            return {
                "status": "ok",
                "engine": "VibeVoice-ASR-4bit",
                "model": self.transcriber.model_name,
                "model_path": self.transcriber.model_path,
                "crispasr": self.transcriber.crispasr_bin,
            }

        else:
            return {"status": "error", "message": f"Unknown command: {cmd}"}

    @staticmethod
    def _post_process(text: str, lang: str) -> str:
        text = re.sub(r'\s+', ' ', text).strip()
        if text and text[-1] not in '.!?。！？':
            text += '。'
        return text

    def run(self):
        sys.stderr.write("[vibevoice_server] VibeVoice ASR Service Ready\n")
        sys.stderr.write("[vibevoice_server] Engine: Microsoft VibeVoice-ASR-4bit (7B)\n")
        sys.stderr.flush()

        while True:
            try:
                line = sys.stdin.readline()
                if not line:
                    break
                request = json.loads(line.strip())
                response = self.handle(request)
                sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
                sys.stdout.flush()
            except json.JSONDecodeError:
                sys.stderr.write("[vibevoice_server] Invalid JSON\n")
                sys.stderr.flush()
            except KeyboardInterrupt:
                break
            except Exception as e:
                response = {"status": "error", "message": str(e)}
                sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
                sys.stdout.flush()


if __name__ == "__main__":
    server = IPCServer()
    server.run()
