#!/usr/bin/env python3
"""LightX2V APP process supervisor. Stdlib only; all stdout is NDJSON."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time


def emit(kind, **fields):
    print(json.dumps({"type": kind, **fields}, ensure_ascii=False), flush=True)


def load_request(path):
    with open(path, encoding="utf-8") as f:
        request = json.load(f)
    for key in ("repository", "model", "config"):
        value = request.get(key)
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise ValueError(f"{key} 必须是绝对路径")
    repo, model, config = (Path(request[k]) for k in ("repository", "model", "config"))
    if not (repo / "lightx2v/infer.py").is_file():
        raise ValueError("LightX2V 路径无效：找不到 lightx2v/infer.py")
    for folder in ("transformer", "text_encoder", "vae", "scheduler", "processor"):
        if not (model / folder).is_dir():
            raise ValueError(f"模型缺少目录或符号链接失效：{folder}")
    with config.open(encoding="utf-8") as f:
        cfg = json.load(f)
    expected = [1.0, 0.9375, 0.875, 0.75, 0.5, 0.25]
    if cfg.get("infer_steps") != 6 or cfg.get("sigmas") != expected:
        raise ValueError("当前版本仅支持 Viggle v0.3 的固定 6 步配置，请选择脚本对应的 JSON")
    if cfg.get("attn_type") != "torch_sdpa_mps":
        raise ValueError("请选择使用 torch_sdpa_mps 的 MPS 配置")
    if cfg.get("enable_cfg") is not False:
        raise ValueError("Viggle v0.3 配置必须关闭 CFG")
    return request, cfg


def environment(request):
    env = os.environ.copy()
    # Keep base.sh semantics while selecting the Python explicitly in the app.
    env.update({
        "PLATFORM": "mps", "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8",
        "PYTHONPATH": request["repository"] + os.pathsep + env.get("PYTHONPATH", ""),
        "MOONCAKE_CONFIG_PATH": str(Path(request["repository"]) / "configs/mooncake_config.json"),
        "TOKENIZERS_PARALLELISM": "false", "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True",
        "PYTORCH_ALLOC_CONF": "expandable_segments:True", "DTYPE": "BF16",
        "SENSITIVE_LAYER_DTYPE": "None", "PROFILING_DEBUG_LEVEL": "2", "LOGURU_COLORIZE": "NO",
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        "PATH": str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "/usr/bin:/bin"),
    })
    return env


def arguments(request, config_path):
    prompt = request.get("prompt", "")
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 20000:
        raise ValueError("请输入 1–20000 字的提示词")
    for key in ("width", "height"):
        n = request.get(key)
        if type(n) is not int or not 256 <= n <= 2048 or n % 32:
            raise ValueError("尺寸必须是 256–2048 之间的 32 的倍数")
    seed = request.get("seed")
    if type(seed) is not int or not 0 <= seed <= 4294967295:
        raise ValueError("种子必须介于 0 和 4294967295 之间")
    output = request.get("output", "")
    if not Path(output).is_absolute() or Path(output).suffix.lower() != ".png":
        raise ValueError("输出必须为 PNG 绝对路径")
    # CLI expects HEIGHT WIDTH, whereas the interface displays WIDTH × HEIGHT.
    return [sys.executable, "-u", "-m", "lightx2v.infer",
            "--model_cls", "qwen_image_21", "--task", "t2i",
            "--model_path", request["model"], "--config_json", str(config_path),
            "--prompt", prompt, "--size", str(request["height"]), str(request["width"]),
            "--seed", str(seed), "--save_result_path", output]


def check(request):
    os.environ.update(environment(request))
    sys.path.insert(0, request["repository"])
    import torch
    if not torch.backends.mps.is_available():
        raise RuntimeError("当前 Python 的 PyTorch 无法使用 MPS，请选择支持 Apple Silicon 的环境")
    for name in ("transformers", "diffusers", "safetensors", "loguru", "cv2"):
        if importlib.util.find_spec(name) is None:
            raise RuntimeError(f"Python 环境缺少依赖：{name}")
    # No weights are loaded during this check; perform a tiny real MPS operation.
    value = (torch.ones(2, device="mps") + 1).sum().item()
    if value != 4:
        raise RuntimeError("MPS 运算自检失败")
    # Redirect third-party startup prints away from the NDJSON channel. The native
    # app bounds this entire check to 100 seconds and owns its cancellation.
    with contextlib.redirect_stdout(sys.stderr):
        import lightx2v.infer
    emit("check", ok=True, message=f"MPS 可用 · PyTorch {torch.__version__} · Python {sys.version.split()[0]}",
         python=sys.executable, torch=torch.__version__)


def validate_image(path, expected_width, expected_height):
    # Decode as well as check metadata: a truncated PNG is not a completed run.
    from PIL import Image
    with Image.open(path) as im:
        im.load()
        if im.format != "PNG" or im.size != (expected_width, expected_height):
            raise RuntimeError(f"输出尺寸不匹配：{im.size}，预期 {expected_width} × {expected_height}")


def run(request, cfg):
    destination = Path(request["output"]).parent
    destination.mkdir(parents=True, exist_ok=True)
    config_path = destination / "config.json"
    # Validate all arguments before modifying any existing output.
    cmd = arguments(request, config_path)
    if Path(request["output"]).exists():
        raise ValueError("输出文件已存在，请创建新的生成任务")
    config_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    (destination / "invocation.json").write_text(json.dumps({"argv": cmd, "cwd": request["repository"]},
                                                             ensure_ascii=False, indent=2), encoding="utf-8")
    started = time.monotonic()
    state = {"child": None, "cancelled": False}

    def stop_group(child, sig):
        if child and child.poll() is None:
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                pass

    def cancel(signum, frame):
        if state["cancelled"]:
            return
        state["cancelled"] = True
        child = state["child"]
        stop_group(child, signal.SIGTERM)
        timer = threading.Timer(3, stop_group, args=(child, signal.SIGKILL))
        timer.daemon = True
        timer.start()

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    # Parent watchdog prevents a GPU process being orphaned if the native app crashes.
    parent = os.getppid()
    finished = threading.Event()

    def watch_parent():
        while not finished.wait(1):
            if os.getppid() != parent:
                os.kill(os.getpid(), signal.SIGTERM)
                return

    threading.Thread(target=watch_parent, daemon=True).start()
    code = -1
    emit("status", message="正在加载模型", phase="loading")
    tail = []
    try:
        with (destination / "inference.log").open("w", encoding="utf-8") as log:
            child = subprocess.Popen(cmd, cwd=request["repository"], env=environment(request),
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, encoding="utf-8", errors="replace", bufsize=1,
                                     start_new_session=True)
            state["child"] = child
            if state["cancelled"]:
                stop_group(child, signal.SIGKILL)
            for raw in child.stdout:
                line = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", raw).rstrip("\r\n")
                log.write(line + "\n")
                log.flush()
                tail = (tail + [line])[-30:]
                emit("log", message=line)
                step = re.search(r"step_index:\s*(\d+)\s*/\s*(\d+)", line)
                if step:
                    emit("step", step=int(step[1]), total=int(step[2]))
                elif "Run VAE Decoder" in line:
                    emit("status", message="正在解码图片", phase="decoding")
                elif "Run Encoders" in line:
                    emit("status", message="正在编码提示词", phase="encoding")
            code = child.wait()
        if state["cancelled"]:
            emit("done", status="cancelled", message="生成已停止", duration=time.monotonic() - started)
            return 130
        if code != 0:
            raise RuntimeError(f"推理进程退出（{code}）\n" + "\n".join(tail[-12:]))
        validate_image(request["output"], request["width"], request["height"])
        emit("done", status="completed", image=request["output"], duration=time.monotonic() - started)
        return 0
    finally:
        finished.set()
        stop_group(state["child"], signal.SIGKILL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["check", "run"])
    parser.add_argument("request")
    args = parser.parse_args()
    try:
        request, cfg = load_request(args.request)
        if args.mode == "check":
            check(request)
            return 0
        return run(request, cfg)
    except BaseException as exc:
        emit("error", message=str(exc))
        if args.mode == "run":
            emit("done", status="failed", message=str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
