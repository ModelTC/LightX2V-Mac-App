"""Local PE adapter. No torch imports; llama.cpp exits before image inference."""
import codecs
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time


CHAT_TEMPLATE = "{% for message in messages %}{{ '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>\\n' }}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n<think>\\n' }}{% endif %}"
END_TEXT = "[end of text]"


def ratio_value(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9]\d{0,4}:[1-9]\d{0,4}", value):
        raise ValueError("增强模型返回了无效的画面比例")
    a, b = map(int, value.split(":"))
    if not 0.1 <= a / b <= 10:
        raise ValueError("增强模型返回的画面比例超出支持范围")
    return a / b


def validate_resources(settings, mode):
    if not isinstance(settings, dict) or settings.get("enabled") is not True:
        raise ValueError("Prompt 增强配置无效")
    binary = "llama-completion" if mode == "t2i" else "llama-mtmd-cli"
    runtime = settings.get("runtimeDirectory", "")
    executable = Path(runtime) / binary
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f"找不到 {binary}，请配置 Prompt 增强的运行目录")
    keys = [mode + "Model", mode + "SystemPrompt"] + (["visionProjector"] if mode == "i2i" else [])
    for key in keys:
        value = settings.get(key)
        if not isinstance(value, str) or not Path(value).is_absolute() or not Path(value).is_file() or Path(value).stat().st_size == 0:
            raise ValueError(f"Prompt 增强资源缺失：{key}")
    return str(executable)


