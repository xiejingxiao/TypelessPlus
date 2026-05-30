#!/usr/bin/env python3
"""
TypelessPlus AI 服务端
- faster-whisper 语音识别（CTranslate2 后端）
- 文本后处理（去填充词、去重复、标点恢复、繁→简转换）
- LLM 润色（OpenAI 兼容 API）
- 通过 stdin/stdout JSON 协议与 Swift 主进程通信
"""

import sys
import json
import os
import re
from pathlib import Path

# HF 镜像，国内网络加速模型下载
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

MODEL_DIR = Path(__file__).parent.parent / "models"
os.makedirs(MODEL_DIR, exist_ok=True)

# 繁→简转换器（延迟加载）
_t2s_converter = None


def _get_t2s_converter():
    global _t2s_converter
    if _t2s_converter is None:
        try:
            from opencc import OpenCC
            cc = OpenCC('t2s')
            _t2s_converter = cc.convert
        except ImportError:
            try:
                from zhconv import convert
                _t2s_converter = lambda t: convert(t, 'zh-cn')
            except ImportError:
                _t2s_converter = None
    return _t2s_converter


def to_simplified(text: str) -> str:
    conv = _get_t2s_converter()
    if conv is None:
        return text
    try:
        return conv(text)
    except Exception:
        return text


class TextProcessor:
    """文本后处理：去填充词、去重复、标点恢复、繁转简"""

    FILLER_WORDS = {
        "zh": ["嗯", "啊", "呃", "那个", "这个", "就是说", "然后呢", "对吧", "怎么说呢", "反正"],
        "en": ["um", "uh", "er", "like", "you know", "i mean", "so", "actually", "basically", "literally"],
    }

    REPEAT_PATTERN_EN = re.compile(r"\b(\w+(?:\s+\w+){0,3})\s+\1\b", re.IGNORECASE)
    REPEAT_PATTERN_ZH = re.compile(r"(.{2,10})\1")

    @classmethod
    def remove_fillers(cls, text: str, lang: str = "zh") -> str:
        fillers = cls.FILLER_WORDS.get(lang, cls.FILLER_WORDS["zh"])
        for fw in sorted(fillers, key=len, reverse=True):
            text = re.sub(rf"\s*{re.escape(fw)}\s*", " ", text)
        return re.sub(r"\s+", " ", text).strip()

    @classmethod
    def remove_repeats(cls, text: str, lang: str = "auto") -> str:
        prev = None
        while prev != text:
            prev = text
            text = cls.REPEAT_PATTERN_EN.sub(r"\1", text)
        if lang != "en":
            prev = None
            while prev != text:
                prev = text
                text = cls.REPEAT_PATTERN_ZH.sub(r"\1", text)
        return text

    @classmethod
    def restore_punctuation(cls, text: str) -> str:
        text = re.sub(r"([a-zA-Z0-9])\s+([a-zA-Z0-9])", r"\1 \2", text)
        text = re.sub(r"\s{2,}", " ", text)
        text = text.strip()
        if text and text[-1] not in ".!?。！？":
            text += "。"
        return text

    @classmethod
    def process(cls, text: str, lang: str = "auto") -> str:
        # Step 1: 繁体 → 简体（最早执行，确保后续处理都在简体上做）
        text = to_simplified(text)

        # Step 2: 去填充词
        text = cls.remove_fillers(text, lang)

        # Step 3: 去重复
        text = cls.remove_repeats(text, lang)

        # Step 4: 标点恢复
        text = cls.restore_punctuation(text)

        return text


class WhisperTranscriber:
    """faster-whisper 封装（CTranslate2 后端，macOS 原生加速）"""

    def __init__(self, model_name: str = "base"):
        self.model_name = model_name
        self._model = None
        self._load_model()

    def _load_model(self):
        from faster_whisper import WhisperModel
        compute_type = "int8"
        self._model = WhisperModel(
            self.model_name,
            device="cpu",
            compute_type=compute_type,
            download_root=str(MODEL_DIR),
            num_workers=1,
        )

    def transcribe(self, audio_path: str, language: str = "auto") -> dict:
        """调用 faster-whisper 进行语音识别"""
        lang = None if language == "auto" else language
        segments, info = self._model.transcribe(
            audio_path,
            language=lang,
            beam_size=10,
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 300},
            temperature=0.0,
            compression_ratio_threshold=2.4,
            log_prob_threshold=-1.0,
            no_speech_threshold=0.6,
            condition_on_previous_text=True,
            initial_prompt="以下是普通话的句子。",
        )
        text = " ".join([seg.text.strip() for seg in segments if seg.text.strip()])
        detected_lang = info.language if info else "unknown"

        # 如果检测到中文，强制使用中文语言提示重新识别以提升准确率
        if detected_lang == "zh" or self._contains_chinese(text):
            segments_zh, info_zh = self._model.transcribe(
                audio_path,
                language="zh",
                beam_size=10,
                vad_filter=True,
                temperature=0.0,
                initial_prompt="以下是普通话的句子。请用简体中文输出。",
            )
            text_zh = " ".join([seg.text.strip() for seg in segments_zh if seg.text.strip()])
            if len(text_zh) > len(text):
                text = text_zh

        return {"text": text, "model": self.model_name, "detected_lang": detected_lang}

    @staticmethod
    def _contains_chinese(text: str) -> bool:
        for char in text:
            if '\u4e00' <= char <= '\u9fff':
                return True
        return False


class IPCServer:
    """stdin/stdout JSON 协议处理"""

    def __init__(self):
        self.transcriber = None
        self.processor = TextProcessor()
        self.llm_bridge = None

    def handle(self, request: dict) -> dict:
        cmd = request.get("command", "")

        if cmd == "init":
            model = request.get("model", "base")
            try:
                self.transcriber = WhisperTranscriber(model)
                return {"status": "ok", "model": model}
            except Exception as e:
                return {"status": "error", "message": str(e)}

        elif cmd == "transcribe":
            if not self.transcriber:
                return {"status": "error", "message": "Not initialized"}

            audio_path = request.get("audio_path", "")
            language = request.get("language", "auto")
            post_process = request.get("post_process", True)

            if not audio_path or not os.path.exists(audio_path):
                return {"status": "error", "message": f"File not found: {audio_path}"}

            result = self.transcriber.transcribe(audio_path, language)

            if "error" in result:
                return {"status": "error", "message": result["error"]}

            text = result["text"]
            raw = text
            if post_process:
                text = self.processor.process(text, language)

            return {"status": "ok", "text": text, "raw": raw}

        elif cmd == "ping":
            return {"status": "ok", "pong": True}

        else:
            return {"status": "error", "message": f"Unknown command: {cmd}"}

    def run(self):
        """主循环：逐行读取 stdin JSON，处理并输出到 stdout"""
        sys.stderr.write("[server] Ready\n")
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
                sys.stderr.write("Invalid JSON\n")
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