def command(request, folder):
    settings = request["promptEnhancement"]
    images = request.get("inputImages", [])
    mode = "i2i" if images else "t2i"
    executable = validate_resources(settings, mode)
    system = Path(settings[mode + "SystemPrompt"]).read_text(encoding="utf-8").strip()
    if not system or len(system) > 100000:
        raise ValueError("增强模型的系统提示词为空或过长")
    args = [executable, "-m", settings[mode + "Model"]]
    if mode == "t2i":
        prompt_file = folder / "input.txt"
        prompt_file.write_text(f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{request['prompt']}<|im_end|>\n<|im_start|>assistant\n<think>\n", encoding="utf-8")
        args += ["-f", str(prompt_file), "--no-conversation", "--no-display-prompt", "--simple-io", "--color", "off"]
    else:
        args += ["--mmproj", settings["visionProjector"]]
        # CLI splits commas in each --image value. Safe relative snapshot names
        # preserve order and duplicates even in a workspace with commas/spaces.
        for image in images:
            path = Path(image["path"])
            args += ["--image", "inputs/" + path.name]
        # Eight 4096-token images would alone exhaust the 32768-token context.
        # Keep the scripts' single/two-image quality and bound the combined
        # vision context for larger reference batches, without dropping images.
        image_tokens = min(4096, (8192 // len(images) // 256) * 256)
        args += ["-p", request["prompt"], "-sys", system, "--jinja", "--chat-template", CHAT_TEMPLATE,
                 "--no-warmup", "--image-max-tokens", str(image_tokens)]
    args += ["--no-escape", "-ngl", "all", "-c", "32768", "-n", "16256" if mode == "t2i" else "24000",
             "-b", "512", "-ub", "512", "--flash-attn", "on", "--temp", "1.0", "--top-p", "0.95",
             "--top-k", "20", "--min-p", "0", "--repeat-penalty", "1", "--seed", "42", "--perf", "--log-verbosity", "4"]
    return args, mode


class ThinkingStream:
    """Incremental UTF-8 text, with a closing tag allowed to span any chunk."""
    def __init__(self, emit):
        self.emit = emit
        self.raw = ""
        self.pending = ""
        self.thinking = ""
        self.delta = ""
        self.closed = False
        self.last_emit = 0.0

    def feed(self, text):
        self.raw += text
        if len(self.raw) > 1500000:
            raise ValueError("增强响应过长，已停止本次生成")
        if self.closed:
            return
        self.pending += text
        # The opening tag is already part of the generation prompt. Some builds
        # echo it; keep it out of the displayed thinking if present.
        if not self.thinking and "<think>".startswith(self.pending.lstrip()):
            return
        if not self.thinking and self.pending.lstrip().startswith("<think>"):
            self.pending = self.pending.lstrip()[len("<think>"):].lstrip("\n")
        head, marker, tail = self.pending.partition("</think>")
        if marker:
            self.append(head)
            self.pending = ""
            self.closed = True
            self.flush()
            self.emit("enhancement_phase", phase="rewriting")
        else:
            # Retain the longest possible partial closing tag, not real text.
            keep = 0
            for n in range(1, len("</think>")):
                if self.pending.endswith("</think>"[:n]):
                    keep = n
            self.append(self.pending[:-keep] if keep else self.pending)
            self.pending = self.pending[-keep:] if keep else ""
        if time.monotonic() - self.last_emit >= 0.15:
            self.flush()

    def append(self, text):
        self.thinking += text
        self.delta += text

    def flush(self):
        if self.delta:
            self.emit("enhancement_thinking", delta=self.delta)
            self.delta = ""
            self.last_emit = time.monotonic()

    def finish(self):
        if not self.closed:
            self.append(self.pending)
            self.pending = ""
        self.flush()


def parse_result(raw, mode, image_count):
    _, marker, answer = raw.partition("</think>")
    if not marker:
        raise ValueError("Prompt 增强未完整输出思考过程，请重试")
    answer = answer.strip()
    if mode == "t2i":
        if not answer.endswith(END_TEXT):
            raise ValueError("Prompt 增强输出未完成，请重试")
        answer = answer[:-len(END_TEXT)].rstrip()
    elif answer.endswith(END_TEXT):
        answer = answer[:-len(END_TEXT)].rstrip()
    result = json.loads(answer)
    expected = {"rewritten_prompt", "wh_ratio"} | ({"ratio_follow"} if mode == "i2i" else set())
    if not isinstance(result, dict) or set(result) != expected or not all(isinstance(v, str) for v in result.values()):
        raise ValueError("Prompt 增强返回了无效的结果格式")
    prompt = result["rewritten_prompt"].strip()
    if not prompt or len(prompt) > 20000:
        raise ValueError("增强后的提示词为空或过长")
    result["rewritten_prompt"] = prompt
    if result["wh_ratio"]:
        ratio_value(result["wh_ratio"])
    follow = result.get("ratio_follow", "")
    if mode == "t2i" and not result["wh_ratio"]:
        raise ValueError("文字增强没有返回画面比例")
    if mode == "i2i":
        match = re.fullmatch(r"<image([1-8])>", follow)
        if bool(result["wh_ratio"]) == bool(follow) or (follow and (not match or int(match[1]) > image_count)):
            raise ValueError("参考图增强返回了无效的比例或参考图编号")
    return result


def inference_request(request, result):
    effective = dict(request)
    effective["prompt"] = result["rewritten_prompt"]
    effective.pop("promptEnhancement", None)
    # A user's selected fixed shape takes precedence. Adaptive retains the 1K/2K
    # tier but can use the enhancer's semantic framing / chosen canvas image.
    if request.get("resolution") is not None:
        if result["wh_ratio"]:
            effective["aspectRatio"] = result["wh_ratio"]
        else:
            index = int(re.fullmatch(r"<image([1-8])>", result["ratio_follow"])[1]) - 1
            from PIL import Image
            with Image.open(request["inputImages"][index]["path"]) as image:
                width, height = image.size
            divisor = math.gcd(width, height)
            effective["aspectRatio"] = f"{width // divisor}:{height // divisor}"
    return effective


def run_enhancement(request, destination, emit, supervisor):
    folder = destination / "enhancement"
    folder.mkdir(exist_ok=True)
    args, mode = command(request, folder)
    (folder / "invocation.json").write_text(json.dumps({"argv": args, "cwd": str(destination)}, ensure_ascii=False, indent=2), encoding="utf-8")
    emit("status", message="正在加载增强模型", phase="enhancement")
    emit("enhancement_phase", phase="thinking", mode=mode)
    started = time.monotonic()
    stream = ThinkingStream(emit)
    decoder = codecs.getincrementaldecoder("utf-8")("strict")
    try:
        with (folder / "llama.log").open("wb") as diagnostics, (folder / "raw.txt").open("w", encoding="utf-8") as raw:
            child = supervisor.spawn(args, cwd=str(destination), env=os.environ.copy(), stdout=subprocess.PIPE, stderr=diagnostics)
            try:
                while True:
                    chunk = child.stdout.read1(4096)
                    if not chunk:
                        break
                    text = decoder.decode(chunk)
                    raw.write(text); raw.flush()
                    stream.feed(text)
                text = decoder.decode(b"", final=True)
                raw.write(text); stream.feed(text)
                code = child.wait()
            finally:
                supervisor.release(child)
            supervisor.check_cancelled()
            if code != 0:
                raise RuntimeError(f"Prompt 增强进程退出（{code}），请查看任务目录中的 enhancement/llama.log")
        stream.finish()
        result = parse_result(stream.raw, mode, len(request.get("inputImages", [])))
        effective = inference_request(request, result)
        (folder / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        (destination / "effective_request.json").write_text(json.dumps(effective, ensure_ascii=False, indent=2), encoding="utf-8")
        supervisor.check_cancelled()
        emit("enhancement_result", prompt=result["rewritten_prompt"], whRatio=result["wh_ratio"],
             ratioFollow=result.get("ratio_follow", ""), duration=time.monotonic() - started)
        return effective
    finally:
        stream.finish()
        (folder / "thinking.txt").write_text(stream.thinking, encoding="utf-8")
